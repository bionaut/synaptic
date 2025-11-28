defmodule Synapse.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Synapse.Registry,
      Synapse.RuntimeSupervisor,
      SynapseWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:synapse, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Synapse.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Synapse.Finch},
      # Start a worker by calling: Synapse.Worker.start_link(arg)
      # {Synapse.Worker, arg},
      # Start to serve requests, typically the last entry
      SynapseWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Synapse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SynapseWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
