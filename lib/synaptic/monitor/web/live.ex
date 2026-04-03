if Code.ensure_loaded?(Phoenix.LiveView) and Code.ensure_loaded?(Phoenix.HTML) do
  defmodule Synaptic.Monitor.Web.Live do
    @moduledoc """
    Embeddable LiveView for browsing Synaptic monitor state inside a Phoenix app.
    """

    use Phoenix.LiveView

    import Phoenix.HTML, only: [raw: 1]

    alias Synaptic.Monitor
    alias Synaptic.Monitor.Web.Page

    @filter_fields ~w(service_id run_id request_id purpose caller_agent_id)a

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket), do: Monitor.subscribe()

      snapshot = Monitor.snapshot()
      selected = Page.selected_entity(snapshot, nil, nil)

      {:ok,
       assign(socket,
         snapshot: snapshot,
         selected_type: selected && selected.type,
         selected_id: selected && selected.id,
         filters: Map.new(@filter_fields, &{&1, ""}),
         graph_json: Jason.encode!(Page.graph(snapshot, selected))
       )}
    end

    @impl true
    def handle_info({:synaptic_monitor_event, _event}, socket) do
      snapshot = Monitor.snapshot()

      selected =
        Page.selected_entity(snapshot, socket.assigns.selected_type, socket.assigns.selected_id)

      {:noreply,
       assign(socket,
         snapshot: snapshot,
         selected_type: selected && selected.type,
         selected_id: selected && selected.id,
         graph_json: Jason.encode!(Page.graph(snapshot, selected))
       )}
    end

    @impl true
    def handle_event("select_entity", %{"type" => type, "id" => id}, socket) do
      selected_type = String.to_existing_atom(type)
      selected = Page.selected_entity(socket.assigns.snapshot, selected_type, id)

      {:noreply,
       assign(socket,
         selected_type: selected_type,
         selected_id: id,
         graph_json: Jason.encode!(Page.graph(socket.assigns.snapshot, selected))
       )}
    end

    def handle_event("filter", %{"filters" => filters}, socket) do
      normalized =
        Enum.into(@filter_fields, %{}, fn field ->
          {field, Map.get(filters, Atom.to_string(field), "")}
        end)

      {:noreply, assign(socket, filters: normalized)}
    end

    @impl true
    def render(assigns) do
      selected =
        Page.selected_entity(assigns.snapshot, assigns.selected_type, assigns.selected_id)

      events = Page.display_events(assigns.snapshot, selected, assigns.filters)
      summary = Page.focus_summary(assigns.snapshot, selected)

      assigns =
        assigns
        |> assign(:selected, selected)
        |> assign(:events, events)
        |> assign(:summary, summary)
        |> assign(:step_history, summary.step_history)
        |> assign(:groups, Page.entity_groups(assigns.snapshot))
        |> assign(:filter_fields, @filter_fields)
        |> assign(:styles, Page.styles())
        |> assign(:graph_script, Page.graph_script())

      ~H"""
      <div>
        <style><%= raw(@styles) %></style>
        <script><%= raw(@graph_script) %></script>

        <div class="monitor-shell">
          <div class="monitor-sidebar">
            <div class="pane">
              <div class="monitor-title">
                <h1>Synaptic Monitor</h1>
                <span class="pill">LiveView</span>
                <p class="monitor-copy">Selected run first, logs second, advanced internals collapsed until needed.</p>
              </div>
            </div>

            <%= for group <- @groups do %>
              <section class="pane">
                <h3><%= group.label %></h3>
                <div class="entity-list">
                  <%= for entity <- group.items do %>
                    <button
                      type="button"
                      class={["entity-button", @selected && @selected.id == entity.id && @selected.type == group.type && "active"]}
                      phx-click="select_entity"
                      phx-value-type={group.type}
                      phx-value-id={entity.id}
                      title={Page.entity_title(entity)}
                    >
                      <div class="entity-name"><%= Page.entity_title(entity) %></div>
                      <div class="entity-meta"><%= Page.entity_meta(entity) %></div>
                    </button>
                  <% end %>
                </div>
              </section>
            <% end %>
          </div>

          <div class="monitor-main">
            <div class="pane">
              <div class="hero-panel">
                <div class="hero-top">
                  <div>
                    <div class="hero-eyebrow">Selected Run</div>
                    <div class="hero-title"><%= @summary.current_step || @summary.headline %></div>
                    <div class="hero-subtitle">
                      <%= @summary.waiting_message || @summary.last_event && @summary.last_event.summary || "No active notes for this run." %>
                    </div>
                  </div>
                  <div class={["status-pill", to_string(@summary.status)]}><%= @summary.status || "unknown" %></div>
                </div>
                <div class="summary-grid">
                  <%= for {key, value} <- Page.summary_rows(@summary) do %>
                    <div class="summary-card">
                      <div class="summary-title"><%= key %></div>
                      <div class="summary-value"><%= value %></div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="pane">
              <div class="section-head">
                <h2>Topology</h2>
                <div class="section-copy">Live relationship view for the selected run and its surrounding context.</div>
              </div>
              <div class="graph-wrap">
                <synaptic-monitor-graph
                  id="synaptic-monitor-graph"
                  phx-update="ignore"
                  data-graph={@graph_json}
                ></synaptic-monitor-graph>
              </div>
              <div class="graph-overview"><%= Page.graph_overview(@snapshot) %></div>
              <div id="synaptic-monitor-topology-outline">
                <%= raw(Page.topology_outline_markup(@snapshot, @selected)) %>
              </div>
            </div>

            <div class="pane">
              <div class="section-head">
                <h2>Activity Log</h2>
                <div class="section-copy">Newest events first. Filters override the selected-run focus.</div>
              </div>
              <div class="event-list">
                <%= if @events == [] do %>
                  <div class="empty">No recent events.</div>
                <% else %>
                  <%= for event <- @events do %>
                    <div class="event-card">
                      <div class="event-time"><%= Page.format_timestamp(event.ts_ms) %></div>
                      <div class="event-summary"><%= event.summary || event.kind %></div>
                      <div class="event-meta"><%= Page.event_meta(event) %></div>
                      <div class="event-actions-row">
                        <div class="payload-label">Inspect</div>
                        <%= if Page.modal_actions(event) != [] do %>
                          <div class="event-actions">
                            <%= for action <- Page.modal_actions(event) do %>
                              <button
                                type="button"
                                class="payload-button"
                                data-monitor-modal-title={action.title}
                                data-monitor-modal-body={URI.encode(action.body)}
                              >
                                <%= action.label %>
                              </button>
                            <% end %>
                          </div>
                        <% else %>
                          <div class="payload-empty">No captured payloads</div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <div class="monitor-detail">
            <div class="pane">
              <h2>Context</h2>
              <div class="detail-card">
                <h3>Step History</h3>
                <%= if @step_history == [] do %>
                  <div class="empty">No step data yet.</div>
                <% else %>
                  <div class="step-list">
                    <%= for step <- @step_history do %>
                      <div class="step-card">
                        <div class="step-header">
                          <div class="step-name"><%= step.step %></div>
                          <div class={["step-status", to_string(step.status)]}><%= step.status %></div>
                        </div>
                        <div class="step-meta"><%= step.summary %></div>
                        <div class="event-actions-row">
                          <div class="payload-label">Inspect</div>
                          <%= if Map.get(step, :actions, []) != [] do %>
                            <div class="step-actions">
                              <%= for action <- Map.get(step, :actions, []) do %>
                                <button
                                  type="button"
                                  class="payload-button"
                                  data-monitor-modal-title={action.title}
                                  data-monitor-modal-body={URI.encode(action.body)}
                                >
                                  <%= action.label %>
                                </button>
                              <% end %>
                            </div>
                          <% else %>
                            <div class="payload-empty">No captured payloads</div>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

              <div class="detail-card">
                <h3>Notes</h3>
                <div class="detail-grid">
                  <%= for {key, value} <- Page.note_rows(@summary) do %>
                    <div class="detail-row">
                      <div class="detail-key"><%= key %></div>
                      <div><%= value %></div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= if @selected do %>
                <details class="collapsible-panel">
                  <summary>Filters</summary>
                  <div class="collapsible-body">
                    <.form for={to_form(Enum.into(@filters, %{}, fn {key, value} -> {Atom.to_string(key), value} end), as: :filters)} phx-change="filter">
                      <div class="filter-grid">
                        <%= for field <- @filter_fields do %>
                          <input type="text" name={"filters[#{field}]"} value={Map.get(@filters, field)} placeholder={field} />
                        <% end %>
                      </div>
                    </.form>
                  </div>
                </details>

                <details class="collapsible-panel">
                  <summary>Raw Entity</summary>
                  <div class="collapsible-body">
                    <div class="detail-grid">
                      <%= for {key, value} <- Page.entity_rows(@selected) do %>
                        <div class="detail-row">
                          <div class="detail-key"><%= key %></div>
                          <div><%= inspect(value, pretty: true) %></div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </details>
              <% else %>
                <div class="empty">No entities yet.</div>
              <% end %>
            </div>
          </div>
        </div>

        <div id="synaptic-monitor-modal-shell" phx-update="ignore">
          <%= raw(Page.modal_markup()) %>
        </div>
      </div>
      """
    end

    @impl true
    def terminate(_reason, _socket) do
      Monitor.unsubscribe()
      :ok
    end
  end
end
