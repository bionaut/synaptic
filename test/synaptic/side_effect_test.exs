defmodule Synaptic.SideEffectTest do
  use ExUnit.Case

  defmodule WorkflowWithBasicSideEffect do
    use Synaptic.Workflow

    step :step_with_side_effect do
      result =
        side_effect do
          send(context.test_pid, {:side_effect_executed, :normal})
          {:ok, :executed}
        end

      {:ok, %{side_effect_result: result}}
    end

    commit()
  end

  defmodule WorkflowWithDefaultValue do
    use Synaptic.Workflow

    step :step_with_default_value do
      result =
        side_effect default: {:ok, %{id: 123, mocked: true}} do
          send(context.test_pid, {:side_effect_executed, :with_default})
          {:ok, %{id: 456, real: true}}
        end

      {:ok, %{side_effect_result: result}}
    end

    commit()
  end

  defmodule WorkflowWithNormalStep do
    use Synaptic.Workflow

    step :step_with_side_effect do
      result =
        side_effect do
          send(context.test_pid, {:side_effect_executed, :normal})
          {:ok, :executed}
        end

      {:ok, %{side_effect_result: result}}
    end

    step :step_without_side_effect do
      send(context.test_pid, {:normal_step_executed})
      {:ok, %{normal: true}}
    end

    commit()
  end

  defmodule WorkflowWithMultipleSideEffects do
    use Synaptic.Workflow

    step :first_side_effect do
      result1 =
        side_effect do
          send(context.test_pid, {:side_effect_1, :executed})
          :result1
        end

      result2 =
        side_effect default: :mocked_result2 do
          send(context.test_pid, {:side_effect_2, :executed})
          :result2
        end

      {:ok, %{result1: result1, result2: result2}}
    end

    step :second_step do
      {:ok, %{continued: true}}
    end

    commit()
  end

  test "side_effect executes normally when flag is not set" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithBasicSideEffect, %{test_pid: parent})

    assert_receive {:side_effect_executed, :normal}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:side_effect_result] == {:ok, :executed}
  end

  test "side_effect is skipped when __skip_side_effects__ flag is true" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithNormalStep, %{
        test_pid: parent,
        __skip_side_effects__: true
      })

    # Side effect should NOT execute
    refute_receive {:side_effect_executed, :normal}, 100

    # Normal step should still execute
    assert_receive {:normal_step_executed}, 500

    snapshot = wait_for(run_id, :completed)
    # Should return :ok (default) when skipped
    assert snapshot.context[:side_effect_result] == :ok
    assert snapshot.context[:normal] == true
  end

  test "side_effect returns default value when skipped" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithDefaultValue, %{
        test_pid: parent,
        __skip_side_effects__: true
      })

    snapshot = wait_for(run_id, :completed)

    # Should return the default value specified
    assert snapshot.context[:side_effect_result] == {:ok, %{id: 123, mocked: true}}
  end

  test "side_effect executes normally when flag is false" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithBasicSideEffect, %{
        test_pid: parent,
        __skip_side_effects__: false
      })

    assert_receive {:side_effect_executed, :normal}, 500

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:side_effect_result] == {:ok, :executed}
  end

  test "multiple side_effect blocks are all skipped when flag is set" do
    parent = self()

    {:ok, run_id} =
      Synaptic.start(WorkflowWithMultipleSideEffects, %{
        test_pid: parent,
        __skip_side_effects__: true
      })

    # Neither side effect should execute
    refute_receive {:side_effect_1, :executed}, 100
    refute_receive {:side_effect_2, :executed}, 100

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context[:result1] == :ok
    assert snapshot.context[:result2] == :mocked_result2
    assert snapshot.context[:continued] == true
  end

  test "side_effect flag persists through context updates" do
    defmodule PersistenceTestWorkflow do
      use Synaptic.Workflow

      step :first do
        {:ok, %{first: true}}
      end

      step :second do
        result =
          side_effect do
            send(context.test_pid, {:side_effect_in_second_step})
            :executed
          end

        {:ok, %{second: true, side_effect_result: result}}
      end

      commit()
    end

    parent = self()

    {:ok, run_id} =
      Synaptic.start(PersistenceTestWorkflow, %{
        test_pid: parent,
        __skip_side_effects__: true
      })

    snapshot = wait_for(run_id, :completed)
    refute_receive {:side_effect_in_second_step}, 100
    assert snapshot.context[:side_effect_result] == :ok
    assert snapshot.context[:first] == true
    assert snapshot.context[:second] == true
  end

  test "side_effect works in parallel steps" do
    defmodule ParallelSideEffectWorkflow do
      use Synaptic.Workflow

      parallel_step :parallel_with_side_effects do
        [
          fn ctx ->
            result =
              side_effect do
                send(ctx.test_pid, {:parallel_side_effect_1})
                :executed1
              end

            {:ok, %{parallel_result1: result}}
          end,
          fn ctx ->
            result =
              side_effect default: :mocked2 do
                send(ctx.test_pid, {:parallel_side_effect_2})
                :executed2
              end

            {:ok, %{parallel_result2: result}}
          end
        ]
      end

      commit()
    end

    parent = self()

    {:ok, run_id} =
      Synaptic.start(ParallelSideEffectWorkflow, %{
        test_pid: parent,
        __skip_side_effects__: true
      })

    snapshot = wait_for(run_id, :completed)
    refute_receive {:parallel_side_effect_1}, 100
    refute_receive {:parallel_side_effect_2}, 100
    assert snapshot.context[:parallel_result1] == :ok
    assert snapshot.context[:parallel_result2] == :mocked2
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
