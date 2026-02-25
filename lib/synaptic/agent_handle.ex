defmodule Synaptic.AgentHandle do
  @moduledoc """
  Opaque-ish handle returned by agent router calls and jobs.
  """

  @enforce_keys [:target_type]
  defstruct [
    :target_type,
    :service_id,
    :instance_id,
    :task_ref_id,
    :run_id,
    :job_id,
    :tenant_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          target_type: :service | :instance | :task_ref | :job,
          service_id: String.t() | nil,
          instance_id: String.t() | nil,
          task_ref_id: String.t() | nil,
          run_id: String.t() | nil,
          job_id: String.t() | nil,
          tenant_id: String.t() | nil,
          metadata: map()
        }
end
