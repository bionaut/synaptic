defmodule Synaptic.RLMIntegrationTest do
  use ExUnit.Case

  alias Synaptic.RLM

  defmodule StubAdapter do
    @moduledoc false

    def chat(messages, _opts) do
      if tool_call_cycle?(messages) do
        {:ok, "ack", %{usage: %{total_tokens: 7}}}
      else
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{
               "id" => "call_1",
               "function" => %{
                 "name" => "set_answer",
                 "arguments" => ~s({"answer":"demo answer"})
               }
             }
           ]
         }, %{usage: %{total_tokens: 5}}}
      end
    end

    defp tool_call_cycle?(messages) do
      Enum.any?(messages, fn
        %{role: "tool"} -> true
        _ -> false
      end)
    end
  end

  setup do
    original = Application.get_env(:synaptic, Synaptic.Tools)

    Application.put_env(:synaptic, Synaptic.Tools,
      llm_adapter: StubAdapter,
      agents: [
        root: [adapter: StubAdapter],
        sub: [adapter: StubAdapter]
      ]
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:synaptic, Synaptic.Tools)
        _ -> Application.put_env(:synaptic, Synaptic.Tools, original)
      end
    end)
  end

  test "process returns answer and tracks budget using stub adapter" do
    {:ok, answer, stats} =
      RLM.process("long context goes here", "What is the answer?", token_budget: 50)

    assert answer == "demo answer"

    # Usage is accumulated across tool call cycles:
    # - First call (with tool calls): 5 tokens
    # - Second call (after tool execution): 7 tokens
    # - Total: 12 tokens
    # Each API call increments root_calls, so we have 2 calls total
    assert stats.budget.tokens_used == 12
    assert stats.budget.root_calls == 2
    assert stats.budget.sub_calls == 0
    assert stats.budget.token_budget == 50
  end
end
