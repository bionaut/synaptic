defmodule Synaptic.WorkflowExecutionTest do
  use ExUnit.Case

  defmodule ApprovalWorkflow do
    use Synaptic.Workflow

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
    use Synaptic.Workflow

    step :flaky, retry: 1 do
      {:error, :boom}
    end

    commit()
  end

  defmodule ParallelWorkflow do
    use Synaptic.Workflow

    parallel_step :generate_parts do
      [
        fn ctx ->
          send(ctx.test_pid, {:task_started, :title})
          Process.sleep(25)
          {:ok, %{title: "Title for #{ctx.base}"}}
        end,
        fn ctx ->
          send(ctx.test_pid, {:task_started, :metadata})
          {:ok, %{metadata: ctx.base * 2}}
        end
      ]
    end

    step :finalize do
      if Map.has_key?(context, :title) and Map.get(context, :metadata) do
        {:ok, %{status: :assembled}}
      else
        {:error, :missing_parallel_results}
      end
    end

    commit()
  end

  defmodule AsyncWorkflow do
    use Synaptic.Workflow

    step :prepare do
      send(context.test_pid, {:step, :prepare})
      {:ok, %{order: [:prepare]}}
    end

    async_step :notify do
      send(context.test_pid, {:async_started, Map.get(context, :order)})
      Process.sleep(50)
      send(context.test_pid, {:async_done, Map.get(context, :order)})
      {:ok, %{async_result: true}}
    end

    step :finalize do
      send(context.test_pid, {:final_step, Map.get(context, :async_result, false)})
      {:ok, %{status: Map.get(context, :async_result, false)}}
    end

    commit()
  end

  defmodule AsyncFailureWorkflow do
    use Synaptic.Workflow

    async_step :flaky, retry: 1 do
      Process.sleep(30)
      {:error, :boom}
    end

    step :after_async do
      send(context.test_pid, :after_async)
      {:ok, %{after: true}}
    end

    commit()
  end

  test "workflow suspends and resumes" do
    {:ok, run_id} = Synaptic.start(ApprovalWorkflow, %{})

    assert %{status: :waiting_for_human, current_step: :human_review} = Synaptic.inspect(run_id)

    assert :ok = Synaptic.resume(run_id, %{approved: true})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:status] == :approved
    assert List.last(Synaptic.history(run_id))[:event] == :completed
  end

  test "rejects invalid resume payload" do
    {:ok, run_id} = Synaptic.start(ApprovalWorkflow, %{})

    assert {:error, {:missing_fields, [:approved]}} = Synaptic.resume(run_id, %{})
  end

  test "step retries before failing" do
    {:ok, run_id} = Synaptic.start(AlwaysFailWorkflow, %{})
    snapshot = wait_for(run_id, :failed)

    assert snapshot.last_error == :boom
    history = Synaptic.history(run_id)
    assert Enum.count(Enum.filter(history, &(&1[:status] == :error))) >= 1
  end

  test "stop halts a workflow and emits event" do
    {:ok, run_id} = Synaptic.start(ApprovalWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    :ok = Synaptic.subscribe(run_id)
    on_exit(fn -> Synaptic.unsubscribe(run_id) end)

    assert :ok = Synaptic.stop(run_id, :user_cancelled)

    assert_receive {:synaptic_event,
                    %{event: :stopped, reason: :user_cancelled, run_id: ^run_id}},
                   1_000

    assert {:error, :not_found} = Synaptic.stop(run_id)
  end

  test "parallel steps run each task and merge context" do
    parent = self()
    {:ok, run_id} = Synaptic.start(ParallelWorkflow, %{base: 5, test_pid: parent})
    snapshot = wait_for(run_id, :completed)

    assert snapshot.context[:status] == :assembled
    assert_receive {:task_started, :title}, 500
    assert_receive {:task_started, :metadata}, 500
  end

  test "async steps continue the workflow while running in the background" do
    parent = self()
    {:ok, run_id} = Synaptic.start(AsyncWorkflow, %{test_pid: parent})

    assert_receive {:step, :prepare}, 500
    assert_receive {:async_started, [:prepare]}, 500
    assert_receive {:final_step, false}, 500

    assert Synaptic.inspect(run_id).status == :running

    assert_receive {:async_done, [:prepare]}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:async_result]
  end

  test "async step failures propagate after retries" do
    parent = self()
    {:ok, run_id} = Synaptic.start(AsyncFailureWorkflow, %{test_pid: parent})

    assert_receive :after_async, 500

    snapshot = wait_for(run_id, :failed)
    assert snapshot.last_error == :boom
    assert snapshot.context[:after]
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
