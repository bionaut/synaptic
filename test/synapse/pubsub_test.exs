defmodule Synapse.PubSubTest do
  use ExUnit.Case

  defmodule QuestionsWorkflow do
    use Synapse.Workflow

    step :pause, suspend: true, resume_schema: %{answer: :boolean} do
      case get_in(context, [:human_input, :answer]) do
        nil -> suspend_for_human("Need answer")
        answer -> {:ok, %{answer: answer}}
      end
    end

    step :finish do
      {:ok, %{done: true}}
    end

    commit()
  end

  test "publishes events for a workflow run" do
    {:ok, run_id} = Synapse.start(QuestionsWorkflow, %{})
    :ok = Synapse.subscribe(run_id)
    drain_events()

    :ok = Synapse.resume(run_id, %{answer: true})

    assert_receive {:synapse_event, %{event: :resumed, run_id: ^run_id}}, 1_000

    assert_receive {:synapse_event, %{event: :step_completed, step: :pause, run_id: ^run_id}},
                   1_000

    assert_receive {:synapse_event, %{event: :step_completed, step: :finish, run_id: ^run_id}},
                   1_000

    assert_receive {:synapse_event, %{event: :completed, run_id: ^run_id}}, 1_000

    Synapse.unsubscribe(run_id)
  end

  defp drain_events do
    receive do
      {:synapse_event, _} -> drain_events()
    after
      50 -> :ok
    end
  end
end
