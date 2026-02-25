defmodule Synaptic.AgentPolicy.Default do
  @moduledoc """
  Default policy: tenant-aware and permissive for non-private records, while
  private records require owner alignment when owner metadata is present.
  """

  @behaviour Synaptic.AgentPolicy

  @impl true
  def authorize_discovery(caller_ctx, record, _action) do
    if same_tenant?(caller_ctx, record) and visible?(caller_ctx, record) do
      :allow
    else
      {:deny, :invisible}
    end
  end

  @impl true
  def authorize_invoke(caller_ctx, _caller_identity, callee_record, _invocation) do
    if same_tenant?(caller_ctx, callee_record) and visible?(caller_ctx, callee_record) do
      :allow
    else
      {:deny, :unauthorized}
    end
  end

  @impl true
  def filter_visible_records(caller_ctx, records) do
    Enum.filter(records, fn rec ->
      authorize_discovery(caller_ctx, rec, :list) == :allow
    end)
  end

  @impl true
  def scope_defaults(_caller_ctx), do: %{tenant_id: "default"}

  defp same_tenant?(caller_ctx, record) do
    record_tenant = Map.get(record, :tenant_id, "default")
    caller_tenant = Map.get(caller_ctx, :tenant_id, "default")
    record_tenant == caller_tenant
  end

  defp visible?(caller_ctx, record) do
    case Map.get(record, :visibility, :private) do
      :public -> true
      :tenant -> true
      :private -> private_visible?(caller_ctx, record)
      _ -> false
    end
  end

  defp private_visible?(caller_ctx, record) do
    owner_user_id = Map.get(record, :user_id) || get_in(record, [:metadata, :owner_user_id])
    owner_agent_id = get_in(record, [:metadata, :owner_agent_id])

    cond do
      owner_user_id && Map.get(caller_ctx, :user_id) == owner_user_id -> true
      owner_agent_id && Map.get(caller_ctx, :caller_agent_id) == owner_agent_id -> true
      is_nil(owner_user_id) and is_nil(owner_agent_id) -> false
      true -> false
    end
  end
end
