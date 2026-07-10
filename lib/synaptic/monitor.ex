defmodule Synaptic.Monitor do
  @moduledoc """
  Dev-oriented monitoring facade for Synaptic runtimes.
  """

  alias Synaptic.Monitor.{Bus, Collector, Store}

  @entity_types [:service, :instance, :run, :task_ref, :workflow]

  def enabled? do
    config()
    |> Keyword.get(:enabled, false)
  end

  def config do
    Application.get_env(:synaptic, __MODULE__, [])
  end

  def web_config do
    Application.get_env(:synaptic, Synaptic.Monitor.Web, [])
  end

  def history_limit do
    config()
    |> Keyword.get(:history_limit, 500)
  end

  def retention_ms do
    config()
    |> Keyword.get(:retention_ms, 300_000)
  end

  def child_specs do
    if enabled?() do
      [Store, Bus, Collector]
    else
      []
    end
  end

  def web_child_specs do
    if enabled?() and Keyword.get(web_config(), :enabled, false) and
         Code.ensure_loaded?(Synaptic.Monitor.Web) do
      [{Synaptic.Monitor.Web, web_config()}]
    else
      []
    end
  end

  def snapshot do
    if started?(Store) do
      Store.snapshot()
    else
      empty_snapshot()
    end
  end

  def entity(type, id) when is_binary(type) or is_atom(type) do
    with {:ok, normalized_type} <- normalize_entity_type(type),
         true <- started?(Store) do
      Store.entity(normalized_type, id)
    else
      _ -> nil
    end
  end

  def recent_events(filters \\ %{}) do
    if started?(Store) do
      Store.recent_events(filters)
    else
      []
    end
  end

  def subscribe do
    if started?(Bus) do
      Bus.subscribe()
    else
      :ok
    end
  end

  def unsubscribe do
    if started?(Bus) do
      Bus.unsubscribe()
    else
      :ok
    end
  end

  def capture(attrs) when is_list(attrs) or is_map(attrs) do
    if started?(Collector) do
      Collector.capture(Map.new(attrs))
    else
      :ok
    end
  end

  def capture_run_started(state) when is_map(state) do
    monitor_ctx = Map.get(state, :monitor_context, %{})

    capture(%{
      kind: :run,
      status: :running,
      run_id: state.run_id,
      workflow: monitor_ctx[:workflow] || state.workflow,
      step: current_step_name(state),
      service_id: monitor_ctx[:service_id],
      instance_id: monitor_ctx[:instance_id],
      task_ref_id: monitor_ctx[:task_ref_id],
      caller_agent_id: monitor_ctx[:caller_agent_id],
      target_service_id: monitor_ctx[:target_service_id] || monitor_ctx[:service_id],
      trace_id: monitor_ctx[:trace_id],
      call_id: monitor_ctx[:call_id],
      parent_call_id: monitor_ctx[:parent_call_id],
      request_id: monitor_ctx[:request_id],
      purpose: monitor_ctx[:purpose],
      summary: "Run started",
      data: %{
        run_source: monitor_ctx[:run_source] || :direct,
        status: :running,
        context_keys: Map.keys(state.context)
      }
    })
  end

  def capture_run_event(state, payload) when is_map(state) and is_map(payload) do
    monitor_ctx = Map.get(state, :monitor_context, %{})
    event_name = Map.get(payload, :event)
    status = run_event_status(event_name)

    capture(%{
      kind: :run,
      status: status,
      run_id: state.run_id,
      workflow: monitor_ctx[:workflow] || state.workflow,
      step: Map.get(payload, :step) || current_step_name(state),
      service_id: monitor_ctx[:service_id],
      instance_id: monitor_ctx[:instance_id],
      task_ref_id: monitor_ctx[:task_ref_id],
      caller_agent_id: monitor_ctx[:caller_agent_id],
      target_service_id: monitor_ctx[:target_service_id] || monitor_ctx[:service_id],
      trace_id: monitor_ctx[:trace_id],
      call_id: monitor_ctx[:call_id],
      parent_call_id: monitor_ctx[:parent_call_id],
      request_id: monitor_ctx[:request_id],
      purpose: monitor_ctx[:purpose],
      summary: run_event_summary(event_name, payload),
      data: %{
        event: event_name,
        current_step: current_step_name(state),
        waiting: state.waiting,
        last_error: state.last_error,
        run_source: monitor_ctx[:run_source] || :direct,
        payload: Map.drop(payload, [:event, :run_id, :current_step])
      }
    })
  end

  def empty_snapshot do
    %{
      services: %{},
      instances: %{},
      runs: %{},
      task_refs: %{},
      workflows: %{},
      edges: [],
      events: [],
      updated_at_ms: nil
    }
  end

  defp normalize_entity_type(type) when type in @entity_types, do: {:ok, type}

  defp normalize_entity_type(type) when is_binary(type) do
    case Enum.find(@entity_types, &(Atom.to_string(&1) == type)) do
      nil -> :error
      entity_type -> {:ok, entity_type}
    end
  end

  defp normalize_entity_type(_), do: :error

  defp current_step_name(state) do
    state.steps
    |> Enum.at(state.current_step_index)
    |> case do
      nil -> nil
      step -> step.name
    end
  end

  defp run_event_status(:waiting_for_human), do: :waiting_for_human
  defp run_event_status(:resumed), do: :running
  defp run_event_status(:step_completed), do: :running
  defp run_event_status(:step_routed), do: :running
  defp run_event_status(:retrying), do: :running
  defp run_event_status(:failed), do: :failed
  defp run_event_status(:stopped), do: :stopped
  defp run_event_status(:completed), do: :completed
  defp run_event_status(_), do: :running

  defp run_event_summary(:waiting_for_human, payload) do
    message = Map.get(payload, :message)
    if is_binary(message), do: message, else: "Waiting for human input"
  end

  defp run_event_summary(:step_completed, payload) do
    "Completed step #{inspect(Map.get(payload, :step))}"
  end

  defp run_event_summary(:step_routed, payload) do
    "Routed to #{inspect(Map.get(payload, :target))}"
  end

  defp run_event_summary(:retrying, payload) do
    "Retrying after #{inspect(Map.get(payload, :reason))}"
  end

  defp run_event_summary(:failed, payload) do
    "Run failed: #{inspect(Map.get(payload, :reason))}"
  end

  defp run_event_summary(:stopped, payload) do
    "Run stopped: #{inspect(Map.get(payload, :reason))}"
  end

  defp run_event_summary(:completed, _payload), do: "Run completed"
  defp run_event_summary(:resumed, _payload), do: "Run resumed"
  defp run_event_summary(_event, payload), do: "Run event #{inspect(Map.get(payload, :event))}"

  defp started?(module), do: Process.whereis(module) != nil
end
