defmodule Synaptic.TestRunnerSideEffectTest do
  use ExUnit.Case

  alias Synaptic.TestRunner.YamlParser

  defmodule TestWorkflowWithSideEffects do
    use Synaptic.Workflow

    step :process do
      result =
        side_effect do
          # This would normally do something like Database.insert()
          :real_execution
        end

      {:ok, %{processed: true, side_effect_result: result}}
    end

    commit()
  end

  test "YAML parser parses skip_side_effects field" do
    yaml = """
    name: "Test"
    workflow: "TestWorkflow"
    input:
      key: "value"
    skip_side_effects: true
    """

    {:ok, definition} = YamlParser.parse(yaml)
    assert definition.skip_side_effects == true
  end

  test "YAML parser defaults skip_side_effects to false" do
    yaml = """
    name: "Test"
    workflow: "TestWorkflow"
    input:
      key: "value"
    """

    {:ok, definition} = YamlParser.parse(yaml)
    assert definition.skip_side_effects == false
  end

  test "YAML parser validates skip_side_effects as boolean" do
    yaml = """
    name: "Test"
    workflow: "TestWorkflow"
    input:
      key: "value"
    skip_side_effects: "not a boolean"
    """

    assert {:error, :invalid_skip_side_effects} = YamlParser.parse(yaml)
  end

  test "test runner injects __skip_side_effects__ flag when YAML has skip_side_effects: true" do
    # Create a temporary YAML file
    yaml_content = """
    name: "Side Effect Test"
    workflow: "Synaptic.TestRunnerSideEffectTest.TestWorkflowWithSideEffects"
    input:
      test_data: "value"
    skip_side_effects: true
    """

    {:ok, test_definition} = YamlParser.parse(yaml_content)

    # Verify the flag would be injected
    assert test_definition.skip_side_effects == true

    # Run the test
    {:ok, result} = Synaptic.TestRunner.run_test(test_definition)

    # Verify workflow completed
    assert result.status == :success

    # Verify side effect was skipped (returns :ok by default)
    assert result.context[:side_effect_result] == :ok
    assert result.context[:processed] == true
  end

  test "test runner does not inject flag when skip_side_effects is false" do
    yaml_content = """
    name: "Normal Test"
    workflow: "Synaptic.TestRunnerSideEffectTest.TestWorkflowWithSideEffects"
    input:
      test_data: "value"
    skip_side_effects: false
    """

    {:ok, test_definition} = YamlParser.parse(yaml_content)
    assert test_definition.skip_side_effects == false

    {:ok, result} = Synaptic.TestRunner.run_test(test_definition)

    assert result.status == :success
    # Side effect should execute normally
    assert result.context[:side_effect_result] == :real_execution
  end

  test "test runner handles missing skip_side_effects field" do
    yaml_content = """
    name: "Test Without Flag"
    workflow: "Synaptic.TestRunnerSideEffectTest.TestWorkflowWithSideEffects"
    input:
      test_data: "value"
    """

    {:ok, test_definition} = YamlParser.parse(yaml_content)
    assert test_definition.skip_side_effects == false

    {:ok, result} = Synaptic.TestRunner.run_test(test_definition)

    assert result.status == :success
    # Should execute normally when flag is not set
    assert result.context[:side_effect_result] == :real_execution
  end
end
