defmodule Synaptic.AgentDirectory.Store.InMemory do
  @moduledoc """
  In-memory GenServer-backed directory store.
  """

  use GenServer

  @behaviour Synaptic.AgentDirectory.Store

  defstruct services: %{}, instances: %{}, task_refs: %{}

  @type state :: %__MODULE__{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def put_service(record), do: GenServer.call(__MODULE__, {:put_service, record})
  @impl true
  def delete_service(tenant_id, service_id),
    do: GenServer.call(__MODULE__, {:delete_service, tenant_id, service_id})

  @impl true
  def get_service(tenant_id, service_id),
    do: GenServer.call(__MODULE__, {:get_service, tenant_id, service_id})

  @impl true
  def list_services(filters), do: GenServer.call(__MODULE__, {:list_services, filters})

  @impl true
  def put_instance(record), do: GenServer.call(__MODULE__, {:put_instance, record})
  @impl true
  def update_instance(tenant_id, instance_id, fun),
    do: GenServer.call(__MODULE__, {:update_instance, tenant_id, instance_id, fun})

  @impl true
  def delete_instance(tenant_id, instance_id),
    do: GenServer.call(__MODULE__, {:delete_instance, tenant_id, instance_id})

  @impl true
  def get_instance(tenant_id, instance_id),
    do: GenServer.call(__MODULE__, {:get_instance, tenant_id, instance_id})

  @impl true
  def list_instances(filters), do: GenServer.call(__MODULE__, {:list_instances, filters})

  @impl true
  def put_task_reference(record), do: GenServer.call(__MODULE__, {:put_task_reference, record})
  @impl true
  def update_task_reference(tenant_id, task_ref_id, fun),
    do: GenServer.call(__MODULE__, {:update_task_reference, tenant_id, task_ref_id, fun})

  @impl true
  def get_task_reference(tenant_id, task_ref_id),
    do: GenServer.call(__MODULE__, {:get_task_reference, tenant_id, task_ref_id})

  @impl true
  def list_task_references(filters),
    do: GenServer.call(__MODULE__, {:list_task_references, filters})

  @impl true
  def delete_task_reference(tenant_id, task_ref_id),
    do: GenServer.call(__MODULE__, {:delete_task_reference, tenant_id, task_ref_id})

  @impl true
  def reset!, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def handle_call({:put_service, record}, _from, state) do
    key = key(record.tenant_id, record.service_id)
    {:reply, {:ok, record}, %{state | services: Map.put(state.services, key, record)}}
  end

  def handle_call({:delete_service, tenant_id, service_id}, _from, state) do
    {:reply, :ok, %{state | services: Map.delete(state.services, key(tenant_id, service_id))}}
  end

  def handle_call({:get_service, tenant_id, service_id}, _from, state) do
    reply = fetch_reply(state.services, tenant_id, service_id)
    {:reply, reply, state}
  end

  def handle_call({:list_services, filters}, _from, state) do
    {:reply, state.services |> Map.values() |> filter_records(filters), state}
  end

  def handle_call({:put_instance, record}, _from, state) do
    key = key(record.tenant_id, record.instance_id)
    {:reply, {:ok, record}, %{state | instances: Map.put(state.instances, key, record)}}
  end

  def handle_call({:update_instance, tenant_id, instance_id, fun}, _from, state) do
    key = key(tenant_id, instance_id)

    case Map.fetch(state.instances, key) do
      {:ok, rec} ->
        updated = fun.(rec)
        {:reply, {:ok, updated}, %{state | instances: Map.put(state.instances, key, updated)}}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete_instance, tenant_id, instance_id}, _from, state) do
    {:reply, :ok, %{state | instances: Map.delete(state.instances, key(tenant_id, instance_id))}}
  end

  def handle_call({:get_instance, tenant_id, instance_id}, _from, state) do
    {:reply, fetch_reply(state.instances, tenant_id, instance_id), state}
  end

  def handle_call({:list_instances, filters}, _from, state) do
    {:reply, state.instances |> Map.values() |> filter_records(filters), state}
  end

  def handle_call({:put_task_reference, record}, _from, state) do
    key = key(record.tenant_id, record.task_ref_id)
    {:reply, {:ok, record}, %{state | task_refs: Map.put(state.task_refs, key, record)}}
  end

  def handle_call({:update_task_reference, tenant_id, task_ref_id, fun}, _from, state) do
    key = key(tenant_id, task_ref_id)

    case Map.fetch(state.task_refs, key) do
      {:ok, rec} ->
        updated = fun.(rec)
        {:reply, {:ok, updated}, %{state | task_refs: Map.put(state.task_refs, key, updated)}}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:get_task_reference, tenant_id, task_ref_id}, _from, state) do
    {:reply, fetch_reply(state.task_refs, tenant_id, task_ref_id), state}
  end

  def handle_call({:list_task_references, filters}, _from, state) do
    {:reply, state.task_refs |> Map.values() |> filter_records(filters), state}
  end

  def handle_call({:delete_task_reference, tenant_id, task_ref_id}, _from, state) do
    {:reply, :ok, %{state | task_refs: Map.delete(state.task_refs, key(tenant_id, task_ref_id))}}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %__MODULE__{}}
  end

  defp fetch_reply(map, tenant_id, id) do
    case Map.fetch(map, key(tenant_id, id)) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  defp key(tenant_id, id), do: {tenant_id || "default", id}

  defp filter_records(records, filters) do
    Enum.filter(records, fn record ->
      Enum.all?(filters, fn
        {_k, nil} ->
          true

        {:status, statuses} when is_list(statuses) ->
          Map.get(record, :status) in statuses

        {:alias, alias_key} when is_binary(alias_key) ->
          alias_key in Map.get(record, :alias_keys, [])

        {k, v} ->
          Map.get(record, k) == v
      end)
    end)
  end
end
