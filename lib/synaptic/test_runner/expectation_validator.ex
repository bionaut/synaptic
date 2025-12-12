defmodule Synaptic.TestRunner.ExpectationValidator do
  @moduledoc """
  Validates test expectations against workflow execution results.
  Supports regex matching for context field values.
  """

  @doc """
  Validates expectations against a workflow snapshot.

  Returns `{:ok, validation_results}` where validation_results is a map
  with `:status`, `:context`, and `:all_passed` keys.
  """
  def validate(_snapshot, expectations) when is_nil(expectations) do
    {:ok, %{status: :skipped, context: :skipped, all_passed: true}}
  end

  def validate(snapshot, expectations) when is_map(expectations) do
    status_result = validate_status(snapshot, expectations)
    context_result = validate_context(snapshot, expectations)

    all_passed = status_result.valid and context_result.valid

    {:ok,
     %{
       status: status_result,
       context: context_result,
       all_passed: all_passed
     }}
  end

  defp validate_status(snapshot, expectations) do
    expected_status = Map.get(expectations, :status)

    if is_nil(expected_status) do
      %{valid: true, message: "Status check skipped"}
    else
      actual_status = Atom.to_string(snapshot.status)
      expected_status_str = String.downcase(to_string(expected_status))

      valid = String.downcase(actual_status) == expected_status_str

      %{
        valid: valid,
        expected: expected_status_str,
        actual: actual_status,
        message:
          if valid do
            "Status matches: #{actual_status}"
          else
            "Status mismatch: expected #{expected_status_str}, got #{actual_status}"
          end
      }
    end
  end

  defp validate_context(snapshot, expectations) do
    expected_context = Map.get(expectations, :context, %{})

    if map_size(expected_context) == 0 do
      %{valid: true, message: "Context check skipped", fields: []}
    else
      results =
        expected_context
        |> Enum.map(fn {field_path, expected_pattern} ->
          validate_context_field(snapshot.context, field_path, expected_pattern)
        end)

      all_valid = Enum.all?(results, & &1.valid)

      %{
        valid: all_valid,
        message:
          if all_valid do
            "All context fields match"
          else
            "Some context fields did not match"
          end,
        fields: results
      }
    end
  end

  defp validate_context_field(context, field_path, expected_pattern) when is_binary(field_path) do
    # Support dot notation for nested paths (e.g., "user.name")
    path_parts = String.split(field_path, ".")

    actual_value =
      case get_nested_value(context, path_parts) do
        nil -> nil
        value -> to_string(value)
      end

    if is_nil(actual_value) do
      %{
        valid: false,
        field: field_path,
        expected: expected_pattern,
        actual: nil,
        message: "Field '#{field_path}' not found in context"
      }
    else
      # Try regex match first, fall back to exact match if regex fails
      matches =
        case Regex.compile(expected_pattern) do
          {:ok, regex} ->
            Regex.match?(regex, actual_value)

          {:error, _} ->
            # If regex compilation fails, treat as exact string match
            actual_value == expected_pattern
        end

      %{
        valid: matches,
        field: field_path,
        expected: expected_pattern,
        actual: actual_value,
        message:
          if matches do
            "Field '#{field_path}' matches pattern"
          else
            "Field '#{field_path}' does not match pattern: expected pattern '#{expected_pattern}', got '#{actual_value}'"
          end
      }
    end
  end

  defp get_nested_value(map, [key]) when is_map(map) do
    # Try atom key first, then string key
    atom_key = String.to_atom(key)
    Map.get(map, atom_key) || Map.get(map, key)
  end

  defp get_nested_value(map, [key | rest]) when is_map(map) do
    # Try atom key first, then string key
    atom_key = String.to_atom(key)
    value = Map.get(map, atom_key) || Map.get(map, key)

    if value do
      get_nested_value(value, rest)
    else
      nil
    end
  end

  defp get_nested_value(_value, _rest), do: nil
end
