defmodule Synaptic.Agent do
  @moduledoc """
  Convenience registration and lifecycle facade for agent directory records.
  """

  alias Synaptic.AgentDirectory

  def register_service(service_id, spec, opts \\ []), do: AgentDirectory.register_service(service_id, spec, opts)
  def deregister_service(service_id, opts \\ []), do: AgentDirectory.deregister_service(service_id, opts)

  def register_instance(instance_spec, opts \\ []), do: AgentDirectory.register_instance(instance_spec, opts)
  def heartbeat_instance(instance_id, attrs \\ %{}, opts \\ []), do: AgentDirectory.heartbeat_instance(instance_id, attrs, opts)
  def update_instance(instance_id, attrs, opts \\ []), do: AgentDirectory.update_instance(instance_id, attrs, opts)
  def deregister_instance(instance_id, opts \\ []), do: AgentDirectory.deregister_instance(instance_id, opts)
end
