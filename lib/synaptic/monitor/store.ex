defmodule Synaptic.Monitor.Store do
  @moduledoc false

  use GenServer

  alias Synaptic.Monitor
  alias Synaptic.Monitor.Event

  @entity_tables %{
    service: :synaptic_monitor_services,
    instance: :synaptic_monitor_instances,
    run: :synaptic_monitor_runs,
    task_ref: :synaptic_monitor_task_refs,
    workflow: :synaptic_monitor_workflows
  }

  @events_table :synaptic_monitor_events
  @edges_table :synaptic_monitor_edges
  @meta_table :synaptic_monitor_meta

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ingest(event) when is_map(event) do
    GenServer.call(__MODULE__, {:ingest, event})
  end

  def snapshot do
    %{
      services: table_to_map(@entity_tables.service),
      instances: table_to_map(@entity_tables.instance),
      runs: table_to_map(@entity_tables.run),
      task_refs: table_to_map(@entity_tables.task_ref),
      workflows: table_to_map(@entity_tables.workflow),
      edges: @edges_table |> :ets.tab2list() |> Enum.map(&elem(&1, 1)),
      events: recent_events(),
      updated_at_ms: meta(:updated_at_ms)
    }
  end

  def entity(type, id) do
    case :ets.lookup(table_for(type), normalize_id(id)) do
      [{_id, entity}] -> entity
      [] -> nil
    end
  end

  def recent_events(filters \\ %{}) do
    filters = normalize_filters(filters)

    @events_table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&matches_filters?(&1, filters))
  end

  @impl true
  def init(_opts) do
    create_tables()

    state = %{
      seq: 0,
      event_queue: :queue.new(),
      history_limit: Monitor.history_limit(),
      retention_ms: Monitor.retention_ms(),
      cleanup_interval_ms:
        Application.get_env(:synaptic, Synaptic.Monitor, [])
        |> Keyword.get(:cleanup_interval_ms, 5_000)
    }

    schedule_cleanup(state.cleanup_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:ingest, event}, _from, state) do
    now_ms = System.system_time(:millisecond)
    {stored_event, new_state} = store_event(event, state)
    upsert_entities(stored_event, now_ms)
    upsert_edges(stored_event, now_ms)
    :ets.insert(@meta_table, {:updated_at_ms, stored_event.ts_ms})
    {:reply, stored_event, cleanup_expired(new_state, now_ms)}
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup(state.cleanup_interval_ms)
    {:noreply, cleanup_expired(state, System.system_time(:millisecond))}
  end

  defp create_tables do
    Enum.each(
      Map.values(@entity_tables),
      &new_table(&1, [:set, :public, :named_table, read_concurrency: true])
    )

    new_table(@events_table, [:ordered_set, :public, :named_table, read_concurrency: true])
    new_table(@edges_table, [:set, :public, :named_table, read_concurrency: true])
    new_table(@meta_table, [:set, :public, :named_table, read_concurrency: true])
  end

  defp new_table(name, opts) do
    case :ets.info(name) do
      :undefined ->
        :ets.new(name, opts)

      _ ->
        :ets.delete_all_objects(name)
        :ok
    end
  end

  defp store_event(event, state) do
    seq = state.seq + 1
    stored_event = Map.put(event, :seq, seq)
    :ets.insert(@events_table, {seq, stored_event})

    queue = :queue.in(seq, state.event_queue)
    {trimmed_queue, history_limit} = trim_event_queue(queue, state.history_limit)

    {stored_event, %{state | seq: seq, event_queue: trimmed_queue, history_limit: history_limit}}
  end

  defp trim_event_queue(queue, history_limit) do
    if :queue.len(queue) > history_limit do
      {{:value, oldest}, queue} = :queue.out(queue)
      :ets.delete(@events_table, oldest)
      trim_event_queue(queue, history_limit)
    else
      {queue, history_limit}
    end
  end

  defp upsert_entities(event, now_ms) do
    maybe_upsert_service(event.service_id, event, now_ms, synthetic: false)
    maybe_upsert_service(event.target_service_id, event, now_ms, synthetic: false)
    maybe_upsert_service(event.caller_agent_id, event, now_ms, synthetic: true)
    maybe_upsert_instance(event.instance_id, event, now_ms)
    maybe_upsert_task_ref(event.task_ref_id, event, now_ms)
    maybe_upsert_run(event.run_id, event, now_ms)

    if event.workflow && should_upsert_workflow?(event) do
      upsert_entity(
        :workflow,
        event.workflow,
        %{
          workflow: event.workflow,
          label: event.workflow,
          status: event.status,
          summary: event.summary
        },
        now_ms
      )
    end
  end

  defp maybe_upsert_service(nil, _event, _now_ms, _opts), do: :ok

  defp maybe_upsert_service(service_id, event, now_ms, opts) do
    upsert_entity(
      :service,
      service_id,
      %{
        service_id: service_id,
        label: service_id,
        status: service_status(event),
        summary: event.summary,
        synthetic: Keyword.get(opts, :synthetic, false),
        metadata:
          filter_nil_fields(%{
            capabilities: Map.get(event.data, :capabilities),
            visibility: Map.get(event.data, :visibility),
            kind: Map.get(event.data, :service_kind) || Map.get(event.data, :kind),
            provider: Map.get(event.data, :provider),
            provider_ref: Map.get(event.data, :provider_ref),
            routing_mode: Map.get(event.data, :routing_mode),
            lifecycle_mode: Map.get(event.data, :lifecycle_mode)
          })
      },
      now_ms
    )
  end

  defp maybe_upsert_instance(nil, _event, _now_ms), do: :ok

  defp maybe_upsert_instance(instance_id, event, now_ms) do
    upsert_entity(
      :instance,
      instance_id,
      %{
        instance_id: instance_id,
        service_id: event.service_id || event.target_service_id,
        run_id: event.run_id,
        status: event.status,
        summary: event.summary,
        metadata:
          filter_nil_fields(%{
            endpoint_type: Map.get(event.data, :endpoint_type),
            endpoint_ref: Map.get(event.data, :endpoint_ref),
            health: Map.get(event.data, :health),
            last_error: Map.get(event.data, :last_error),
            labels: Map.get(event.data, :labels),
            purpose: event.purpose
          })
      },
      now_ms
    )
  end

  defp maybe_upsert_task_ref(nil, _event, _now_ms), do: :ok

  defp maybe_upsert_task_ref(task_ref_id, event, now_ms) do
    upsert_entity(
      :task_ref,
      task_ref_id,
      %{
        task_ref_id: task_ref_id,
        service_id: event.service_id || event.target_service_id,
        instance_id: event.instance_id,
        run_id: event.run_id,
        status: event.status,
        request_id: event.request_id,
        purpose: event.purpose,
        summary: event.summary,
        metadata:
          filter_nil_fields(%{
            user_id: Map.get(event.data, :user_id),
            session_id: Map.get(event.data, :session_id),
            alias_keys: Map.get(event.data, :alias_keys),
            last_error: Map.get(event.data, :last_error)
          })
      },
      now_ms
    )
  end

  defp maybe_upsert_run(nil, _event, _now_ms), do: :ok

  defp maybe_upsert_run(run_id, event, now_ms) do
    upsert_entity(
      :run,
      run_id,
      %{
        run_id: run_id,
        workflow: event.workflow,
        service_id: event.service_id || event.target_service_id,
        instance_id: event.instance_id,
        task_ref_id: event.task_ref_id,
        step: event.step,
        status: event.status,
        request_id: event.request_id,
        purpose: event.purpose,
        trace_id: event.trace_id,
        call_id: event.call_id,
        parent_call_id: event.parent_call_id,
        summary: event.summary,
        last_error: Map.get(event.data, :last_error),
        waiting: Map.get(event.data, :waiting),
        metrics:
          filter_nil_fields(%{
            duration_ms: Map.get(event.data, :duration_ms),
            prompt_tokens: Map.get(event.data, :prompt_tokens),
            completion_tokens: Map.get(event.data, :completion_tokens),
            total_tokens: Map.get(event.data, :total_tokens),
            estimated_cost_usd: Map.get(event.data, :estimated_cost_usd)
          }),
        metadata:
          filter_nil_fields(%{
            current_step: Map.get(event.data, :current_step),
            event: Map.get(event.data, :event),
            run_source: Map.get(event.data, :run_source)
          })
      },
      now_ms
    )
  end

  defp upsert_entity(type, id, attrs, now_ms) do
    table = table_for(type)
    id = normalize_id(id)
    existing = entity(type, id) || %{id: id, type: type, inserted_at_ms: now_ms}
    status = Map.get(attrs, :status) || Map.get(existing, :status)

    entity =
      existing
      |> Map.merge(filter_nil_fields(attrs))
      |> Map.put(:id, id)
      |> Map.put(:type, type)
      |> Map.put(:updated_at_ms, now_ms)
      |> maybe_mark_terminal(status, now_ms)

    :ets.insert(table, {id, entity})
  end

  defp upsert_edges(event, now_ms) do
    maybe_upsert_edge(
      :service_instance,
      {:service, event.service_id},
      {:instance, event.instance_id},
      event,
      now_ms
    )

    maybe_upsert_edge(
      :instance_run,
      {:instance, event.instance_id},
      {:run, event.run_id},
      event,
      now_ms
    )

    maybe_upsert_edge(
      :task_ref_run,
      {:task_ref, event.task_ref_id},
      {:run, event.run_id},
      event,
      now_ms
    )

    if should_upsert_workflow?(event) do
      maybe_upsert_edge(
        :workflow_run,
        {:workflow, event.workflow},
        {:run, event.run_id},
        event,
        now_ms
      )
    end

    maybe_upsert_edge(
      :caller_callee,
      {:service, event.caller_agent_id},
      {:service, event.target_service_id},
      event,
      now_ms
    )
  end

  defp maybe_upsert_edge(_kind, {_from_type, nil}, _to, _event, _now_ms), do: :ok
  defp maybe_upsert_edge(_kind, _from, {_to_type, nil}, _event, _now_ms), do: :ok

  defp maybe_upsert_edge(kind, {from_type, from_id}, {to_type, to_id}, event, now_ms) do
    normalized_from_id = normalize_id(from_id)
    normalized_to_id = normalize_id(to_id)
    edge_key = {kind, normalized_from_id, normalized_to_id}

    existing =
      case :ets.lookup(@edges_table, edge_key) do
        [{^edge_key, edge}] ->
          edge

        [] ->
          %{
            id: edge_public_id(kind, normalized_from_id, normalized_to_id),
            kind: kind,
            inserted_at_ms: now_ms
          }
      end

    edge =
      existing
      |> Map.merge(%{
        from_type: from_type,
        from_id: normalized_from_id,
        to_type: to_type,
        to_id: normalized_to_id,
        status: event.status,
        summary: event.summary,
        trace_id: event.trace_id,
        call_id: event.call_id,
        request_id: event.request_id,
        purpose: event.purpose,
        updated_at_ms: now_ms
      })
      |> Map.put(:id, edge_public_id(kind, normalized_from_id, normalized_to_id))
      |> maybe_mark_terminal(event.status, now_ms)

    :ets.insert(@edges_table, {edge_key, edge})
  end

  defp should_upsert_workflow?(event) do
    event.workflow && (Map.get(event.data, :run_source) == :direct || is_nil(event.service_id))
  end

  defp service_status(%{kind: :service}), do: :registered
  defp service_status(%{status: status}) when status in [:deregistered], do: status
  defp service_status(_event), do: :active

  defp maybe_mark_terminal(entity, status, now_ms) do
    if Event.terminal_status?(status) do
      Map.put(entity, :terminal_at_ms, now_ms)
    else
      Map.delete(entity, :terminal_at_ms)
    end
  end

  defp cleanup_expired(state, now_ms) do
    Enum.each(@entity_tables, fn {type, table} ->
      table
      |> :ets.tab2list()
      |> Enum.each(fn {id, entity} ->
        if expired?(entity, state.retention_ms, now_ms) do
          :ets.delete(table, id)
          delete_related_edges(type, id)
        end
      end)
    end)

    @edges_table
    |> :ets.tab2list()
    |> Enum.each(fn {edge_id, edge} ->
      if expired?(edge, state.retention_ms, now_ms) do
        :ets.delete(@edges_table, edge_id)
      end
    end)

    state
  end

  defp expired?(entity, retention_ms, now_ms) do
    case Map.get(entity, :terminal_at_ms) do
      terminal_at_ms when is_integer(terminal_at_ms) ->
        now_ms - terminal_at_ms >= retention_ms

      nil ->
        Map.get(entity, :kind) == :caller_callee and
          is_integer(Map.get(entity, :updated_at_ms)) and
          now_ms - entity.updated_at_ms >= retention_ms
    end
  end

  defp delete_related_edges(type, id) do
    normalized_id = normalize_id(id)

    @edges_table
    |> :ets.tab2list()
    |> Enum.each(fn {edge_id, edge} ->
      if (edge.from_type == type and edge.from_id == normalized_id) or
           (edge.to_type == type and edge.to_id == normalized_id) do
        :ets.delete(@edges_table, edge_id)
      end
    end)
  end

  defp normalize_filters(filters) do
    filters
    |> Map.new()
    |> Enum.reduce(%{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, normalize_filter_key(key), normalize_id(value))
    end)
  end

  defp normalize_filter_key(key) when is_atom(key), do: key

  defp normalize_filter_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp matches_filters?(event, filters) do
    Enum.all?(filters, fn
      {key, value} when is_atom(key) ->
        normalize_id(Map.get(event, key)) == value

      _ ->
        false
    end)
  end

  defp table_to_map(table) do
    table
    |> :ets.tab2list()
    |> Enum.into(%{}, fn {id, entity} -> {id, entity} end)
  end

  defp table_for(type), do: Map.fetch!(@entity_tables, type)

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp edge_public_id(kind, from_id, to_id) do
    "#{kind}:#{from_id}:#{to_id}"
  end

  defp filter_nil_fields(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp meta(key) do
    case :ets.lookup(@meta_table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp schedule_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup, interval_ms)
  end
end
