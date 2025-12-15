defmodule Synaptic.TestRunner do
  @moduledoc """
  Main test runner module for executing Synaptic workflows from YAML test definitions.

  This module orchestrates workflow execution, waiting for completion,
  handling human input, and validating expectations.
  """

  alias Synaptic.TestRunner.{YamlParser, ExpectationValidator, ResultFormatter}

  @default_timeout 60_000
  @poll_interval 100

  @spec run_test_file(
          binary()
          | maybe_improper_list(
              binary() | maybe_improper_list(any(), binary() | []) | char(),
              binary() | []
            )
        ) ::
          {:error,
           :invalid_expectations
           | :invalid_input
           | :invalid_start_at_step
           | :invalid_workflow_module
           | :invalid_yaml_structure
           | :missing_input
           | :missing_workflow
           | {:file_read_error, atom()}
           | {:yaml_parse_error,
              %{
                :__exception__ => true,
                :__struct__ => YamlElixir.FileNotFoundError | YamlElixir.ParsingError,
                :message => binary(),
                optional(:column) => any(),
                optional(:line) => any(),
                optional(:type) => any()
              }}}
          | {:ok,
             %{
               context: any(),
               error: any(),
               execution_time_ms: integer(),
               run_id: nil | binary(),
               status: :error | :failed | :success,
               test_name: any(),
               validation: nil | map(),
               workflow: any()
             }}
  @doc """
  Runs a test from a YAML file path.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def run_test_file(file_path, opts \\ []) do
    with {:ok, test_definition} <- YamlParser.load_file(file_path) do
      run_test(test_definition, opts)
    end
  end

  @doc """
  Runs a test from a test definition map.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def run_test(test_definition, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, workflow_module} <- resolve_workflow_module(test_definition.workflow),
         {:ok, run_id} <- start_workflow(workflow_module, test_definition),
         {:ok, snapshot} <- wait_for_completion(run_id, timeout, opts) do
      execution_time = System.monotonic_time(:millisecond) - start_time

      validation =
        if test_definition.expectations do
          {:ok, validation_result} =
            ExpectationValidator.validate(snapshot, test_definition.expectations)

          validation_result
        else
          nil
        end

      result = %{
        test_name: test_definition.name,
        workflow: test_definition.workflow,
        run_id: run_id,
        status: determine_status(snapshot, validation),
        validation: validation,
        context: snapshot.context,
        error: snapshot.last_error,
        execution_time_ms: execution_time
      }

      {:ok, result}
    else
      {:error, reason} ->
        execution_time = System.monotonic_time(:millisecond) - start_time

        result = %{
          test_name: test_definition.name,
          workflow: test_definition.workflow,
          run_id: nil,
          status: :error,
          validation: nil,
          context: nil,
          error: reason,
          execution_time_ms: execution_time
        }

        {:ok, result}
    end
  end

  defp resolve_workflow_module(module_string) when is_binary(module_string) do
    # Split by dots and convert to atoms
    parts = String.split(module_string, ".")

    try do
      module = Module.concat(Enum.map(parts, &String.to_atom/1))
      {:ok, module}
    rescue
      ArgumentError ->
        {:error, {:invalid_module, module_string}}
    end
  end

  defp start_workflow(workflow_module, test_definition) do
    # Inject __skip_side_effects__ flag into context if specified in YAML
    input =
      if Map.get(test_definition, :skip_side_effects, false) do
        Map.put(test_definition.input, :__skip_side_effects__, true)
      else
        test_definition.input
      end

    opts = []

    opts =
      if test_definition.start_at_step do
        Keyword.put(opts, :start_at_step, test_definition.start_at_step)
      else
        opts
      end

    case Synaptic.start(workflow_module, input, opts) do
      {:ok, run_id} -> {:ok, run_id}
      {:error, reason} -> {:error, {:workflow_start_failed, reason}}
    end
  end

  defp wait_for_completion(run_id, timeout, opts) do
    start_time = System.monotonic_time(:millisecond)

    case wait_for_completion_loop(run_id, start_time, timeout, opts) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_completion_loop(run_id, start_time, timeout, opts) do
    elapsed = System.monotonic_time(:millisecond) - start_time

    if elapsed >= timeout do
      snapshot = Synaptic.inspect(run_id)
      {:error, {:timeout, snapshot}}
    else
      case Synaptic.inspect(run_id) do
        %{status: :completed} = snapshot ->
          {:ok, snapshot}

        %{status: :failed} = snapshot ->
          {:ok, snapshot}

        %{status: :waiting_for_human} = snapshot ->
          handle_human_input(run_id, snapshot, opts)

        %{status: :running} = _snapshot ->
          Process.sleep(@poll_interval)
          wait_for_completion_loop(run_id, start_time, timeout, opts)

        %{status: :stopped} = snapshot ->
          {:ok, snapshot}

        other ->
          {:error, {:unexpected_status, other}}
      end
    end
  end

  defp handle_human_input(run_id, snapshot, opts) do
    # Check if auto-resume is configured
    auto_resume = Keyword.get(opts, :auto_resume)

    if auto_resume do
      # Auto-resume with provided payload
      case Synaptic.resume(run_id, auto_resume) do
        :ok ->
          # Continue waiting
          start_time = System.monotonic_time(:millisecond)
          timeout = Keyword.get(opts, :timeout, @default_timeout)
          wait_for_completion_loop(run_id, start_time, timeout, opts)

        {:error, reason} ->
          {:error, {:resume_failed, reason}}
      end
    else
      # Manual input - prompt user
      display_waiting_message(snapshot)

      case prompt_for_resume(snapshot) do
        {:ok, payload} ->
          case Synaptic.resume(run_id, payload) do
            :ok ->
              # Continue waiting
              start_time = System.monotonic_time(:millisecond)
              timeout = Keyword.get(opts, :timeout, @default_timeout)
              wait_for_completion_loop(run_id, start_time, timeout, opts)

            {:error, reason} ->
              {:error, {:resume_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:user_cancelled, reason}}
      end
    end
  end

  defp display_waiting_message(snapshot) do
    IO.puts(("\n" <> "=") |> String.duplicate(80))
    IO.puts("Workflow is waiting for human input")
    IO.puts("=" |> String.duplicate(80))

    if snapshot.waiting do
      IO.puts("\nMessage: #{snapshot.waiting.message}")

      if snapshot.waiting.metadata && map_size(snapshot.waiting.metadata) > 0 do
        IO.puts("\nMetadata:")
        IO.inspect(snapshot.waiting.metadata, pretty: true)
      end

      if snapshot.waiting.resume_schema && map_size(snapshot.waiting.resume_schema) > 0 do
        IO.puts("\nRequired fields:")

        Enum.each(snapshot.waiting.resume_schema, fn {key, type} ->
          IO.puts("  - #{key} (#{type})")
        end)
      end
    end

    IO.puts("\n")
  end

  defp prompt_for_resume(_snapshot) do
    IO.puts("Enter resume payload (JSON format, or 'skip' to skip this test):")

    case IO.gets("> ") |> String.trim() do
      "skip" ->
        {:error, :user_skipped}

      input ->
        case Jason.decode(input) do
          {:ok, payload} when is_map(payload) ->
            # Convert string keys to atoms for simple keys
            payload =
              payload
              |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
              |> Map.new()

            {:ok, payload}

          {:ok, _} ->
            {:error, :invalid_payload_format}

          {:error, reason} ->
            {:error, {:json_parse_error, reason}}
        end
    end
  end

  defp determine_status(snapshot, validation) do
    cond do
      snapshot.status == :failed -> :failed
      snapshot.status == :stopped -> :failed
      snapshot.status != :completed -> :error
      validation && not validation.all_passed -> :failed
      true -> :success
    end
  end

  @doc """
  Formats and displays test results.
  """
  def display_results(test_name, result, format \\ :both) do
    case format do
      :console ->
        IO.puts(ResultFormatter.format_console(test_name, result))

      :json ->
        IO.puts(ResultFormatter.format_json(test_name, result))

      :both ->
        IO.puts(ResultFormatter.format_console(test_name, result))
        IO.puts("\n--- JSON Output ---\n")
        IO.puts(ResultFormatter.format_json(test_name, result))
    end
  end
end
