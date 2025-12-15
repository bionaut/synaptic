defmodule Synaptic.Experiments do
  @moduledoc """
  Experimental API for running workflows against multiple inputs and scorers.

  This module intentionally provides a minimal, in-memory harness inspired by
  Mastra's `runExperiment` function. It reuses the existing scorer abstraction
  and the public `Synaptic.start/3` + `Synaptic.inspect/1` APIs without adding
  new runtime behaviour to `Synaptic.Runner`.

  The API is kept small on purpose to allow iteration as real-world use cases
  emerge.
  """

  @typedoc """
  Data item used when running experiments.

  The `:input` map is passed as the initial workflow context. Arbitrary
  metadata can be attached via `:metadata` and will be available to scorers
  through their own configuration or via Telemetry subscribers.
  """
  @type data_item :: %{
          required(:input) => map(),
          optional(:metadata) => map()
        }

  @typedoc """
  High-level summary of an experiment run.
  """
  @type summary :: %{
          total_items: non_neg_integer()
        }

  @doc """
  Sketch of an experiment runner that evaluates a workflow against many inputs.

  This function is intentionally conservative: it starts a real Synaptic
  workflow for each input using `Synaptic.start/3` and waits for completion
  using `Synaptic.inspect/1`. Scorer execution is still driven by
  `Synaptic.Runner` just like in normal production runs.

  Returns an opaque result map for now, primarily for future extension. The
  main integration point for host applications is still Telemetry
  (e.g. `[:synaptic, :scorer]` and workflow-level events).
  """
  @spec run_experiment(module(), [data_item()], keyword()) :: %{
          summary: summary()
        }
  def run_experiment(workflow_module, data_items, _opts \\ [])
      when is_atom(workflow_module) and is_list(data_items) do
    Enum.each(data_items, fn %{input: input} = _item ->
      {:ok, run_id} = Synaptic.start(workflow_module, input)

      wait_for_completion(run_id)
    end)

    %{
      summary: %{
        total_items: length(data_items)
      }
    }
  end

  defp wait_for_completion(run_id, attempts \\ 100)
  defp wait_for_completion(_run_id, 0), do: :ok

  defp wait_for_completion(run_id, attempts) do
    snapshot = Synaptic.inspect(run_id)

    case snapshot.status do
      status when status in [:completed, :failed, :stopped] ->
        :ok

      _ ->
        Process.sleep(25)
        wait_for_completion(run_id, attempts - 1)
    end
  end
end
