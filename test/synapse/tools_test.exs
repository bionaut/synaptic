defmodule Synapse.ToolsTest do
  use ExUnit.Case

  defmodule PrimaryAdapter do
    def chat(_messages, opts), do: {:ok, {:primary, opts}}
  end

  defmodule SecondaryAdapter do
    def chat(_messages, opts), do: {:ok, {:secondary, opts}}
  end

  @messages [%{role: "user", content: "ping"}]

  setup do
    original = Application.get_env(:synapse, Synapse.Tools)

    Application.put_env(:synapse, Synapse.Tools,
      llm_adapter: __MODULE__.PrimaryAdapter,
      agents: [
        engineer: [model: "o4-mini", temperature: 0.2],
        translator: [adapter: __MODULE__.SecondaryAdapter, model: "gpt-4o-mini"]
      ]
    )

    on_exit(fn ->
      if original do
        Application.put_env(:synapse, Synapse.Tools, original)
      else
        Application.delete_env(:synapse, Synapse.Tools)
      end
    end)

    :ok
  end

  test "applies agent defaults" do
    assert {:ok, {:primary, opts}} = Synapse.Tools.chat(@messages, agent: :engineer)
    assert opts[:model] == "o4-mini"
    assert opts[:temperature] == 0.2
  end

  test "allows explicit overrides" do
    assert {:ok, {:primary, opts}} =
             Synapse.Tools.chat(@messages, agent: :engineer, temperature: 0.5)

    assert opts[:temperature] == 0.5
  end

  test "uses adapter overrides configured on agent" do
    assert {:ok, {:secondary, opts}} = Synapse.Tools.chat(@messages, agent: :translator)
    assert opts[:model] == "gpt-4o-mini"
  end

  test "raises when agent is missing" do
    assert_raise ArgumentError, ~r/unknown Synapse agent/, fn ->
      Synapse.Tools.chat(@messages, agent: :missing)
    end
  end
end
