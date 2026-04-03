if Code.ensure_loaded?(Plug.Conn.Status) do
  defmodule Synaptic.Monitor.Web.ErrorHTML do
    @moduledoc false

    def render(template, _assigns) do
      template
      |> status_from_template()
      |> Plug.Conn.Status.reason_phrase()
    end

    defp status_from_template(template) do
      template
      |> template_name()
      |> Integer.parse()
      |> case do
        {status, _rest} -> status
        :error -> 500
      end
    end

    defp template_name(template) when is_binary(template) do
      template
      |> String.split(".")
      |> List.first()
    end
  end
end
