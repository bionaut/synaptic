defmodule Synaptic.TestRunner.ResultFormatter do
  @moduledoc """
  Formats test results for console and JSON output.
  """

  @doc """
  Formats test results for console output.
  """
  def format_console(test_name, result) do
    separator = String.duplicate("=", 80)

    [
      "\n",
      separator,
      "\n",
      "Test: #{test_name}\n",
      separator,
      "\n\n",
      format_status_console(result),
      format_validation_console(result),
      format_context_console(result),
      format_errors_console(result),
      "\n"
    ]
    |> Enum.join("")
  end

  @doc """
  Formats test results as JSON.
  """
  def format_json(test_name, result) do
    json_result = %{
      test_name: test_name,
      workflow: result.workflow,
      run_id: result.run_id,
      status: result.status,
      validation: result.validation,
      context: result.context,
      error: result.error,
      execution_time_ms: result.execution_time_ms
    }

    Jason.encode!(json_result, pretty: true)
  end

  defp format_status_console(result) do
    status_icon =
      case result.status do
        :success -> "✓"
        :failed -> "✗"
        :timeout -> "⏱"
        :error -> "⚠"
        _ -> "?"
      end

    status_text =
      case result.status do
        :success -> "PASSED"
        :failed -> "FAILED"
        :timeout -> "TIMEOUT"
        :error -> "ERROR"
        _ -> "UNKNOWN"
      end

    "#{status_icon} Status: #{status_text}\n"
  end

  defp format_validation_console(result) do
    case result.validation do
      nil ->
        ""

      validation ->
        [
          "\nValidation Results:\n",
          "  Status Check: ",
          format_validation_item(validation.status),
          "\n",
          "  Context Check: ",
          format_validation_item(validation.context),
          "\n"
        ]
        |> Enum.join("")
    end
  end

  defp format_validation_item(%{valid: true, message: message}) do
    "✓ #{message}"
  end

  defp format_validation_item(%{valid: false, message: message}) do
    "✗ #{message}"
  end

  defp format_validation_item(%{fields: fields} = result) when is_list(fields) do
    if result.valid do
      "✓ #{result.message}"
    else
      field_messages =
        fields
        |> Enum.map(fn field -> "    - #{field.message}\n" end)
        |> Enum.join("")

      "✗ #{result.message}\n" <> field_messages
    end
  end

  defp format_validation_item(_), do: "?"

  defp format_context_console(result) do
    if result.context do
      "\nFinal Context:\n" <> format_map(result.context, "  ") <> "\n"
    else
      ""
    end
  end

  defp format_errors_console(result) do
    if result.error do
      "\nError: #{inspect(result.error)}\n"
    else
      ""
    end
  end

  defp format_map(map, indent) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      formatted_value = format_value(value, indent <> "  ")
      "#{indent}#{key}: #{formatted_value}\n"
    end)
    |> Enum.join("")
  end

  defp format_value(value, indent) when is_map(value) do
    "\n" <> format_map(value, indent)
  end

  defp format_value(value, _indent) when is_list(value) do
    inspect(value, limit: :infinity, pretty: true)
  end

  defp format_value(value, _indent) when is_binary(value) do
    # Truncate long strings
    if String.length(value) > 200 do
      String.slice(value, 0, 200) <> "... (truncated)"
    else
      value
    end
  end

  defp format_value(value, _indent), do: inspect(value, limit: :infinity)
end
