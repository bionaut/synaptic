# Test runner script for Synaptic workflows
# Usage: mix run scripts/run_tests.exs <yaml_file> [--format console|json|both] [--timeout <ms>]

alias Synaptic.TestRunner

defmodule RunTestsScript do
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        run_tests(opts)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        print_usage()
        System.halt(1)
    end
  end

  defp parse_args(args) do
    case args do
      [] ->
        {:error, "No YAML file specified"}

      [file_path | rest] ->
        opts = parse_options(rest, file: file_path)
        {:ok, opts}

      _ ->
        {:error, "Invalid arguments"}
    end
  end

  defp parse_options([], acc), do: acc

  defp parse_options(["--format", format | rest], acc) do
    format_atom =
      case format do
        "console" -> :console
        "json" -> :json
        "both" -> :both
        _ -> :both
      end

    parse_options(rest, Keyword.put(acc, :format, format_atom))
  end

  defp parse_options(["--timeout", timeout_str | rest], acc) do
    case Integer.parse(timeout_str) do
      {timeout, _} ->
        parse_options(rest, Keyword.put(acc, :timeout, timeout))

      :error ->
        parse_options(rest, acc)
    end
  end

  defp parse_options([_unknown | rest], acc) do
    parse_options(rest, acc)
  end

  defp run_tests(opts) do
    file_path = Keyword.fetch!(opts, :file)
    format = Keyword.get(opts, :format, :both)
    timeout = Keyword.get(opts, :timeout, 60_000)

    unless File.exists?(file_path) do
      IO.puts(:stderr, "Error: File not found: #{file_path}")
      System.halt(1)
    end

    IO.puts("Running test from: #{file_path}\n")

    case TestRunner.run_test_file(file_path, timeout: timeout) do
      {:ok, result} ->
        # Extract test name from result or use filename
        test_name = extract_test_name(file_path, result)
        TestRunner.display_results(test_name, result, format)

        # Exit with appropriate code
        exit_code =
          case result.status do
            :success -> 0
            _ -> 1
          end

        System.halt(exit_code)

      {:error, reason} ->
        IO.puts(:stderr, "Error running test: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp extract_test_name(file_path, result) do
    # Try to get name from result, fall back to filename
    Map.get(result, :test_name) || Path.basename(file_path, ".yaml")
  end

  defp print_usage do
    IO.puts("""
    Usage: mix run scripts/run_tests.exs <yaml_file> [options]

    Options:
      --format <format>    Output format: console, json, or both (default: both)
      --timeout <ms>        Timeout in milliseconds (default: 60000)

    Examples:
      mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml
      mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml --format json
      mix run scripts/run_tests.exs test/fixtures/demo_workflow_test.yaml --timeout 120000
    """)
  end
end

# For direct execution
if System.argv() != [] do
  RunTestsScript.main(System.argv())
end
