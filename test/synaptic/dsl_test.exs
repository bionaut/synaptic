defmodule Synaptic.DSLTest do
  use ExUnit.Case, async: true

  defmodule ExampleWorkflow do
    use Synaptic.Workflow

    step :greet, input: %{name: :string}, output: %{greeting: :string} do
      name = Map.get(context, :name, "world")
      {:ok, %{greeting: "hello #{name}"}}
    end

    step :review, suspend: true, resume_schema: %{approved: :boolean} do
      suspend_for_human("Approve?", %{intent: :greeting})
    end

    step :finalize do
      human_decision = get_in(context, [:human_input, :approved])
      {:ok, %{approved: human_decision}}
    end

    commit()
  end

  defmodule ParallelWorkflow do
    use Synaptic.Workflow

    parallel_step :fan_out do
      [
        fn _ctx -> {:ok, %{first: true}} end,
        fn _ctx -> {:ok, %{second: true}} end
      ]
    end

    commit()
  end

  defmodule AsyncWorkflow do
    use Synaptic.Workflow

    async_step :notify do
      {:ok, %{fired: true}}
    end

    commit()
  end

  test "workflow definition includes ordered step metadata" do
    definition = Synaptic.workflow_definition(ExampleWorkflow)

    assert definition.module == ExampleWorkflow
    assert Enum.map(definition.steps, & &1.name) == [:greet, :review, :finalize]
    assert Enum.at(definition.steps, 1).resume_schema == %{approved: :boolean}
  end

  test "parallel steps are marked in the workflow definition" do
    definition = Synaptic.workflow_definition(ParallelWorkflow)
    [step] = definition.steps

    assert step.type == :parallel
  end

  test "async steps are marked in the workflow definition" do
    definition = Synaptic.workflow_definition(AsyncWorkflow)
    [step] = definition.steps

    assert step.type == :async
  end

  test "suspend_for_human helper formats payload" do
    assert {:suspend, %{message: "Need help", metadata: %{}}} =
             Synaptic.Workflow.suspend_for_human("Need help")
  end
end
