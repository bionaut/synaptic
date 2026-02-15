defmodule Synaptic.Voice.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor responsible for `Synaptic.Voice.Session` processes.
  """

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
