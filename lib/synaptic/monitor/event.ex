defmodule Synaptic.Monitor.Event do
  @moduledoc """
  Normalized event envelope stored by the Synaptic monitor.
  """

  @enforce_keys [:id, :ts_ms, :kind, :status]
  defstruct [
    :id,
    :ts_ms,
    :kind,
    :status,
    :service_id,
    :instance_id,
    :task_ref_id,
    :run_id,
    :workflow,
    :step,
    :caller_agent_id,
    :target_service_id,
    :trace_id,
    :call_id,
    :parent_call_id,
    :request_id,
    :purpose,
    :summary,
    data: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: Map.get(attrs, :id, gen_id("evt")),
      ts_ms: Map.get(attrs, :ts_ms, System.system_time(:millisecond)),
      kind: Map.get(attrs, :kind, :info),
      status: Map.get(attrs, :status, :ok),
      service_id: normalize_id(Map.get(attrs, :service_id)),
      instance_id: normalize_id(Map.get(attrs, :instance_id)),
      task_ref_id: normalize_id(Map.get(attrs, :task_ref_id)),
      run_id: normalize_id(Map.get(attrs, :run_id)),
      workflow: normalize_workflow(Map.get(attrs, :workflow)),
      step: Map.get(attrs, :step),
      caller_agent_id: normalize_id(Map.get(attrs, :caller_agent_id)),
      target_service_id: normalize_id(Map.get(attrs, :target_service_id)),
      trace_id: normalize_id(Map.get(attrs, :trace_id)),
      call_id: normalize_id(Map.get(attrs, :call_id)),
      parent_call_id: normalize_id(Map.get(attrs, :parent_call_id)),
      request_id: normalize_id(Map.get(attrs, :request_id)),
      purpose: normalize_id(Map.get(attrs, :purpose)),
      summary: Map.get(attrs, :summary),
      data: Map.get(attrs, :data, %{}) |> Map.new()
    }
  end

  def to_map(%__MODULE__{} = event), do: Map.from_struct(event)

  def terminal_status?(status), do: status in [:completed, :failed, :stopped, :deregistered]

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp normalize_workflow(nil), do: nil
  defp normalize_workflow(value) when is_atom(value), do: inspect(value)
  defp normalize_workflow(value) when is_binary(value), do: value
  defp normalize_workflow(value), do: inspect(value)

  defp gen_id(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
