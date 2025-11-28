defmodule Synapse.Engine do
  @moduledoc false

  alias Synapse.{Runner, Workflow}

  def start(workflow_module, input, opts) do
    definition = Workflow.definition(workflow_module)
    run_id = Keyword.get(opts, :run_id, generate_run_id())

    child_spec =
      {Runner, workflow: workflow_module, definition: definition, run_id: run_id, context: input}

    case DynamicSupervisor.start_child(Synapse.RuntimeSupervisor, child_spec) do
      {:ok, _pid} ->
        {:ok, run_id}

      {:error, {:already_started, _pid}} ->
        {:error, :already_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resume(run_id, payload) do
    Runner.resume(run_id, payload)
  end

  def inspect(run_id) do
    Runner.snapshot(run_id)
  end

  def history(run_id) do
    Runner.history(run_id)
  end

  def workflow_definition(module), do: Workflow.definition(module)

  def generate_run_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
