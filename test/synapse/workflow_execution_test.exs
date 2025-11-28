defmodule Synapse.WorkflowExecutionTest do
  use ExUnit.Case

  defmodule ApprovalWorkflow do
    use Synapse.Workflow

    step :prepare, output: %{prepared: :boolean} do
      {:ok, %{prepared: true}}
    end

    step :human_review,
      suspend: true,
      resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil -> suspend_for_human("Please approve the prepared payload")
        true -> {:ok, %{approval: true}}
        false -> {:error, :rejected}
      end
    end

    step :finalize do
      if Map.get(context, :approval) do
        {:ok, %{status: :approved}}
      else
        {:error, :rejected}
      end
    end

    commit()
  end

  defmodule AlwaysFailWorkflow do
    use Synapse.Workflow

    step :flaky, retry: 1 do
      {:error, :boom}
    end

    commit()
  end

  test "workflow suspends and resumes" do
    {:ok, run_id} = Synapse.start(ApprovalWorkflow, %{})

    assert %{status: :waiting_for_human, current_step: :human_review} = Synapse.inspect(run_id)

    assert :ok = Synapse.resume(run_id, %{approved: true})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:status] == :approved
    assert List.last(Synapse.history(run_id))[:event] == :completed
  end

  test "rejects invalid resume payload" do
    {:ok, run_id} = Synapse.start(ApprovalWorkflow, %{})

    assert {:error, {:missing_fields, [:approved]}} = Synapse.resume(run_id, %{})
  end

  test "step retries before failing" do
    {:ok, run_id} = Synapse.start(AlwaysFailWorkflow, %{})
    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error == :boom
    history = Synapse.history(run_id)
    assert Enum.count(Enum.filter(history, &(&1[:status] == :error))) >= 1
  end

  defp wait_for(run_id, status, attempts \\ 20)
  defp wait_for(_run_id, _status, 0), do: flunk("workflow did not reach desired status")

  defp wait_for(run_id, status, attempts) do
    snapshot = Synapse.inspect(run_id)

    if snapshot.status == status do
      snapshot
    else
      Process.sleep(25)
      wait_for(run_id, status, attempts - 1)
    end
  end
end
