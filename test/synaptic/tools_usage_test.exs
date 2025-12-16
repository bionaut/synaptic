defmodule Synaptic.ToolsUsageTest do
  use ExUnit.Case

  defmodule AdapterWithUsage do
    def chat(_messages, _opts) do
      {:ok, "response", %{usage: %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}}}
    end
  end

  defmodule AdapterWithoutUsage do
    def chat(_messages, _opts) do
      {:ok, "response"}
    end
  end

  defmodule AdapterWithUsageAndToolCalls do
    def chat(_messages, _opts) do
      {:ok, %{content: "response", tool_calls: []},
       %{usage: %{prompt_tokens: 15, completion_tokens: 25, total_tokens: 40}}}
    end
  end

  @messages [%{role: "user", content: "test"}]

  setup do
    # Capture Telemetry events
    handler_id = "test-handler-#{:erlang.unique_integer([:positive])}"

    handler = fn event, measurements, metadata, _config ->
      send(self(), {:telemetry, event, measurements, metadata})
    end

    :telemetry.attach_many(
      handler_id,
      [
        [:synaptic, :llm, :start],
        [:synaptic, :llm, :stop]
      ],
      handler,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    %{handler_id: handler_id}
  end

  test "extracts and includes usage metrics in Telemetry when adapter returns them" do
    result = Synaptic.Tools.chat(@messages, adapter: AdapterWithUsage)

    assert {:ok, "response"} = result

    assert_receive {:telemetry, [:synaptic, :llm, :start], _measurements, metadata}, 100
    assert metadata.adapter == AdapterWithUsage

    assert_receive {:telemetry, [:synaptic, :llm, :stop], measurements, metadata}, 100
    # Duration is automatically added by Telemetry span
    assert Map.has_key?(measurements, :duration)
    # Token counts are in metadata
    assert metadata.prompt_tokens == 10
    assert metadata.completion_tokens == 20
    assert metadata.total_tokens == 30
    assert metadata.usage == %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30}
  end

  test "works without usage metrics when adapter doesn't return them" do
    result = Synaptic.Tools.chat(@messages, adapter: AdapterWithoutUsage)

    assert {:ok, "response"} = result

    assert_receive {:telemetry, [:synaptic, :llm, :start], _measurements, _metadata}, 100
    assert_receive {:telemetry, [:synaptic, :llm, :stop], measurements, metadata}, 100

    # Duration is automatically added by Telemetry span
    assert Map.has_key?(measurements, :duration)
    # No usage metrics when adapter doesn't return them
    refute Map.has_key?(metadata, :usage)
    refute Map.has_key?(metadata, :prompt_tokens)
  end

  test "handles usage metrics with tool calls" do
    result = Synaptic.Tools.chat(@messages, adapter: AdapterWithUsageAndToolCalls)

    assert {:ok, %{content: "response", tool_calls: []}} = result

    assert_receive {:telemetry, [:synaptic, :llm, :start], _measurements, _metadata}, 100
    assert_receive {:telemetry, [:synaptic, :llm, :stop], measurements, metadata}, 100

    # Duration is automatically added by Telemetry span
    assert Map.has_key?(measurements, :duration)
    # Token counts are in metadata
    assert metadata.prompt_tokens == 15
    assert metadata.completion_tokens == 25
    assert metadata.total_tokens == 40
    assert metadata.usage == %{prompt_tokens: 15, completion_tokens: 25, total_tokens: 40}
  end
end
