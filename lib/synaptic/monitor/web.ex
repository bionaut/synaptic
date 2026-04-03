if Code.ensure_loaded?(Phoenix.Endpoint) do
  defmodule Synaptic.Monitor.Web do
    @moduledoc """
    Standalone browser viewer for the Synaptic monitor.
    """

    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__.Supervisor))
    end

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :supervisor
      }
    end

    @impl true
    def init(opts) do
      configure_endpoint(opts)
      Supervisor.init([Synaptic.Monitor.Web.Endpoint], strategy: :one_for_one)
    end

    defp configure_endpoint(opts) do
      port = Keyword.get(opts, :port, 4050)
      adapter = Keyword.get(opts, :adapter, server_adapter!())

      Application.put_env(
        :synaptic,
        Synaptic.Monitor.Web.Endpoint,
        [
          adapter: adapter,
          url: [host: "localhost"],
          http: [ip: {127, 0, 0, 1}, port: port],
          secret_key_base: String.duplicate("monitor_secret_key_base_", 4),
          server: true,
          render_errors: [
            formats: [
              html: Synaptic.Monitor.Web.ErrorHTML,
              json: Synaptic.Monitor.Web.ErrorJSON
            ],
            layout: false
          ],
          pubsub_server: Synaptic.PubSub,
          live_view: [signing_salt: "synaptic-monitor-salt"]
        ]
      )
    end

    defp server_adapter! do
      cond do
        Code.ensure_loaded?(Plug.Cowboy) and function_exported?(Plug.Cowboy, :child_spec, 1) ->
          Phoenix.Endpoint.Cowboy2Adapter

        Code.ensure_loaded?(Bandit.PhoenixAdapter) and function_exported?(Bandit.PhoenixAdapter, :child_specs, 2) ->
          Bandit.PhoenixAdapter

        true ->
          raise """
          Synaptic standalone monitor could not start because no supported Phoenix HTTP adapter is available.

          Install one of:
          - {:plug_cowboy, "~> 2.7"}
          - {:bandit, "~> 1.0"}
          """
      end
    end
  end
end
