defmodule Synaptic.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc """
  OTP application entry point that starts the registry, runtime supervisor,
  PubSub, and Finch pool required by Synaptic.
  """

  use Application

  @impl true
  @spec start(any(), any()) :: {:error, any()} | {:ok, pid()}
  def start(_type, _args) do
    children = [
      Synaptic.Registry,
      Synaptic.RuntimeSupervisor,
      Synaptic.AgentDirectory.Store.InMemory,
      Synaptic.AgentDirectory,
      Synaptic.WorkloadManager,
      Synaptic.AgentRouter,
      Synaptic.Voice.Registry,
      Synaptic.Voice.SessionSupervisor,
      Synaptic.Voice.Realtime.Registry,
      Synaptic.Voice.Realtime.SessionSupervisor,
      {Phoenix.PubSub, name: Synaptic.PubSub},
      {Finch, name: Synaptic.Finch}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [
      strategy: :one_for_one,
      name: Synaptic.Supervisor
    ]

    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(_changed, _new, _removed), do: :ok
end
