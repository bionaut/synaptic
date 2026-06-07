defmodule Synaptic.Tools.CodexExecTest do
  use ExUnit.Case, async: true

  alias Synaptic.Tools.CodexExec

  test "parse_exec_output returns final agent message and normalized usage" do
    output =
      [
        Jason.encode!(%{"type" => "thread.started", "thread_id" => "thr_1"}),
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "first"}
        }),
        Jason.encode!(%{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "final"}
        }),
        Jason.encode!(%{
          "type" => "turn.completed",
          "usage" => %{
            "input_tokens" => 10,
            "cached_input_tokens" => 4,
            "output_tokens" => 5,
            "reasoning_output_tokens" => 2
          }
        })
      ]
      |> Enum.join("\n")

    assert {:ok, "final", %{usage: usage}} = CodexExec.parse_exec_output(output)
    assert usage.prompt_tokens == 10
    assert usage.completion_tokens == 5
    assert usage.total_tokens == 15
    assert usage.cached_input_tokens == 4
    assert usage.reasoning_output_tokens == 2
  end

  test "chat invokes codex exec with prompt argument and returns final jsonl message" do
    parent = self()

    runner = fn bin, args, opts ->
      send(parent, {:command, bin, args, opts})

      {Jason.encode!(%{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => "done"}
       }), 0}
    end

    assert {:ok, "done"} =
             CodexExec.chat(
               [
                 %{role: "system", content: "You are concise."},
                 %{role: "user", content: "Ping"}
               ],
               codex_bin: "/bin/echo",
               cwd: File.cwd!(),
               model: "gpt-5-mini",
               sandbox: :workspace_write,
               command_runner: runner
             )

    assert_received {:command, "/bin/echo", args, opts}
    assert flag_value(args, "--ask-for-approval") == "never"
    assert "exec" in args
    assert "--json" in args
    assert "--ephemeral" in args
    assert flag_value(args, "--model") == "gpt-5-mini"
    assert flag_value(args, "--sandbox") == "workspace-write"
    assert ~s(model_reasoning_effort="low") in flag_values(args, "-c")
    assert List.last(args) =~ "[SYSTEM]\nYou are concise."
    assert List.last(args) =~ "[USER]\nPing"
    assert opts[:cd] == File.cwd!()
    assert opts[:stderr_to_stdout]
    refute Keyword.has_key?(opts, :input)
  end

  test "chat decodes json_object response_format" do
    runner = fn _bin, _args, _opts ->
      {Jason.encode!(%{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => ~s({"ok":true})}
       }), 0}
    end

    assert {:ok, %{"ok" => true}} =
             CodexExec.chat([%{role: "user", content: "json"}],
               codex_bin: "/bin/echo",
               cwd: File.cwd!(),
               command_runner: runner,
               model_reasoning_effort: :medium,
               response_format: :json_object
             )
  end

  test "chat defaults to gpt-5.5 with low reasoning" do
    parent = self()

    runner = fn bin, args, opts ->
      send(parent, {:command, bin, args, opts})

      {Jason.encode!(%{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => "done"}
       }), 0}
    end

    assert {:ok, "done"} =
             CodexExec.chat([%{role: "user", content: "ping"}],
               codex_bin: "/bin/echo",
               cwd: File.cwd!(),
               command_runner: runner
             )

    assert_received {:command, "/bin/echo", args, _opts}
    assert flag_value(args, "--model") == "gpt-5.5"
    assert ~s(model_reasoning_effort="low") in flag_values(args, "-c")
  end

  test "chat rejects OpenAI-style tool calls" do
    assert {:error, {:unsupported, :codex_exec_tool_loop}} =
             CodexExec.chat([%{role: "user", content: "ping"}],
               codex_bin: "/bin/echo",
               tools: [%{type: "function"}]
             )
  end

  test "chat returns structured error for non-zero exit" do
    runner = fn _bin, _args, _opts ->
      {Jason.encode!(%{
         "type" => "error",
         "message" => "not authenticated"
       }), 1}
    end

    assert {:error, {:codex_exec_failed, 1, %{"message" => "not authenticated"}}} =
             CodexExec.chat([%{role: "user", content: "ping"}],
               codex_bin: "/bin/echo",
               cwd: File.cwd!(),
               command_runner: runner
             )
  end

  defp flag_value(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^flag, value] -> value
      _ -> nil
    end)
  end

  defp flag_values(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [^flag, value] -> [value]
      _ -> []
    end)
  end
end
