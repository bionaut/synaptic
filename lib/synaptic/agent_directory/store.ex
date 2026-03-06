defmodule Synaptic.AgentDirectory.Store do
  @moduledoc """
  Pluggable storage backend for services, instances, and task references.
  """

  @type record :: map()

  @callback put_service(record()) :: {:ok, record()} | {:error, term()}
  @callback delete_service(String.t(), String.t()) :: :ok
  @callback get_service(String.t(), String.t()) :: {:ok, record()} | :error
  @callback list_services(map()) :: [record()]

  @callback put_instance(record()) :: {:ok, record()} | {:error, term()}
  @callback update_instance(String.t(), String.t(), (record() -> record())) ::
              {:ok, record()} | :error
  @callback delete_instance(String.t(), String.t()) :: :ok
  @callback get_instance(String.t(), String.t()) :: {:ok, record()} | :error
  @callback list_instances(map()) :: [record()]

  @callback put_task_reference(record()) :: {:ok, record()} | {:error, term()}
  @callback update_task_reference(String.t(), String.t(), (record() -> record())) ::
              {:ok, record()} | :error
  @callback get_task_reference(String.t(), String.t()) :: {:ok, record()} | :error
  @callback list_task_references(map()) :: [record()]
  @callback delete_task_reference(String.t(), String.t()) :: :ok

  @callback reset!() :: :ok

  def module do
    Application.get_env(:synaptic, :agent_directory_store, Synaptic.AgentDirectory.Store.InMemory)
  end
end
