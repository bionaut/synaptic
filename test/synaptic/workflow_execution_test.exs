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

  defmodule MultiStepWorkflow do
    use Synaptic.Workflow

    step :first do
      send(context.test_pid, {:step_executed, :first})
      {:ok, %{first_result: "first", order: [:first]}}
    end

    step :second do
      send(context.test_pid, {:step_executed, :second})
      {:ok, %{second_result: "second", order: context.order ++ [:second]}}
    end

    step :third do
      send(context.test_pid, {:step_executed, :third})
      {:ok, %{third_result: "third", order: context.order ++ [:third]}}
    end

    step :final do
      send(context.test_pid, {:step_executed, :final})
      {:ok, %{final_result: "done", order: context.order ++ [:final]}}
    end

    commit()
  end

  defmodule StopSequentialWorkflow do
    use Synaptic.Workflow

    step :validate do
      {:stop, :validation_failed}
    end

    step :should_not_run do
      send(context.test_pid, :should_not_run)
      {:ok, %{}}
    end

    commit()
  end

  defmodule StopAsyncWorkflow do
    use Synaptic.Workflow

    step :prepare do
      send(context.test_pid, {:step, :prepare})
      {:ok, %{order: [:prepare]}}
    end

    async_step :maybe_stop, retry: 3 do
      send(context.test_pid, :async_started)
      {:stop, :user_rejected}
    end

    step :after_async do
      send(context.test_pid, :after_async_should_not_run)
      {:ok, %{after: true}}
    end

    commit()
  end

  defmodule StopParallelWorkflow do
    use Synaptic.Workflow

    parallel_step :generate_parts do
      [
        fn ctx ->
          send(ctx.test_pid, {:task_started, :title})
          {:ok, %{title: "Title for #{ctx.base}"}}
        end,
        fn ctx ->
          send(ctx.test_pid, {:task_started, :stopper})
          {:stop, :abort}
        end
      ]
    end

    step :after_parallel do
      send(context.test_pid, :after_parallel_should_not_run)
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

  test "sequential {:stop, reason} stops the workflow without running later steps" do
    parent = self()
    {:ok, run_id} = Synaptic.start(StopSequentialWorkflow, %{test_pid: parent})

    snapshot = wait_for(run_id, :stopped)

    assert snapshot.status == :stopped
    assert snapshot.current_step == :validate

    history = Synaptic.history(run_id)
    assert Enum.any?(history, &(&1[:event] == :stopped and &1[:reason] == :validation_failed))

    refute_receive :should_not_run, 100
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

  test "parallel {:stop, reason} stops the workflow and does not run later steps" do
    parent = self()
    {:ok, run_id} = Synaptic.start(StopParallelWorkflow, %{base: 5, test_pid: parent})

    # At least one task should start
    assert_receive {:task_started, :title}, 500
    assert_receive {:task_started, :stopper}, 500

    snapshot = wait_for(run_id, :stopped)

    assert snapshot.status == :stopped

    history = Synaptic.history(run_id)
    assert Enum.any?(history, &(&1[:event] == :stopped and &1[:reason] == :abort))

    # Ensure step after parallel did not run
    refute_receive :after_parallel_should_not_run, 100
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

  test "async {:stop, reason} stops the workflow without retries" do
    parent = self()
    {:ok, run_id} = Synaptic.start(StopAsyncWorkflow, %{test_pid: parent})

    assert_receive {:step, :prepare}, 500
    assert_receive :async_started, 500

    snapshot = wait_for(run_id, :stopped)

    assert snapshot.status == :stopped

    history = Synaptic.history(run_id)

    # Ensure :stopped event is present
    assert Enum.any?(history, &(&1[:event] == :stopped and &1[:reason] == :user_rejected))

    # Ensure no retrying events occurred despite retry: 3
    refute Enum.any?(history, &(&1[:event] == :retrying))
  end

  test "start at specific step by name" do
    parent = self()
    context = %{test_pid: parent, first_result: "precomputed", order: [:first]}

    {:ok, run_id} = Synaptic.start(MultiStepWorkflow, context, start_at_step: :second)

    # Should not execute first step
    refute_receive {:step_executed, :first}, 100

    # Should execute from second step onwards
    assert_receive {:step_executed, :second}, 500
    assert_receive {:step_executed, :third}, 500
    assert_receive {:step_executed, :final}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:order] == [:first, :second, :third, :final]
    assert snapshot.context[:first_result] == "precomputed"
    assert snapshot.context[:second_result] == "second"
    assert snapshot.context[:third_result] == "third"
    assert snapshot.context[:final_result] == "done"
  end

  test "start at last step" do
    parent = self()

    context = %{
      test_pid: parent,
      first_result: "precomputed",
      second_result: "precomputed",
      third_result: "precomputed",
      order: [:first, :second, :third]
    }

    {:ok, run_id} = Synaptic.start(MultiStepWorkflow, context, start_at_step: :final)

    # Should not execute earlier steps
    refute_receive {:step_executed, :first}, 100
    refute_receive {:step_executed, :second}, 100
    refute_receive {:step_executed, :third}, 100

    # Should only execute final step
    assert_receive {:step_executed, :final}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:order] == [:first, :second, :third, :final]
    assert snapshot.context[:final_result] == "done"
  end

  test "start at step 0 behaves like normal start" do
    parent = self()
    {:ok, run_id} = Synaptic.start(MultiStepWorkflow, %{test_pid: parent}, start_at_step: :first)

    assert_receive {:step_executed, :first}, 500
    assert_receive {:step_executed, :second}, 500
    assert_receive {:step_executed, :third}, 500
    assert_receive {:step_executed, :final}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:order] == [:first, :second, :third, :final]
  end

  test "rejects invalid step name" do
    assert {:error, :invalid_step} =
             Synaptic.start(MultiStepWorkflow, %{}, start_at_step: :nonexistent)
  end

  test "context is properly initialized when starting at specific step" do
    parent = self()
    # Provide context that simulates what would have been accumulated up to step 3
    context = %{
      test_pid: parent,
      first_result: "from_step_1",
      second_result: "from_step_2",
      third_result: "from_step_3",
      order: [:first, :second, :third],
      custom_data: "preserved"
    }

    {:ok, run_id} = Synaptic.start(MultiStepWorkflow, context, start_at_step: :final)

    snapshot = wait_for(run_id, :completed)

    # All context should be preserved
    assert snapshot.context[:first_result] == "from_step_1"
    assert snapshot.context[:second_result] == "from_step_2"
    assert snapshot.context[:third_result] == "from_step_3"
    assert snapshot.context[:custom_data] == "preserved"
    assert snapshot.context[:order] == [:first, :second, :third, :final]
  end

  test "starting at middle step with approval workflow" do
    # Start at finalize step with pre-approved context
    context = %{approval: true}

    {:ok, run_id} = Synaptic.start(ApprovalWorkflow, context, start_at_step: :finalize)

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:status] == :approved
    assert snapshot.current_step == nil
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
