defmodule Synaptic.AgentPolicy do
  @moduledoc """
  Behavior for host-provided agent discovery and invocation authorization.
  """

  @type caller_ctx :: map()
  @type record :: map()
  @type invocation :: map()

  @callback authorize_discovery(caller_ctx(), record(), atom()) :: :allow | {:deny, term()}
  @callback authorize_invoke(caller_ctx(), term(), record(), invocation()) ::
              :allow | {:deny, term()}
  @callback filter_visible_records(caller_ctx(), [record()]) :: [record()]
  @callback scope_defaults(caller_ctx()) :: map()

  @optional_callbacks filter_visible_records: 2, scope_defaults: 1

  def module do
    Application.get_env(:synaptic, :agent_policy_module, Synaptic.AgentPolicy.Default)
  end

  def authorize_discovery(caller_ctx, record, action) do
    module().authorize_discovery(caller_ctx, record, action)
  end

  def authorize_invoke(caller_ctx, caller_identity, callee_record, invocation) do
    module().authorize_invoke(caller_ctx, caller_identity, callee_record, invocation)
  end

  def filter_visible_records(caller_ctx, records) do
    mod = module()

    if function_exported?(mod, :filter_visible_records, 2) do
      mod.filter_visible_records(caller_ctx, records)
    else
      Enum.filter(records, fn record ->
        authorize_discovery(caller_ctx, record, :list) == :allow
      end)
    end
  end

  def scope_defaults(caller_ctx) do
    mod = module()

    if function_exported?(mod, :scope_defaults, 1), do: mod.scope_defaults(caller_ctx), else: %{}
  end
end
