defmodule Synaptic.AgentDirectory do
  @moduledoc """
  Agent service/instance/task-reference directory facade with policy filtering.
  """

  use GenServer

  alias Synaptic.{AgentPolicy, TaskReference}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  def register_service(service_id, spec, opts \\ []) do
    tenant_id = tenant_id(opts)
    now = now()

    record =
      spec
      |> normalize_service_spec(service_id, tenant_id)
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)

    emit(:register, %{kind: :service, service_id: service_id, tenant_id: tenant_id})
    store().put_service(record)
  end

  def deregister_service(service_id, opts \\ []) do
    tenant_id = tenant_id(opts)
    emit(:deregister, %{kind: :service, service_id: service_id, tenant_id: tenant_id})
    store().delete_service(tenant_id, service_id)
  end

  def lookup_service(service_id, opts \\ []) do
    tenant_id = tenant_id(opts)
    caller_ctx = caller_ctx(opts)

    with {:ok, record} <- store().get_service(tenant_id, service_id),
         :allow <- allow_or_error(AgentPolicy.authorize_discovery(caller_ctx, record, :lookup)) do
      {:ok, record}
    else
      :error -> {:error, :not_found}
      {:deny, :invisible} -> {:error, :invisible}
      {:deny, reason} -> {:error, :unauthorized, reason}
      {:error, _} = err -> err
    end
  end

  def list_services(filters \\ %{}, opts \\ []) do
    caller_ctx = caller_ctx(opts)
    filters = Map.put_new(filters, :tenant_id, tenant_id(opts))

    filters
    |> store().list_services()
    |> then(&AgentPolicy.filter_visible_records(caller_ctx, &1))
  end

  def find_services_by_capability(capability, opts \\ []) when is_binary(capability) do
    list_services(%{tenant_id: tenant_id(opts)}, opts)
    |> Enum.filter(&(capability in Map.get(&1, :capabilities, [])))
  end

  def register_instance(instance_spec, opts \\ []) do
    tenant_id = tenant_id(opts)
    now = now()

    record =
      instance_spec
      |> normalize_instance_spec(tenant_id)
      |> Map.put_new(:created_at, now)
      |> Map.put(:last_activity_at, now)

    emit(:register, %{kind: :instance, instance_id: record.instance_id, tenant_id: tenant_id})
    store().put_instance(record)
  end

  def heartbeat_instance(instance_id, attrs \\ %{}, opts \\ []) do
    update_instance(instance_id, Map.put(attrs, :last_activity_at, now()), opts)
  end

  def update_instance(instance_id, attrs, opts \\ []) when is_map(attrs) do
    tenant_id = tenant_id(opts)

    result =
      store().update_instance(tenant_id, instance_id, fn rec ->
        rec
        |> Map.merge(attrs)
        |> Map.put(:last_activity_at, Map.get(attrs, :last_activity_at, now()))
      end)

    if match?({:ok, _}, result), do: emit(:update, %{kind: :instance, instance_id: instance_id})

    case result do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  def deregister_instance(instance_id, opts \\ []) do
    tenant_id = tenant_id(opts)
    emit(:deregister, %{kind: :instance, instance_id: instance_id, tenant_id: tenant_id})
    store().delete_instance(tenant_id, instance_id)
  end

  def lookup_instance(instance_id, opts \\ []) do
    tenant_id = tenant_id(opts)
    caller_ctx = caller_ctx(opts)

    with {:ok, record} <- store().get_instance(tenant_id, instance_id),
         :allow <- allow_or_error(AgentPolicy.authorize_discovery(caller_ctx, record, :lookup)) do
      {:ok, record}
    else
      :error -> {:error, :not_found}
      {:deny, :invisible} -> {:error, :invisible}
      {:deny, reason} -> {:error, :unauthorized, reason}
    end
  end

  def list_instances(filters \\ %{}, opts \\ []) do
    caller_ctx = caller_ctx(opts)
    filters = Map.put_new(filters, :tenant_id, tenant_id(opts))

    filters
    |> store().list_instances()
    |> then(&AgentPolicy.filter_visible_records(caller_ctx, &1))
  end

  def put_task_reference(attrs, opts \\ []) when is_map(attrs) do
    tenant_id = tenant_id(opts)
    now = now()

    record =
      attrs
      |> Map.put_new(:tenant_id, tenant_id)
      |> Map.put_new(:task_ref_id, id("task"))
      |> Map.put_new(:alias_keys, [])
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:inserted_at, now)
      |> Map.put(:updated_at, now)
      |> Map.put_new(:last_activity_at, now)
      |> then(&struct(TaskReference, &1))

    emit(:task_reference, %{event: :put, task_ref_id: record.task_ref_id})
    store().put_task_reference(Map.from_struct(record))
  end

  def update_task_reference(task_ref_id, attrs, opts \\ []) when is_map(attrs) do
    tenant_id = tenant_id(opts)

    case store().update_task_reference(tenant_id, task_ref_id, fn rec ->
           rec
           |> Map.merge(attrs)
           |> Map.put(:updated_at, now())
           |> Map.put(:last_activity_at, Map.get(attrs, :last_activity_at, now()))
         end) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, :not_found}
    end
  end

  def lookup_task_reference(task_ref_id, opts \\ []) do
    tenant_id = tenant_id(opts)

    case store().get_task_reference(tenant_id, task_ref_id) do
      {:ok, rec} -> {:ok, rec}
      :error -> {:error, :not_found}
    end
  end

  def list_user_tasks(user_id, filters \\ %{}, opts \\ []) do
    filters =
      filters
      |> Map.new()
      |> Map.put(:tenant_id, tenant_id(opts))
      |> Map.put(:user_id, user_id)

    store().list_task_references(filters)
    |> sort_task_refs(filters)
  end

  def resolve_task_reference(query, opts \\ []) when is_map(query) do
    tenant_id = tenant_id(opts)
    query = Map.put_new(query, :tenant_id, tenant_id)
    filters = task_ref_filters(query)

    candidates =
      store().list_task_references(filters)
      |> maybe_filter_task_ref_alias(query)
      |> maybe_filter_task_ref_recency(query)
      |> sort_task_refs(query)

    case candidates do
      [] -> {:error, :not_found}
      [a, b | _] = many ->
        if same_rank?(query, a, b) do
          {:error, :ambiguous_task_reference, Enum.take(many, 10)}
        else
          {:ok, a}
        end
      [one] -> {:ok, one}
    end
  end

  def reset! do
    store().reset!()
  end

  defp task_ref_filters(query) do
    query
    |> Map.take([:tenant_id, :user_id, :session_id, :service_id, :capability])
    |> then(fn filters ->
      case Map.get(query, :status) do
        nil -> filters
        status when is_list(status) -> Map.put(filters, :status, status)
        status -> Map.put(filters, :status, [status])
      end
    end)
  end

  defp maybe_filter_task_ref_alias(records, query) do
    case Map.get(query, :alias) do
      nil -> records
      alias_key -> Enum.filter(records, &(alias_key in Map.get(&1, :alias_keys, [])))
    end
    |> maybe_filter_task_ref_purpose(query)
    |> maybe_require_active(query)
  end

  defp maybe_filter_task_ref_purpose(records, query) do
    case Map.get(query, :purpose) do
      nil -> records
      purpose -> Enum.filter(records, &(Map.get(&1, :purpose) == purpose))
    end
  end

  defp maybe_require_active(records, query) do
    if Map.get(query, :require_active, false) do
      Enum.filter(records, &(Map.get(&1, :status) in [:starting, :ready, :running, :waiting_for_human, :busy]))
    else
      records
    end
  end

  defp maybe_filter_task_ref_recency(records, %{recency: {:within_ms, ms}}) do
    cutoff = DateTime.add(DateTime.utc_now(), -div(ms, 1000), :second)
    Enum.filter(records, &(DateTime.compare(Map.get(&1, :last_activity_at) || Map.get(&1, :updated_at), cutoff) != :lt))
  end

  defp maybe_filter_task_ref_recency(records, _query), do: records

  defp sort_task_refs(records, query) do
    Enum.sort_by(records, fn rec ->
      {rank_alias(rec, query), rank_purpose(rec, query), rank_active(rec), rec.last_activity_at, rec.inserted_at, rec.task_ref_id}
    end, fn a, b -> compare_sort_tuple(a, b, Map.get(query, :recency, :latest)) end)
  end

  defp compare_sort_tuple(a, b, :oldest), do: a <= b
  defp compare_sort_tuple(a, b, _), do: a >= b

  defp rank_alias(rec, %{alias: alias_key}) when is_binary(alias_key) do
    if alias_key in Map.get(rec, :alias_keys, []), do: 1, else: 0
  end

  defp rank_alias(_rec, _query), do: 0

  defp rank_purpose(rec, %{purpose: purpose}) when is_binary(purpose) do
    if Map.get(rec, :purpose) == purpose, do: 1, else: 0
  end

  defp rank_purpose(_rec, _query), do: 0

  defp rank_active(rec) do
    if Map.get(rec, :status) in [:starting, :ready, :running, :waiting_for_human, :busy], do: 1, else: 0
  end

  defp same_rank?(query, a, b) do
    {rank_alias(a, query), rank_purpose(a, query), rank_active(a), a.last_activity_at, a.inserted_at} ==
      {rank_alias(b, query), rank_purpose(b, query), rank_active(b), b.last_activity_at, b.inserted_at}
  end

  defp normalize_service_spec(spec, service_id, tenant_id) do
    spec = Map.new(spec)
    {provider, provider_ref} = normalize_provider(spec)

    %{
      service_id: service_id,
      tenant_id: tenant_id,
      kind: Map.get(spec, :kind, :workflow),
      capabilities: normalize_capabilities(Map.get(spec, :capabilities, [])),
      visibility: Map.get(spec, :visibility, :private),
      lifecycle_mode: Map.get(spec, :lifecycle_mode, :spawn_on_demand),
      routing_mode: Map.get(spec, :routing_mode, :both),
      provider: provider,
      provider_ref: provider_ref,
      spawn_config: Map.get(spec, :spawn_config, %{}),
      auth_policy: Map.get(spec, :auth_policy),
      metadata: Map.get(spec, :metadata, %{})
    }
  end

  defp normalize_provider(spec) do
    cond do
      Map.has_key?(spec, :provider) and Map.has_key?(spec, :provider_ref) ->
        {Map.fetch!(spec, :provider), Map.fetch!(spec, :provider_ref)}

      match?({:workflow_module, _}, Map.get(spec, :provider)) ->
        {p, r} = Map.fetch!(spec, :provider)
        {p, r}

      match?({:pid, _}, Map.get(spec, :provider)) ->
        {p, r} = Map.fetch!(spec, :provider)
        {p, r}

      match?({:mfa, _}, Map.get(spec, :provider)) ->
        {p, r} = Map.fetch!(spec, :provider)
        {p, r}

      true ->
        raise ArgumentError, "service spec must include provider/provider_ref or provider tuple"
    end
  end

  defp normalize_capabilities(caps) when is_list(caps), do: Enum.map(caps, &to_string/1)
  defp normalize_capabilities(cap) when is_binary(cap), do: [cap]
  defp normalize_capabilities(cap) when is_atom(cap), do: [Atom.to_string(cap)]
  defp normalize_capabilities(_), do: []

  defp normalize_instance_spec(spec, tenant_id) do
    spec = Map.new(spec)

    %{
      instance_id: Map.get(spec, :instance_id, id("inst")),
      service_id: Map.fetch!(spec, :service_id),
      tenant_id: tenant_id,
      user_id: Map.get(spec, :user_id),
      session_id: Map.get(spec, :session_id),
      purpose: Map.get(spec, :purpose),
      labels: Map.get(spec, :labels, %{}),
      status: Map.get(spec, :status, :starting),
      endpoint_type: Map.get(spec, :endpoint_type),
      endpoint_ref: Map.get(spec, :endpoint_ref),
      health: Map.get(spec, :health, :unknown),
      last_error: Map.get(spec, :last_error),
      expires_at: Map.get(spec, :expires_at),
      visibility: Map.get(spec, :visibility, :private),
      metadata: Map.get(spec, :metadata, %{})
    }
  end

  defp caller_ctx(opts) do
    ctx = opts[:caller_ctx] || %{}
    defaults = AgentPolicy.scope_defaults(ctx)
    Map.merge(defaults, ctx)
    |> Map.put_new(:tenant_id, tenant_id(opts))
  end

  defp tenant_id(opts), do: Keyword.get(opts, :tenant_id, "default")
  defp store, do: Synaptic.AgentDirectory.Store.module()

  defp allow_or_error(:allow), do: :allow
  defp allow_or_error({:deny, reason}), do: {:deny, reason}

  defp now, do: DateTime.utc_now()

  defp id(prefix) do
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    prefix <> "_" <> rand
  end

  defp emit(event, metadata) do
    :telemetry.execute([:synaptic, :agent_directory, event], %{}, metadata)
  end
end
