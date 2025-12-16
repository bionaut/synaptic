defmodule Synaptic.Eval.Integration do
  @moduledoc """
  Behaviour for integrating with 3rd party eval services like Braintrust, LangSmith, etc.

  Eval integrations observe LLM calls and scorer results via Telemetry events and
  can combine them into complete eval records for external services.

  ## Example Implementation

      defmodule MyApp.Eval.BraintrustIntegration do
        @behaviour Synaptic.Eval.Integration

        @impl Synaptic.Eval.Integration
        def on_llm_call(_event, measurements, metadata, config) do
          # Log LLM call with tokens, input, output
          usage = Map.get(metadata, :usage, %{})

          Braintrust.log({
            run_id: metadata.run_id,
            step: metadata.step_name,
            input: metadata.input,  # You'd need to capture this separately
            output: metadata.output,  # You'd need to capture this separately
            model: metadata.model,
            prompt_tokens: Map.get(usage, :prompt_tokens, 0),
            completion_tokens: Map.get(usage, :completion_tokens, 0),
            total_tokens: Map.get(usage, :total_tokens, 0),
            duration_ms: System.convert_time_unit(measurements.duration, :native, :millisecond)
          })
        end

        @impl Synaptic.Eval.Integration
        def on_scorer_result(_event, measurements, metadata, config) do
          # Log scorer result
          Braintrust.log_score({
            run_id: metadata.run_id,
            step: metadata.step_name,
            scorer: metadata.scorer,
            score: metadata.score,
            reason: metadata.reason
          })
        end
      end

  ## Attaching the Integration

  Attach your integration in your application startup (e.g., in `application.ex`):

      defmodule MyApp.Application do
        def start(_type, _args) do
          # ... other setup ...

          Synaptic.Eval.Integration.attach(MyApp.Eval.BraintrustIntegration, %{
            # Your config here
          })

          # ... rest of startup ...
        end
      end

  ## Combining LLM Metrics with Scorer Results

  To combine LLM metrics with scorer results, you can:
  1. Store LLM call data in a process dictionary or ETS table keyed by `{run_id, step_name}`
  2. When scorer results arrive, look up the corresponding LLM call
  3. Combine both into a single eval record

  See the README for more detailed examples.
  """

  @doc """
  Called when an LLM call completes.

  This callback is invoked via a Telemetry handler attached to `[:synaptic, :llm, :stop]`.

  ## Parameters

    * `event` - The Telemetry event name (e.g., `[:synaptic, :llm, :stop]`)
    * `measurements` - Map containing `:duration` and optionally token counts
    * `metadata` - Map containing:
      * `:run_id` - Workflow run identifier
      * `:step_name` - Step name (atom)
      * `:adapter` - Adapter module
      * `:model` - Model name
      * `:stream` - Boolean indicating if streaming was used
      * `:usage` - Optional usage map with `:prompt_tokens`, `:completion_tokens`, `:total_tokens`
    * `config` - Configuration passed to `attach/2`
  """
  @callback on_llm_call(
              event :: list(atom()),
              measurements :: map(),
              metadata :: map(),
              config :: term()
            ) :: :ok

  @doc """
  Called when a scorer completes.

  This callback is invoked via a Telemetry handler attached to `[:synaptic, :scorer, :stop]`.

  ## Parameters

    * `event` - The Telemetry event name (e.g., `[:synaptic, :scorer, :stop]`)
    * `measurements` - Map containing `:duration`
    * `metadata` - Map containing:
      * `:run_id` - Workflow run identifier
      * `:workflow` - Workflow module
      * `:step_name` - Step name (atom)
      * `:scorer` - Scorer module
      * `:status` - `:ok` or `:error`
      * `:score` - Score value (number, or `nil` on error)
      * `:reason` - Reason string (or error message)
    * `config` - Configuration passed to `attach/2`
  """
  @optional_callbacks on_scorer_result: 4
  @callback on_scorer_result(
              event :: list(atom()),
              measurements :: map(),
              metadata :: map(),
              config :: term()
            ) :: :ok

  @doc """
  Called when a step completes.

  This optional callback can be used to combine LLM metrics with scorer results
  after a step finishes. It's invoked via a Telemetry handler attached to
  `[:synaptic, :step, :stop]`.

  ## Parameters

    * `event` - The Telemetry event name (e.g., `[:synaptic, :step, :stop]`)
    * `measurements` - Map containing `:duration`
    * `metadata` - Map containing:
      * `:run_id` - Workflow run identifier
      * `:workflow` - Workflow module
      * `:step_name` - Step name (atom)
      * `:type` - Step type
      * `:status` - `:ok`, `:suspend`, `:error`, or `:unknown`
    * `config` - Configuration passed to `attach/2`
  """
  @optional_callbacks on_step_complete: 4
  @callback on_step_complete(
              event :: list(atom()),
              measurements :: map(),
              metadata :: map(),
              config :: term()
            ) :: :ok

  @doc """
  Attaches Telemetry handlers for the given integration module.

  This function sets up Telemetry handlers that call the integration's callbacks
  when LLM calls, scorer results, or step completions occur.

  ## Parameters

    * `integration_module` - Module implementing `Synaptic.Eval.Integration`
    * `config` - Configuration map passed to all callbacks

  ## Example

      Synaptic.Eval.Integration.attach(MyApp.Eval.BraintrustIntegration, %{
        api_key: System.get_env("BRAINTRUST_API_KEY"),
        project: "my-project"
      })
  """
  @spec attach(module(), config :: term()) :: :ok
  def attach(integration_module, config \\ %{}) do
    handler_id_llm = handler_id(integration_module, :llm)
    handler_id_scorer = handler_id(integration_module, :scorer)
    handler_id_step = handler_id(integration_module, :step)

    # Attach LLM handler
    :telemetry.attach(
      handler_id_llm,
      [:synaptic, :llm, :stop],
      fn event, measurements, metadata, _ ->
        if function_exported?(integration_module, :on_llm_call, 4) do
          integration_module.on_llm_call(event, measurements, metadata, config)
        end
      end,
      nil
    )

    # Attach scorer handler (if callback exists)
    if function_exported?(integration_module, :on_scorer_result, 4) do
      :telemetry.attach(
        handler_id_scorer,
        [:synaptic, :scorer, :stop],
        fn event, measurements, metadata, _ ->
          integration_module.on_scorer_result(event, measurements, metadata, config)
        end,
        nil
      )
    end

    # Attach step handler (if callback exists)
    if function_exported?(integration_module, :on_step_complete, 4) do
      :telemetry.attach(
        handler_id_step,
        [:synaptic, :step, :stop],
        fn event, measurements, metadata, _ ->
          integration_module.on_step_complete(event, measurements, metadata, config)
        end,
        nil
      )
    end

    :ok
  end

  @doc """
  Detaches Telemetry handlers for the given integration module.

  ## Parameters

    * `integration_module` - Module implementing `Synaptic.Eval.Integration`
  """
  @spec detach(module()) :: :ok | {:error, :not_found}
  def detach(integration_module) do
    handler_id_llm = handler_id(integration_module, :llm)
    handler_id_scorer = handler_id(integration_module, :scorer)
    handler_id_step = handler_id(integration_module, :step)

    results = [
      :telemetry.detach(handler_id_llm),
      :telemetry.detach(handler_id_scorer),
      :telemetry.detach(handler_id_step)
    ]

    # Return :ok if at least one handler was found, otherwise :error
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp handler_id(module, type) do
    "synaptic-eval-#{inspect(module)}-#{type}"
  end
end
