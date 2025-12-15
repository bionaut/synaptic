defmodule Synaptic.TestRunner.YamlParser do
  @moduledoc """
  Parses and validates YAML test definition files for Synaptic workflows.
  """

  @doc """
  Loads and parses a YAML test file.

  Returns `{:ok, test_definition}` or `{:error, reason}`.
  """
  def load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        parse(content)

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  @doc """
  Parses YAML content into a test definition map.

  Returns `{:ok, test_definition}` or `{:error, reason}`.
  """
  def parse(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, data} ->
        validate_test_definition(data)

      {:error, reason} ->
        {:error, {:yaml_parse_error, reason}}
    end
  end

  defp validate_test_definition(data) when is_map(data) do
    with :ok <- validate_required_fields(data),
         :ok <- validate_workflow_module(data),
         :ok <- validate_input(data),
         :ok <- validate_start_at_step(data),
         :ok <- validate_expectations(data),
         :ok <- validate_skip_side_effects(data) do
      {:ok, normalize_test_definition(data)}
    end
  end

  defp validate_test_definition(_), do: {:error, :invalid_yaml_structure}

  defp validate_required_fields(data) do
    cond do
      not Map.has_key?(data, "workflow") ->
        {:error, :missing_workflow}

      not Map.has_key?(data, "input") ->
        {:error, :missing_input}

      true ->
        :ok
    end
  end

  defp validate_workflow_module(data) do
    workflow = Map.get(data, "workflow")

    if is_binary(workflow) and workflow != "" do
      :ok
    else
      {:error, :invalid_workflow_module}
    end
  end

  defp validate_input(data) do
    input = Map.get(data, "input")

    if is_map(input) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp validate_start_at_step(data) do
    case Map.get(data, "start_at_step") do
      nil -> :ok
      step when is_binary(step) -> :ok
      _ -> {:error, :invalid_start_at_step}
    end
  end

  defp validate_expectations(data) do
    case Map.get(data, "expectations") do
      nil -> :ok
      expectations when is_map(expectations) -> :ok
      _ -> {:error, :invalid_expectations}
    end
  end

  defp validate_skip_side_effects(data) do
    case Map.get(data, "skip_side_effects") do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, :invalid_skip_side_effects}
    end
  end

  defp normalize_test_definition(data) do
    %{
      name: Map.get(data, "name", "Unnamed test"),
      workflow: Map.get(data, "workflow"),
      input: normalize_input(Map.get(data, "input", %{})),
      start_at_step: normalize_start_at_step(Map.get(data, "start_at_step")),
      expectations: normalize_expectations(Map.get(data, "expectations")),
      skip_side_effects: Map.get(data, "skip_side_effects", false)
    }
  end

  defp normalize_input(input) when is_map(input) do
    # Convert string keys to atoms where appropriate, keep as strings for now
    # since context keys can be strings
    input
  end

  defp normalize_start_at_step(nil), do: nil
  defp normalize_start_at_step(step) when is_binary(step), do: String.to_atom(step)

  defp normalize_expectations(nil), do: nil

  defp normalize_expectations(expectations) when is_map(expectations) do
    %{
      status: Map.get(expectations, "status"),
      context: Map.get(expectations, "context", %{})
    }
  end
end
