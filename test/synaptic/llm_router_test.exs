defmodule Synaptic.LLMRouterTest do
  use ExUnit.Case, async: true

  defmodule RouterAdapter do
    def chat(_messages, _opts), do: {:ok, %{"choice" => 2}}
  end

  defmodule RouterAdapterChoiceTarget do
    def chat(_messages, _opts), do: {:ok, %{"choice" => "right"}}
  end

  defmodule LLMRouterWorkflow do
    use Synaptic.Workflow

    step :start do
      send(context.test_pid, {:step, :start})
      {:ok, %{started: true}}
    end

    llm_router :decide,
               [
                 {"go left", :left},
                 {"go right", :right}
               ] do
      %{signal: Map.get(context, :signal)}
    end

    step :left do
      send(context.test_pid, {:step, :left})
      {:ok, %{path: :left}}
    end

    step :right do
      send(context.test_pid, {:step, :right})
      {:ok, %{path: :right}}
    end

    commit()
  end

  setup do
    original = Application.get_env(:synaptic, Synaptic.Tools)

    base = original || []

    Application.put_env(
      :synaptic,
      Synaptic.Tools,
      Keyword.put(base, :llm_adapter, __MODULE__.RouterAdapter)
    )

    on_exit(fn ->
      if original do
        Application.put_env(:synaptic, Synaptic.Tools, original)
      else
        Application.delete_env(:synaptic, Synaptic.Tools)
      end
    end)

    :ok
  end

  test "llm_router registers branch metadata" do
    definition = Synaptic.workflow_definition(LLMRouterWorkflow)

    decide_step = Enum.find(definition.steps, &(&1.name == :decide))

    assert decide_step.type == :llm

    assert decide_step.llm_branches == [
             {"go left", :left},
             {"go right", :right}
           ]
  end

  test "llm_router routes to the chosen target step" do
    parent = self()
    {:ok, run_id} = Synaptic.start(LLMRouterWorkflow, %{test_pid: parent, signal: :ok})

    assert_receive {:step, :start}, 500
    assert_receive {:step, :right}, 500
    refute_receive {:step, :left}, 100

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:path] == :right

    history = Synaptic.history(run_id)

    assert Enum.any?(history, fn entry ->
             entry[:step] == :decide and entry[:status] == :routed and entry[:target] == :right
           end)
  end

  test "llm_router accepts target name in choice field" do
    original = Application.get_env(:synaptic, Synaptic.Tools)
    base = original || []

    Application.put_env(
      :synaptic,
      Synaptic.Tools,
      Keyword.put(base, :llm_adapter, __MODULE__.RouterAdapterChoiceTarget)
    )

    on_exit(fn ->
      if original do
        Application.put_env(:synaptic, Synaptic.Tools, original)
      else
        Application.delete_env(:synaptic, Synaptic.Tools)
      end
    end)

    parent = self()
    {:ok, _run_id} = Synaptic.start(LLMRouterWorkflow, %{test_pid: parent, signal: :ok})

    assert_receive {:step, :start}, 500
    assert_receive {:step, :right}, 500
    refute_receive {:step, :left}, 100
  end

  test "llm_router branch targets must exist in workflow" do
    module_name = "Synaptic.InvalidLLMRouterWorkflow#{System.unique_integer([:positive])}"

    code = """
    defmodule #{module_name} do
      use Synaptic.Workflow

      llm_router :decide, [{"missing target", :nope}] do
        "state"
      end

      commit()
    end
    """

    assert_raise ArgumentError, ~r/unknown step/, fn ->
      Code.compile_string(code)
    end
  end

  defp wait_for(run_id, status, attempts \\ 20)
  defp wait_for(_run_id, _status, 0), do: flunk("workflow did not reach desired status")

  defp wait_for(run_id, status, attempts) do
    snapshot = Synaptic.inspect(run_id)

    if snapshot.status == status do
      snapshot
    else
      Process.sleep(25)
      wait_for(run_id, status, attempts - 1)
    end
  end
end
