defmodule Synapse do
  @moduledoc """
  Synapse provides a declarative workflow engine with a DSL for orchestrating
  LLM-backed steps, human-in-the-loop pauses, and resumable executions.
  """

  alias Synapse.Engine
  alias Phoenix.PubSub

  @doc """
  Starts a workflow module with the provided input context.
  """
  def start(workflow_module, input \\ %{}, opts \\ []) when is_map(input) do
    Engine.start(workflow_module, input, opts)
  end

  @doc """
  Resumes a previously suspended workflow run with the supplied payload.
  """
  def resume(run_id, payload) when is_binary(run_id) and is_map(payload) do
    Engine.resume(run_id, payload)
  end

  @doc """
  Returns a snapshot of the current workflow state for a run id.
  """
  def inspect(run_id) when is_binary(run_id) do
    Engine.inspect(run_id)
  end

  @doc """
  Returns the step-level history collected for a workflow run.
  """
  def history(run_id) when is_binary(run_id) do
    Engine.history(run_id)
  end

  @doc """
  Fetches the compiled workflow definition for a module.
  """
  def workflow_definition(module) when is_atom(module) do
    Engine.workflow_definition(module)
  end

  @doc """
  Returns a list of currently running workflows with their run ids, workflow
  module, and snapshot context.
  """
  def list_runs do
    for {run_id, pid} <- Synapse.Registry.entries(), reduce: [] do
      acc ->
        case safe_get_state(pid) do
          %{workflow: workflow, context: context, status: status} ->
            [%{run_id: run_id, workflow: workflow, context: context, status: status} | acc]

          _ ->
            acc
        end
    end
  end

  @doc """
  Stops a running workflow. Returns `:ok` when the runner terminates or
  `{:error, :not_found}` if the run id is unknown.
  """
  def stop(run_id, reason \\ :canceled) when is_binary(run_id) do
    Engine.stop(run_id, reason)
  end

  @doc """
  Subscribes the calling process to PubSub events for the given `run_id`.

  Events are delivered as `{:synapse_event, %{run_id: ..., event: ...}}` tuples.
  """
  def subscribe(run_id) when is_binary(run_id) do
    PubSub.subscribe(Synapse.PubSub, topic(run_id))
  end

  @doc """
  Unsubscribes the calling process from workflow events for the given `run_id`.
  """
  def unsubscribe(run_id) when is_binary(run_id) do
    PubSub.unsubscribe(Synapse.PubSub, topic(run_id))
  end

  defp topic(run_id), do: "synapse:run:" <> run_id

  defp safe_get_state(pid) do
    try do
      :sys.get_state(pid)
    catch
      :exit, _ -> nil
    end
  end
end
