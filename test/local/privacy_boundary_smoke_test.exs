defmodule Synaptic.Local.PrivacyBoundarySmokeTest do
  use ExUnit.Case

  @moduledoc false

  # Local-only smoke tests for exercising the privacy boundary by hand.
  #
  # Run examples:
  #   mix test test/local/privacy_boundary_smoke_test.exs
  #   mix test test/local/privacy_boundary_smoke_test.exs --trace

  defmodule CaptureAdapter do
    def chat(messages, _opts) do
      send(test_pid(), {:capture_messages, messages})
      result = Application.get_env(:synaptic, __MODULE__)[:result] || "Contact jane@example.com"
      {:ok, result}
    end

    defp test_pid do
      Application.fetch_env!(:synaptic, __MODULE__)[:test_pid]
    end
  end

  defmodule ToolLoopAdapter do
    def chat(messages, _opts) do
      send(test_pid(), {:tool_loop_messages, messages})

      case Process.get({__MODULE__, :stage}, :first) do
        :first ->
          Process.put({__MODULE__, :stage}, :second)

          {:ok,
           %{
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "function" => %{
                   "name" => "send_email",
                   "arguments" => ~s({"email":"[PII_EMAIL_1]","subject":"Hello"})
                 }
               }
             ]
           }}

        :second ->
          {:ok, "Sent follow-up to jane@example.com"}
      end
    end

    defp test_pid do
      Application.fetch_env!(:synaptic, __MODULE__)[:test_pid]
    end
  end

  defmodule StreamAdapter do
    def chat(messages, opts) do
      send(test_pid(), {:stream_messages, messages})

      if on_chunk = opts[:on_chunk] do
        on_chunk.("Reach jane@example.com", "Reach jane@example.com")
      end

      {:ok, "Reach jane@example.com"}
    end

    defp test_pid do
      Application.fetch_env!(:synaptic, __MODULE__)[:test_pid]
    end
  end

  setup do
    original_privacy = Application.get_env(:synaptic, Synaptic.Privacy)
    original_capture = Application.get_env(:synaptic, CaptureAdapter)
    original_tool_loop = Application.get_env(:synaptic, ToolLoopAdapter)
    original_stream = Application.get_env(:synaptic, StreamAdapter)

    Application.put_env(:synaptic, CaptureAdapter, test_pid: self())
    Application.put_env(:synaptic, ToolLoopAdapter, test_pid: self())
    Application.put_env(:synaptic, StreamAdapter, test_pid: self())

    Process.delete({ToolLoopAdapter, :stage})

    on_exit(fn ->
      restore_env(Synaptic.Privacy, original_privacy)
      restore_env(CaptureAdapter, original_capture)
      restore_env(ToolLoopAdapter, original_tool_loop)
      restore_env(StreamAdapter, original_stream)
      Process.delete({ToolLoopAdapter, :stage})
    end)

    :ok
  end

  test "prompt input is tokenized while model output is masked" do
    assert {:ok, "Contact j***@example.com"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please reach jane@example.com"}],
               adapter: CaptureAdapter,
               privacy: [enabled: true]
             )

    assert_receive {:capture_messages, messages}, 1_000

    content = Enum.at(messages, 0).content
    refute content =~ "jane@example.com"
    assert content =~ "[PII_EMAIL_1]"
  end

  test "output rehydration can be enabled explicitly" do
    Application.put_env(:synaptic, CaptureAdapter,
      test_pid: self(),
      result: "Contact [PII_EMAIL_1]"
    )

    assert {:ok, "Contact jane@example.com"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Please reach jane@example.com"}],
               adapter: CaptureAdapter,
               privacy: [enabled: true, output: [rehydrate: true]]
             )
  end

  test "tool calls are rehydrated outside the model boundary" do
    tool = %Synaptic.Tools.Tool{
      name: "send_email",
      description: "send an email",
      schema: %{
        type: "object",
        properties: %{
          email: %{type: "string"},
          subject: %{type: "string"}
        },
        required: ["email", "subject"]
      },
      handler: fn %{"email" => email, "subject" => subject} ->
        send(self(), {:tool_handler_args, email, subject})
        %{status: "sent to #{email}"}
      end
    }

    assert {:ok, "Sent follow-up to j***@example.com"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "Email jane@example.com with subject Hello"}],
               adapter: ToolLoopAdapter,
               tools: [tool],
               privacy: [enabled: true]
             )

    assert_receive {:tool_handler_args, "jane@example.com", "Hello"}, 1_000
    assert_receive {:tool_loop_messages, first_messages}, 1_000
    assert Enum.at(first_messages, 0).content =~ "[PII_EMAIL_1]"
  end

  test "stream chunks are filtered before subscribers receive them" do
    run_id = "local-privacy-smoke"
    :ok = Synaptic.subscribe(run_id)

    on_exit(fn ->
      Synaptic.unsubscribe(run_id)
    end)

    assert {:ok, "Reach j***@example.com"} =
             Synaptic.Tools.chat(
               [%{role: "user", content: "hello"}],
               adapter: StreamAdapter,
               stream: true,
               run_id: run_id,
               step_name: :privacy_smoke,
               privacy: [enabled: true]
             )

    assert_receive {:synaptic_event, %{event: :stream_chunk, chunk: chunk, accumulated: all}},
                   1_000

    refute chunk =~ "jane@example.com"
    refute all =~ "jane@example.com"
    assert chunk =~ "j***@example.com"
    assert all =~ "j***@example.com"
  end

  defp restore_env(app, nil), do: Application.delete_env(:synaptic, app)
  defp restore_env(app, value), do: Application.put_env(:synaptic, app, value)
end
