if Code.ensure_loaded?(Phoenix.Controller) do
  defmodule Synaptic.Monitor.Web.PageController do
    @moduledoc false

    use Phoenix.Controller, formats: [:html, :json]

    alias Synaptic.Monitor
    alias Synaptic.Monitor.Web.Page

    def index(conn, _params) do
      snapshot = Monitor.snapshot()
      selected = Page.selected_entity(snapshot, nil, nil)
      serializable_snapshot = json_safe(snapshot)
      graph_json = Jason.encode!(Page.graph(snapshot, selected))
      snapshot_json = Jason.encode!(serializable_snapshot)

      html(
        conn,
        """
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <title>Synaptic Monitor</title>
            <style>#{Page.styles()}</style>
          </head>
          <body>
            <div id="synaptic-monitor-root" data-snapshot-url="/api/snapshot">
              <div class="monitor-shell">
                <div class="monitor-sidebar">
                  <div class="pane">
                    <div class="monitor-title">
                      <h1>Synaptic Monitor</h1>
                      <span class="pill">Standalone</span>
                      <p class="monitor-copy">Track the selected run first. Topology and raw internals stay available, but out of the way.</p>
                    </div>
                  </div>
                  <div id="synaptic-monitor-entities"></div>
                </div>
                <div class="monitor-main">
                  <div class="pane">
                    <div id="synaptic-monitor-focus"></div>
                  </div>
                  <div class="pane">
                    <div class="section-head">
                      <h2>Topology</h2>
                      <div class="section-copy">Live relationship view for the selected run and its surrounding context.</div>
                    </div>
                    <div class="graph-wrap">
                      <synaptic-monitor-graph id="synaptic-monitor-graph" data-graph='#{graph_json}'></synaptic-monitor-graph>
                    </div>
                    <div id="synaptic-monitor-graph-overview" class="graph-overview">#{Page.graph_overview(snapshot)}</div>
                    <div id="synaptic-monitor-topology-outline">#{Page.topology_outline_markup(snapshot, selected)}</div>
                  </div>
                  <div class="pane">
                    <div class="section-head">
                      <h2>Activity Log</h2>
                      <div class="section-copy">Newest events first, scoped to the selected run unless filters are active.</div>
                    </div>
                    <div id="synaptic-monitor-events" class="event-list"></div>
                  </div>
                </div>
                <div class="monitor-detail">
                  <div class="pane">
                    <h2>Context</h2>
                    <div id="synaptic-monitor-inspector" class="advanced-stack"></div>
                  </div>
                  <div class="pane">
                    <details class="collapsible-panel">
                      <summary>Filters</summary>
                      <div class="collapsible-body">
                        <form id="synaptic-monitor-filters">
                          <div class="filter-grid">
                            <input type="text" name="service_id" placeholder="service_id" />
                            <input type="text" name="run_id" placeholder="run_id" />
                            <input type="text" name="request_id" placeholder="request_id" />
                            <input type="text" name="purpose" placeholder="purpose" />
                            <input type="text" name="caller_agent_id" placeholder="caller_agent_id" />
                          </div>
                        </form>
                      </div>
                    </details>
                  </div>
                </div>
              </div>
            </div>
            <script>
              window.__synapticMonitorInitialSnapshot = #{snapshot_json};
            </script>
            #{Page.modal_markup()}
            <script>#{Page.standalone_script()}</script>
          </body>
        </html>
        """
      )
    end

    def snapshot(conn, _params) do
      json(conn, json_safe(Monitor.snapshot()))
    end

    def favicon(conn, _params) do
      send_resp(conn, 204, "")
    end

    defp json_safe(%Date{} = value), do: value
    defp json_safe(%DateTime{} = value), do: value
    defp json_safe(%NaiveDateTime{} = value), do: value
    defp json_safe(%Time{} = value), do: value

    defp json_safe(%module{} = value) do
      base =
        if Kernel.is_exception(value) do
          %{
            __struct__: inspect(module),
            message: Exception.message(value)
          }
        else
          value
          |> Map.from_struct()
          |> Map.put_new(:__struct__, inspect(module))
        end

      json_safe(base)
    end

    defp json_safe(value) when is_map(value) do
      value
      |> Enum.map(fn {key, item} -> {json_safe_key(key), json_safe(item)} end)
      |> Enum.into(%{})
    end

    defp json_safe(value) when is_list(value) do
      Enum.map(value, &json_safe/1)
    end

    defp json_safe(value) when is_tuple(value) do
      value
      |> Tuple.to_list()
      |> Enum.map(&json_safe/1)
    end

    defp json_safe(value)
         when is_pid(value) or is_reference(value) or is_port(value) or is_function(value) do
      inspect(value)
    end

    defp json_safe(value), do: value

    defp json_safe_key(key) when is_atom(key), do: key
    defp json_safe_key(key), do: to_string(key)
  end
end
