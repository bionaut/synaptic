defmodule Synaptic.Engine do
  @moduledoc """
  Internal orchestrator that glues workflow definitions to runtime runners.
  """

  alias Synaptic.{Runner, Workflow}

  def start(workflow_module, input, opts) do
    definition = Workflow.definition(workflow_module)
    run_id = Keyword.get(opts, :run_id, generate_run_id())

    with {:ok, start_at_step_index} <- validate_start_at_step(opts, definition) do
      child_spec_opts = [
        workflow: workflow_module,
        definition: definition,
        run_id: run_id,
        context: input
      ]

      child_spec_opts =
        if start_at_step_index do
          Keyword.put(child_spec_opts, :start_at_step_index, start_at_step_index)
        else
          child_spec_opts
        end

      child_spec = {Runner, child_spec_opts}

      case DynamicSupervisor.start_child(Synaptic.RuntimeSupervisor, child_spec) do
        {:ok, _pid} ->
          {:ok, run_id}

        {:error, {:already_started, _pid}} ->
          {:error, :already_running}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_start_at_step(opts, definition) do
    case Keyword.get(opts, :start_at_step) do
      nil ->
        {:ok, nil}

      step_name when is_atom(step_name) ->
        case find_step_index(definition.steps, step_name) do
          nil -> {:error, :invalid_step}
          index -> {:ok, index}
        end

      _ ->
        {:error, :invalid_step}
    end
  end

  defp find_step_index(steps, step_name) do
    steps
    |> Enum.with_index()
    |> Enum.find_value(fn {%{name: name}, index} ->
      if name == step_name, do: index
    end)
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

  def stop(run_id, reason) do
    Runner.stop(run_id, reason)
  end

  def workflow_definition(module), do: Workflow.definition(module)

  def generate_run_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
