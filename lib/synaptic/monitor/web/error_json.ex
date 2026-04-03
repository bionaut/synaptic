if Code.ensure_loaded?(Plug.Conn.Status) do
  defmodule Synaptic.Monitor.Web.ErrorJSON do
    @moduledoc false

    def render(template, _assigns) do
      status =
        template
        |> String.split(".")
        |> List.first()
        |> Integer.parse()
        |> case do
          {value, _rest} -> value
          :error -> 500
        end

      %{errors: %{detail: Plug.Conn.Status.reason_phrase(status)}}
    end
  end
end
