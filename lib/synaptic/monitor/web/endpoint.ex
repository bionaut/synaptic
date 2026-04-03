if Code.ensure_loaded?(Phoenix.Endpoint) do
  defmodule Synaptic.Monitor.Web.Endpoint do
    @moduledoc false

    use Phoenix.Endpoint, otp_app: :synaptic

    plug Plug.RequestId
    plug Plug.Telemetry, event_prefix: [:synaptic, :monitor, :web]
    plug Synaptic.Monitor.Web.Router
  end
end
