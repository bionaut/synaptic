defmodule Synapse do
  @moduledoc """
  Synapse provides a declarative workflow engine with a DSL for orchestrating
  LLM-backed steps, human-in-the-loop pauses, and resumable executions.
  """

  alias Synapse.Engine

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
end
