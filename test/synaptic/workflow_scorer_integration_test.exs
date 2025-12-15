defmodule Synaptic.WorkflowScorerIntegrationTest do
  use ExUnit.Case

  alias Synaptic.Scorer.Result

  defmodule WorkflowWithScorer do
    use Synaptic.Workflow

    defmodule SimpleScorer do
      @behaviour Synaptic.Scorer

      alias Synaptic.Scorer.{Context, Result}

      @impl true
      def score(
            %Context{step: step, run_id: run_id, output: output, pre_context: pre_ctx},
            _metadata
          ) do
        send(pre_ctx.test_pid, {:scored, step.name, run_id, output})

        Result.new(
          name: "simple_scorer",
          step: step.name,
          run_id: run_id,
          score: 1.0,
          reason: "ok",
          details: %{output_keys: Map.keys(output)}
        )
      end
    end

    step :first,
      scorers: [{SimpleScorer, [mode: :async]}] do
      {:ok, %{first: true}}
    end

    step :second do
      {:ok, %{second: true}}
    end

    commit()
  end

  test "attached scorers run after successful step and can observe output" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithScorer, %{
        test_pid: parent
      })

    # scorer should be invoked for the first step
    assert_receive {:scored, :first, ^run_id, %{first: true}}, 1_000

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:first] == true
    assert snapshot.context[:second] == true
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
