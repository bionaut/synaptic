defmodule Synapse.DSLTest do
  use ExUnit.Case, async: true

  defmodule ExampleWorkflow do
    use Synapse.Workflow

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

  test "workflow definition includes ordered step metadata" do
    definition = Synapse.workflow_definition(ExampleWorkflow)

    assert definition.module == ExampleWorkflow
    assert Enum.map(definition.steps, & &1.name) == [:greet, :review, :finalize]
    assert Enum.at(definition.steps, 1).resume_schema == %{approved: :boolean}
  end

  test "suspend_for_human helper formats payload" do
    assert {:suspend, %{message: "Need help", metadata: %{}}} =
             Synapse.Workflow.suspend_for_human("Need help")
  end
end
