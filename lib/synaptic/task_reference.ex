defmodule Synaptic.TaskReference do
  @moduledoc """
  Structured task reference memory record used for durable task lookup.
  """

  @enforce_keys [:task_ref_id, :tenant_id, :user_id, :service_id, :capability, :status]
  defstruct [
    :task_ref_id,
    :tenant_id,
    :user_id,
    :session_id,
    :caller_agent_id,
    :service_id,
    :instance_id,
    :run_id,
    :capability,
    :purpose,
    :status,
    :inserted_at,
    :updated_at,
    :last_activity_at,
    alias_keys: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{}
end
