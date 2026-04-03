if Code.ensure_loaded?(Phoenix.HTML) do
  defmodule Synaptic.Monitor.Web.Page do
    @moduledoc false

    alias Synaptic.Monitor

    def graph(snapshot, selected \\ nil) do
      now_ms = System.system_time(:millisecond)
      context = graph_context(snapshot, selected, now_ms)

      entity_nodes =
        snapshot
        |> entity_groups()
        |> Enum.flat_map(fn %{type: type, items: items} ->
          Enum.map(items, &graph_node(&1, type, context))
        end)

      edge_nodes = Enum.map(snapshot.edges, &graph_edge(&1, context))

      %{
        nodes: entity_nodes,
        edges: edge_nodes,
        meta: %{
          overview: graph_overview(snapshot),
          active_runs: context.active_runs_count,
          waiting_runs: context.waiting_runs_count
        }
      }
    end

    def graph_overview(snapshot) do
      runs = Map.values(snapshot.runs)
      active_runs = Enum.count(runs, &active_status?(Map.get(&1, :status)))
      waiting_runs = Enum.count(runs, &(Map.get(&1, :status) == :waiting_for_human))
      failed_runs = Enum.count(runs, &(Map.get(&1, :status) in [:failed, :stopped]))
      entity_count = Enum.sum(Enum.map(entity_groups(snapshot), &length(&1.items)))

      [
        "#{entity_count} nodes",
        "#{length(snapshot.edges)} links",
        "#{active_runs} active",
        waiting_runs > 0 && "#{waiting_runs} waiting",
        failed_runs > 0 && "#{failed_runs} unhealthy"
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" • ")
    end

    def entity_groups(snapshot) do
      [
        %{label: "Runs", type: :run, items: entities(snapshot.runs)},
        %{label: "Workflows", type: :workflow, items: entities(snapshot.workflows)},
        %{label: "Instances", type: :instance, items: entities(snapshot.instances)},
        %{label: "Task refs", type: :task_ref, items: entities(snapshot.task_refs)},
        %{label: "Services", type: :service, items: entities(snapshot.services)}
      ]
      |> Enum.filter(&(&1.items != []))
    end

    def selected_entity(snapshot, nil, nil), do: default_entity(snapshot)

    def selected_entity(snapshot, selected_type, selected_id) do
      Monitor.entity(selected_type, selected_id) || default_entity(snapshot)
    end

    def filter_events(snapshot, filters) do
      filters = normalize_filters(filters)

      Enum.filter(snapshot.events, fn event ->
        Enum.all?(filters, fn
          {_key, ""} -> true
          {_key, nil} -> true
          {key, value} -> to_string(Map.get(event, key) || "") == value
        end)
      end)
    end

    def display_events(snapshot, selected, filters) do
      filtered_events = filter_events(snapshot, filters)

      if blank_filters?(filters) do
        focus_events(snapshot, selected, filtered_events)
      else
        filtered_events
      end
    end

    def focus_run(snapshot, nil), do: latest_active_run(snapshot)

    def focus_run(snapshot, %{type: :run, id: id}) do
      Map.get(snapshot.runs, id)
    end

    def focus_run(snapshot, %{type: :workflow, id: id}) do
      latest_run(snapshot, &(Map.get(&1, :workflow) == id))
    end

    def focus_run(snapshot, %{type: :service, id: id}) do
      latest_run(snapshot, &(Map.get(&1, :service_id) == id))
    end

    def focus_run(snapshot, %{type: :instance, id: id}) do
      latest_run(snapshot, &(Map.get(&1, :instance_id) == id))
    end

    def focus_run(snapshot, %{type: :task_ref, id: id}) do
      latest_run(snapshot, &(Map.get(&1, :task_ref_id) == id))
    end

    def focus_run(_snapshot, _selected), do: nil

    def focus_events(snapshot, selected, events \\ nil)

    def focus_events(snapshot, selected, nil) do
      focus_events(snapshot, selected, snapshot.events)
    end

    def focus_events(snapshot, selected, events) do
      case focus_run(snapshot, selected) do
        %{run_id: run_id} ->
          Enum.filter(events, &(Map.get(&1, :run_id) == run_id))

        %{type: :service, id: id} ->
          Enum.filter(events, fn event ->
            Map.get(event, :service_id) == id or Map.get(event, :target_service_id) == id or
              Map.get(event, :caller_agent_id) == id
          end)

        %{type: :instance, id: id} ->
          Enum.filter(events, &(Map.get(&1, :instance_id) == id))

        %{type: :task_ref, id: id} ->
          Enum.filter(events, &(Map.get(&1, :task_ref_id) == id))

        %{type: :workflow, id: id} ->
          Enum.filter(events, &(Map.get(&1, :workflow) == id))

        _ ->
          events
      end
    end

    def focus_summary(snapshot, selected) do
      run = focus_run(snapshot, selected)

      events =
        snapshot
        |> focus_events(selected)
        |> Enum.sort_by(&{Map.get(&1, :ts_ms, 0), inspect(Map.get(&1, :kind))}, :desc)

      waiting_event =
        Enum.find(events, fn event ->
          event.status == :waiting_for_human or
            get_in(event, [:data, :event]) == :waiting_for_human
        end)

      step_history = step_history(run, events)
      current_step = current_step(run)

      %{
        headline: focus_headline(selected, run),
        selected_type: selected && Map.get(selected, :type),
        status: (run && Map.get(run, :status)) || (selected && Map.get(selected, :status)),
        workflow: run && Map.get(run, :workflow),
        run_id: run && Map.get(run, :run_id),
        service_id: run && Map.get(run, :service_id),
        instance_id: run && Map.get(run, :instance_id),
        current_step: current_step,
        executed_steps: Enum.filter(step_history, &(Map.get(&1, :status) == :completed)),
        step_history: step_history,
        event_count: length(events),
        waiting_message: waiting_message(events),
        waiting_at_ms: waiting_event && waiting_event.ts_ms,
        last_error: run && Map.get(run, :last_error),
        updated_at_ms:
          (run && Map.get(run, :updated_at_ms)) || (selected && Map.get(selected, :updated_at_ms)) ||
            (List.first(events) && List.first(events).ts_ms),
        last_event: List.first(events)
      }
    end

    def step_history(run, events) do
      current_step = current_step(run)

      run
      |> step_events(events)
      |> Enum.sort_by(& &1.ts_ms)
      |> Enum.reduce([], fn event, acc ->
        entry =
          %{
            step: to_string(event.step),
            status: step_status(event),
            summary: event.summary,
            ts_ms: event.ts_ms
          }
          |> maybe_put_step_actions(event)

        upsert_step_entry(acc, entry)
      end)
      |> maybe_append_current_step(current_step, run)
    end

    def styles do
      """
      :root { --bg: #091120; --panel: rgba(13, 24, 42, 0.88); --panel-soft: rgba(9, 17, 32, 0.58); --border: rgba(148, 163, 184, 0.16); --text: #e6eefc; --muted: #8da2c5; --accent: #93c5fd; --accent-soft: rgba(147, 197, 253, 0.12); }
      body { margin: 0; font-family: Menlo, Monaco, monospace; background: radial-gradient(circle at top, #14233d 0%, var(--bg) 52%); color: var(--text); }
      .monitor-shell { display: grid; grid-template-columns: 206px minmax(0, 1fr) 264px; min-height: 100vh; }
      .monitor-shell > * { min-width: 0; }
      .monitor-sidebar, .monitor-main, .monitor-detail { border-right: 1px solid var(--border); }
      .monitor-detail { border-right: 0; background: rgba(5, 11, 20, 0.3); }
      .pane { padding: 18px 18px 0; }
      .pane:last-child { padding-bottom: 18px; }
      .pane h1, .pane h2, .pane h3 { margin: 0 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: 0.08em; color: #a8c8ff; }
      .monitor-copy { margin: 0; font-size: 12px; color: var(--muted); line-height: 1.5; max-width: 24ch; }
      .pill { display: inline-block; padding: 2px 8px; border-radius: 999px; background: var(--accent-soft); color: #dbeafe; font-size: 11px; }
      .entity-list, .event-list, .step-list, .advanced-stack { display: grid; gap: 10px; }
      .entity-button { width: 100%; min-width: 0; text-align: left; border: 1px solid var(--border); background: rgba(10, 18, 31, 0.72); color: inherit; padding: 12px; border-radius: 12px; cursor: pointer; overflow: hidden; }
      .entity-button.active { border-color: rgba(147, 197, 253, 0.38); background: rgba(17, 31, 52, 0.92); box-shadow: inset 0 0 0 1px rgba(147, 197, 253, 0.08); }
      .entity-name { font-weight: 700; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .entity-meta { font-size: 11px; color: var(--muted); margin-top: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .hero-panel, .event-card, .detail-card, .collapsible-panel { border: 1px solid var(--border); border-radius: 14px; background: linear-gradient(180deg, rgba(16, 29, 48, 0.95), rgba(10, 18, 31, 0.92)); }
      .hero-panel { padding: 18px; display: grid; gap: 16px; }
      .hero-top { display: flex; justify-content: space-between; gap: 16px; align-items: flex-start; }
      .hero-eyebrow { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.1em; margin-bottom: 8px; }
      .hero-title { font-size: 28px; line-height: 1.06; font-weight: 700; color: var(--text); }
      .hero-subtitle { font-size: 13px; line-height: 1.5; color: var(--muted); max-width: 54ch; }
      .status-pill { display: inline-flex; align-items: center; padding: 8px 12px; border-radius: 999px; border: 1px solid var(--border); background: rgba(255,255,255,0.03); font-size: 11px; text-transform: uppercase; letter-spacing: 0.08em; color: var(--text); white-space: nowrap; }
      .status-pill.waiting_for_human { color: #fde68a; border-color: rgba(251, 191, 36, 0.24); background: rgba(251, 191, 36, 0.1); }
      .status-pill.running { color: #bae6fd; border-color: rgba(56, 189, 248, 0.24); background: rgba(56, 189, 248, 0.1); }
      .status-pill.completed { color: #bbf7d0; border-color: rgba(34, 197, 94, 0.24); background: rgba(34, 197, 94, 0.1); }
      .status-pill.failed, .status-pill.stopped { color: #fecaca; border-color: rgba(248, 113, 113, 0.24); background: rgba(248, 113, 113, 0.1); }
      .summary-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 10px; }
      .summary-card { border: 1px solid var(--border); border-radius: 12px; padding: 12px; background: var(--panel-soft); }
      .summary-title { font-size: 10px; color: var(--muted); margin-bottom: 6px; text-transform: uppercase; letter-spacing: 0.08em; }
      .summary-value { font-size: 13px; color: var(--text); word-break: break-word; line-height: 1.4; }
      .event-card, .detail-card { padding: 12px 14px; }
      .event-time { font-size: 11px; color: var(--accent); margin-bottom: 8px; }
      .event-summary { font-weight: 700; color: var(--text); line-height: 1.45; }
      .event-meta, .detail-key, .step-meta { font-size: 11px; color: var(--muted); }
      .event-actions-row { display: flex; align-items: center; gap: 10px; margin-top: 12px; min-height: 30px; }
      .event-actions, .step-actions { display: flex; flex-wrap: wrap; gap: 8px; }
      .payload-label { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.12em; min-width: 54px; }
      .payload-empty { font-size: 11px; color: rgba(141, 162, 197, 0.82); }
      .payload-button { appearance: none; border: 1px solid rgba(147, 197, 253, 0.24); background: rgba(147, 197, 253, 0.08); color: #dbeafe; border-radius: 999px; padding: 6px 10px; font: inherit; font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; cursor: pointer; }
      .payload-button:hover { background: rgba(147, 197, 253, 0.16); border-color: rgba(147, 197, 253, 0.4); }
      .detail-grid { display: grid; gap: 10px; }
      .detail-row { display: grid; gap: 4px; }
      .step-card { border: 1px solid var(--border); border-radius: 12px; padding: 12px; background: var(--panel-soft); }
      .step-header { display: flex; justify-content: space-between; gap: 8px; align-items: center; }
      .step-name { font-weight: 700; color: var(--text); }
      .step-status { font-size: 10px; padding: 3px 8px; border-radius: 999px; background: rgba(56, 189, 248, 0.16); color: #bae6fd; text-transform: uppercase; letter-spacing: 0.08em; }
      .step-status.completed { background: rgba(34, 197, 94, 0.16); color: #bbf7d0; }
      .step-status.running { background: rgba(56, 189, 248, 0.16); color: #bae6fd; }
      .step-status.waiting { background: rgba(245, 158, 11, 0.18); color: #fde68a; }
      .step-status.failed, .step-status.stopped { background: rgba(239, 68, 68, 0.18); color: #fecaca; }
      .collapsible-panel { padding: 12px 14px; }
      .collapsible-panel summary { cursor: pointer; list-style: none; font-size: 12px; text-transform: uppercase; letter-spacing: 0.08em; color: #a8c8ff; }
      .collapsible-panel summary::-webkit-details-marker { display: none; }
      .collapsible-body { margin-top: 12px; }
      .graph-wrap { height: 388px; border: 1px solid var(--border); border-radius: 16px; overflow: hidden; background: radial-gradient(circle at top, rgba(27, 45, 74, 0.78), rgba(7, 13, 24, 0.96)); position: relative; }
      .graph-wrap::after { content: ""; position: absolute; inset: 0; pointer-events: none; background: linear-gradient(180deg, rgba(147, 197, 253, 0.04), rgba(0,0,0,0)); }
      .graph-wrap synaptic-monitor-graph { display: block; width: 100%; height: 100%; position: relative; z-index: 1; }
      .graph-overview { margin-top: 10px; font-size: 11px; color: var(--muted); }
      .topology-outline-card { margin-top: 12px; }
      .outline-section { margin-top: 14px; display: grid; gap: 8px; }
      .outline-list { display: grid; gap: 8px; }
      .outline-item { border: 1px solid var(--border); border-radius: 12px; padding: 10px 12px; background: rgba(7, 13, 24, 0.34); }
      .outline-item.selected { border-color: rgba(253, 230, 138, 0.38); background: rgba(71, 58, 25, 0.28); }
      .outline-item.focus { border-color: rgba(248, 250, 252, 0.34); background: rgba(27, 39, 56, 0.34); }
      .outline-item.hot { border-color: rgba(125, 211, 252, 0.32); }
      .outline-title { font-size: 12px; color: var(--text); font-weight: 700; line-height: 1.4; }
      .outline-meta { font-size: 11px; color: var(--muted); margin-top: 4px; line-height: 1.45; }
      .filter-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
      .filter-grid input { width: 100%; padding: 8px 10px; background: rgba(7, 13, 24, 0.46); color: var(--text); border: 1px solid var(--border); border-radius: 10px; }
      .empty { color: var(--muted); font-size: 12px; }
      .monitor-modal[hidden] { display: none; }
      .monitor-modal { position: fixed; inset: 0; z-index: 50; }
      .monitor-modal-backdrop { position: absolute; inset: 0; background: rgba(3, 7, 18, 0.76); backdrop-filter: blur(6px); }
      .monitor-modal-card { position: relative; width: min(920px, calc(100vw - 48px)); max-height: calc(100vh - 72px); margin: 36px auto; border: 1px solid rgba(148, 163, 184, 0.22); border-radius: 18px; background: linear-gradient(180deg, rgba(16, 29, 48, 0.98), rgba(8, 14, 25, 0.98)); box-shadow: 0 20px 80px rgba(0, 0, 0, 0.45); overflow: hidden; }
      .monitor-modal-header { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 16px 18px; border-bottom: 1px solid var(--border); }
      .monitor-modal-title { margin: 0; font-size: 14px; text-transform: uppercase; letter-spacing: 0.08em; color: #dbeafe; }
      .monitor-modal-close { appearance: none; border: 1px solid var(--border); background: rgba(255,255,255,0.04); color: var(--text); border-radius: 999px; padding: 8px 12px; font: inherit; cursor: pointer; }
      .monitor-modal-body { margin: 0; padding: 18px; max-height: calc(100vh - 180px); overflow: auto; font: inherit; font-size: 12px; line-height: 1.55; color: #dbeafe; white-space: pre-wrap; word-break: break-word; background: rgba(4, 8, 17, 0.76); }
      @media (max-width: 1180px) { .monitor-shell { grid-template-columns: 190px 1fr; } .monitor-detail { grid-column: 1 / -1; border-top: 1px solid var(--border); } .summary-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } .graph-wrap { height: 340px; } }
      @media (max-width: 840px) { .monitor-shell { grid-template-columns: 1fr; } .monitor-sidebar, .monitor-main { border-right: 0; border-bottom: 1px solid var(--border); } .summary-grid { grid-template-columns: 1fr; } .hero-top { display: grid; } .graph-wrap { height: 286px; } }
      """
    end

    def graph_script do
      """
      (function () {
        if (!window.__synapticMonitorModalBound) {
          window.__synapticMonitorModalBound = true;
          window.__synapticMonitorModalState = window.__synapticMonitorModalState || {
            open: false,
            title: "Payload",
            body: ""
          };

          function synapticModalElements() {
            return {
              modal: document.getElementById("synaptic-monitor-modal"),
              title: document.getElementById("synaptic-monitor-modal-title"),
              body: document.getElementById("synaptic-monitor-modal-body")
            };
          }

          function syncSynapticModal() {
            const { modal, title, body } = synapticModalElements();
            const state = window.__synapticMonitorModalState;
            if (!modal || !title || !body || !state) return;
            title.textContent = state.title || "Payload";
            body.textContent = state.body || "";
            modal.hidden = !state.open;
          }

          function closeSynapticModal() {
            window.__synapticMonitorModalState = {
              open: false,
              title: "Payload",
              body: ""
            };

            const { modal } = synapticModalElements();
            if (modal) modal.hidden = true;
          }

          function openSynapticModal(title, body) {
            window.__synapticMonitorModalState = {
              open: true,
              title: title || "Payload",
              body: body || ""
            };

            const { modal, title: titleEl, body: bodyEl } = synapticModalElements();
            if (!modal || !titleEl || !bodyEl) return;
            titleEl.textContent = title || "Payload";
            bodyEl.textContent = body || "";
            modal.hidden = false;
          }

          document.addEventListener("click", (event) => {
            const trigger = event.target.closest("[data-monitor-modal-body]");
            if (trigger) {
              event.preventDefault();
              openSynapticModal(
                trigger.getAttribute("data-monitor-modal-title") || "Payload",
                decodeURIComponent(trigger.getAttribute("data-monitor-modal-body") || "")
              );
              return;
            }

            if (event.target.closest("[data-monitor-modal-close]")) {
              event.preventDefault();
              closeSynapticModal();
            }
          });

          document.addEventListener("keydown", (event) => {
            if (event.key === "Escape") closeSynapticModal();
          });

          document.addEventListener("phx:page-loading-stop", () => requestAnimationFrame(syncSynapticModal));
          document.addEventListener("phx:update", () => requestAnimationFrame(syncSynapticModal));

          if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", syncSynapticModal, { once: true });
          } else {
            syncSynapticModal();
          }
        }

        if (!window.customElements || window.customElements.get("synaptic-monitor-graph")) return;

        class SynapticMonitorGraph extends HTMLElement {
          static get observedAttributes() { return ["data-graph"]; }

          connectedCallback() {
            this.style.display = "block";
            this.style.width = "100%";
            this.style.height = "100%";
            this.renderGraph();
          }

          attributeChangedCallback() {
            this.renderGraph();
          }

          renderGraph() {
            let graph = { nodes: [], edges: [], meta: {} };

            try {
              graph = JSON.parse(this.dataset.graph || "{}");
            } catch (_error) {
              graph = { nodes: [], edges: [], meta: {} };
            }

            const nodes = graph.nodes || [];
            const edges = graph.edges || [];

            this.setAttribute("role", "img");
            this.setAttribute(
              "aria-label",
              graph.meta?.overview || `Topology graph with ${nodes.length} nodes and ${edges.length} links`
            );

            if (nodes.length === 0) {
              this.innerHTML = `
                <div style="display:grid;place-items:center;width:100%;height:100%;color:#8da2c5;font:12px Menlo, Monaco, monospace;">
                  No graph data yet.
                </div>
              `;
              return;
            }

            const width = Math.max(this.clientWidth || 960, 320);
            const height = Math.max(this.clientHeight || 264, 220);
            const model = this.buildModel(nodes, edges, width, height);
            this.innerHTML = this.renderSvg(model, width, height);
          }

          buildModel(nodes, edges, width, height) {
            const typeOrder = ["workflow", "service", "instance", "task_ref", "run"];
            const groups = new Map(typeOrder.map((type) => [type, []]));

            nodes.forEach((node) => {
              const type = node.data.node_type || "run";
              if (!groups.has(type)) groups.set(type, []);
              groups.get(type).push(node.data);
            });

            const activeTypes = [...groups.entries()].filter(([, items]) => items.length > 0);
            const marginX = 36;
            const marginY = 28;
            const usableWidth = Math.max(width - marginX * 2, 200);
            const usableHeight = Math.max(height - marginY * 2, 120);
            const hasRenderableEdges = edges.some((edge) => {
              const sourceType = (edge.data.source || "").split(":")[0];
              const targetType = (edge.data.target || "").split(":")[0];
              return sourceType && targetType;
            });

            const positioned =
              !hasRenderableEdges || activeTypes.length <= 1
                ? this.positionAsGrid(activeTypes, marginX, marginY, usableWidth, usableHeight)
                : this.positionInLanes(activeTypes, marginX, marginY, usableWidth, usableHeight);

            const positions = new Map(positioned.map((item) => [item.id, item]));

            const renderedEdges = edges
              .map((edge) => {
                const source = positions.get(edge.data.source);
                const target = positions.get(edge.data.target);
                if (!source || !target) return null;

                const path = this.edgePath(source, target);

                return {
                  ...edge.data,
                  path,
                  label_x: (source.x + target.x) / 2,
                  label_y: (source.y + target.y) / 2 - 8
                };
              })
              .filter(Boolean);

            return { nodes: positioned, edges: renderedEdges };
          }

          positionAsGrid(activeTypes, marginX, marginY, usableWidth, usableHeight) {
            const flat = activeTypes.flatMap(([, items]) => items);
            const count = flat.length;
            const columns = Math.max(1, Math.min(4, Math.ceil(Math.sqrt(count))));
            const rows = Math.max(1, Math.ceil(count / columns));
            const cellWidth = usableWidth / columns;
            const cellHeight = usableHeight / rows;

            return flat.map((item, index) => {
              const type = item.node_type || "run";
              const size = this.nodeSize(type);
              const column = index % columns;
              const row = Math.floor(index / columns);

              return {
                ...item,
                x: marginX + cellWidth * column + cellWidth / 2,
                y: marginY + cellHeight * row + cellHeight / 2,
                width: size.width,
                height: size.height
              };
            });
          }

          positionInLanes(activeTypes, marginX, marginY, usableWidth, usableHeight) {
            const laneWidth = usableWidth / activeTypes.length;

            return activeTypes.flatMap(([type, items], laneIndex) => {
              const orderedItems = [...items].sort((left, right) => {
                const leftScore = String(left.is_selected) === "true" ? 3 : String(left.is_focus) === "true" ? 2 : left.recency === "hot" ? 1 : 0;
                const rightScore = String(right.is_selected) === "true" ? 3 : String(right.is_focus) === "true" ? 2 : right.recency === "hot" ? 1 : 0;
                return rightScore - leftScore;
              });

              const xStart = marginX + laneWidth * laneIndex;
              const laneCenterX = xStart + laneWidth / 2;
              const size = this.nodeSize(type);
              const maxRows = Math.max(2, Math.min(5, Math.floor(usableHeight / (size.height + 16))));
              const localColumns = Math.max(1, Math.ceil(orderedItems.length / maxRows));
              const actualRows = Math.max(1, Math.ceil(orderedItems.length / localColumns));
              const localCellWidth = laneWidth / localColumns;
              const localCellHeight = usableHeight / actualRows;

              return orderedItems.map((item, index) => {
                const column = Math.floor(index / actualRows);
                const row = index % actualRows;
                const columnOffset = localColumns > 1
                  ? (column - (localColumns - 1) / 2) * Math.min(localCellWidth, size.width + 24)
                  : 0;

                return {
                  ...item,
                  x: laneCenterX + columnOffset,
                  y: marginY + localCellHeight * row + localCellHeight / 2,
                  width: size.width,
                  height: size.height
                };
              });
            });
          }

          renderSvg(model, width, height) {
            const defs = `
              <defs>
                <marker id="arrow-slate" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="#4b5a72"></path>
                </marker>
                <marker id="arrow-cyan" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="#38bdf8"></path>
                </marker>
                <marker id="arrow-blue" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="#60a5fa"></path>
                </marker>
                <marker id="arrow-green" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="#34d399"></path>
                </marker>
                <marker id="arrow-gold" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
                  <path d="M 0 0 L 10 5 L 0 10 z" fill="#fbbf24"></path>
                </marker>
                <filter id="node-glow" x="-40%" y="-40%" width="180%" height="180%">
                  <feGaussianBlur stdDeviation="7" result="blur"></feGaussianBlur>
                  <feMerge>
                    <feMergeNode in="blur"></feMergeNode>
                    <feMergeNode in="SourceGraphic"></feMergeNode>
                  </feMerge>
                </filter>
              </defs>
            `;

            const edgeMarkup = model.edges.map((edge) => this.renderEdge(edge)).join("");
            const nodeMarkup = model.nodes.map((node) => this.renderNode(node)).join("");

            return `
              <svg viewBox="0 0 ${width} ${height}" width="100%" height="100%" xmlns="http://www.w3.org/2000/svg" style="display:block;width:100%;height:100%;font-family:Menlo, Monaco, monospace;">
                ${defs}
                ${edgeMarkup}
                ${nodeMarkup}
              </svg>
            `;
          }

          renderEdge(edge) {
            const color = this.edgeColor(edge);
            const marker = this.edgeMarker(edge);
            const dash = edge.edge_type === "workflow_run" ? ' stroke-dasharray="6 6"' : edge.edge_type === "task_ref_run" ? ' stroke-dasharray="3 5"' : "";
            const opacity = edge.recency === "hot" ? "1" : edge.recency === "warm" ? "0.86" : "0.68";
            const width = edge.edge_type === "caller_callee" ? 3.2 : edge.recency === "hot" ? 3 : 2.2;
            const label = edge.label ? `
              <text x="${edge.label_x}" y="${edge.label_y}" fill="#dbeafe" font-size="8.5" text-anchor="middle">
                ${this.escapeText(this.shorten(edge.label, 18))}
              </text>
            ` : "";

            return `
              <g opacity="${opacity}">
                <path d="${edge.path}" fill="none" stroke="${color}" stroke-width="${width}" marker-end="url(#${marker})"${dash}></path>
                ${label}
              </g>
            `;
          }

          renderNode(node) {
            const style = this.nodeStyle(node);
            const labelLines = String(node.display_label || node.label || node.id)
              .split("\\n")
              .slice(0, 2)
              .map((line) => this.shorten(line, node.node_type === "run" ? 24 : 20));

            const ring = node.recency === "hot"
              ? this.renderGlow(node, style.stroke)
              : "";

            const shape = this.renderShape(node, style);
            const label = labelLines
              .map((line, index) => {
                const dy = index === 0 ? "-0.2em" : "1.15em";
                return `<tspan x="${node.x}" dy="${dy}">${this.escapeText(line)}</tspan>`;
              })
              .join("");

            return `
              <g filter="${node.recency === "hot" ? "url(#node-glow)" : ""}">
                ${ring}
                ${shape}
                <text x="${node.x}" y="${node.y}" fill="#eff6ff" font-size="9.5" font-weight="700" text-anchor="middle" dominant-baseline="middle">
                  ${label}
                </text>
              </g>
            `;
          }

          renderGlow(node, color) {
            if (node.node_type === "instance") {
              return `<ellipse cx="${node.x}" cy="${node.y}" rx="${node.width / 2 + 8}" ry="${node.height / 2 + 8}" fill="none" stroke="${color}" stroke-opacity="0.22" stroke-width="8"></ellipse>`;
            }

            return `<rect x="${node.x - node.width / 2 - 6}" y="${node.y - node.height / 2 - 6}" width="${node.width + 12}" height="${node.height + 12}" rx="20" fill="none" stroke="${color}" stroke-opacity="0.22" stroke-width="8"></rect>`;
          }

          renderShape(node, style) {
            const x = node.x - node.width / 2;
            const y = node.y - node.height / 2;

            if (node.node_type === "instance") {
              return `<ellipse cx="${node.x}" cy="${node.y}" rx="${node.width / 2}" ry="${node.height / 2}" fill="${style.fill}" stroke="${style.stroke}" stroke-width="${style.strokeWidth}"></ellipse>`;
            }

            if (node.node_type === "task_ref") {
              const points = [
                [node.x, y],
                [x + node.width, node.y],
                [node.x, y + node.height],
                [x, node.y]
              ].map(([px, py]) => `${px},${py}`).join(" ");

              return `<polygon points="${points}" fill="${style.fill}" stroke="${style.stroke}" stroke-width="${style.strokeWidth}"></polygon>`;
            }

            if (node.node_type === "run") {
              const inset = 18;
              const points = [
                [x + inset, y],
                [x + node.width - inset, y],
                [x + node.width, node.y],
                [x + node.width - inset, y + node.height],
                [x + inset, y + node.height],
                [x, node.y]
              ].map(([px, py]) => `${px},${py}`).join(" ");

              return `<polygon points="${points}" fill="${style.fill}" stroke="${style.stroke}" stroke-width="${style.strokeWidth}"></polygon>`;
            }

            return `<rect x="${x}" y="${y}" width="${node.width}" height="${node.height}" rx="${node.node_type === "workflow" ? 18 : 14}" fill="${style.fill}" stroke="${style.stroke}" stroke-width="${style.strokeWidth}"></rect>`;
          }

          edgePath(source, target) {
            const sourceX = source.x + source.width / 2;
            const targetX = target.x - target.width / 2;
            const sourceY = source.y;
            const targetY = target.y;
            const delta = Math.max((targetX - sourceX) * 0.45, 24);
            return `M ${sourceX} ${sourceY} C ${sourceX + delta} ${sourceY}, ${targetX - delta} ${targetY}, ${targetX} ${targetY}`;
          }

          nodeStyle(node) {
            const statusStyles = {
              completed: { fill: "#166534", stroke: "#86efac" },
              failed: { fill: "#7f1d1d", stroke: "#fca5a5" },
              stopped: { fill: "#7f1d1d", stroke: "#fca5a5" },
              waiting_for_human: { fill: "#92400e", stroke: "#fcd34d" },
              running: { fill: "#1d4ed8", stroke: "#7dd3fc" },
              registered: { fill: "#1e293b", stroke: "#93c5fd" },
              active: { fill: "#1e293b", stroke: "#93c5fd" },
              deregistered: { fill: "#475569", stroke: "#94a3b8" }
            };

            const base = statusStyles[String(node.status)] || { fill: "#1d4ed8", stroke: "#7dd3fc" };
            let stroke = base.stroke;
            let strokeWidth = node.recency === "warm" ? 3 : 2;

            if (String(node.is_focus) === "true") {
              stroke = "#f8fafc";
              strokeWidth = 4;
            }

            if (String(node.is_selected) === "true") {
              stroke = "#fde68a";
              strokeWidth = 5;
            }

            if (node.recency === "hot" && strokeWidth < 4) strokeWidth = 4;

            return { fill: base.fill, stroke, strokeWidth };
          }

          edgeColor(edge) {
            if (edge.status === "failed" || edge.status === "stopped") return "#f87171";
            if (edge.edge_type === "caller_callee") return "#38bdf8";
            if (edge.edge_type === "service_instance") return "#60a5fa";
            if (edge.edge_type === "instance_run") return "#34d399";
            if (edge.edge_type === "task_ref_run") return "#fbbf24";
            return "#64748b";
          }

          edgeMarker(edge) {
            if (edge.status === "failed" || edge.status === "stopped") return "arrow-slate";
            if (edge.edge_type === "caller_callee") return "arrow-cyan";
            if (edge.edge_type === "service_instance") return "arrow-blue";
            if (edge.edge_type === "instance_run") return "arrow-green";
            if (edge.edge_type === "task_ref_run") return "arrow-gold";
            return "arrow-slate";
          }

          nodeSize(type) {
            if (type === "workflow") return { width: 176, height: 58 };
            if (type === "service") return { width: 162, height: 54 };
            if (type === "instance") return { width: 126, height: 52 };
            if (type === "task_ref") return { width: 118, height: 46 };
            if (type === "run") return { width: 170, height: 58 };
            return { width: 140, height: 52 };
          }

          shorten(value, max) {
            const text = String(value || "");
            return text.length > max ? `${text.slice(0, max - 1)}…` : text;
          }

          escapeText(value) {
            return String(value)
              .replace(/&/g, "&amp;")
              .replace(/</g, "&lt;")
              .replace(/>/g, "&gt;");
          }
        }

        window.customElements.define("synaptic-monitor-graph", SynapticMonitorGraph);
      })();
      """
    end

    def standalone_script do
      """
      #{graph_script()}
      (function () {
        function boot() {
          const root = document.getElementById("synaptic-monitor-root");
          if (!root) return false;

          if (window.__synapticMonitorBooted) return true;
          window.__synapticMonitorBooted = true;

          const graph = document.getElementById("synaptic-monitor-graph");
          const focus = document.getElementById("synaptic-monitor-focus");
          const entities = document.getElementById("synaptic-monitor-entities");
          const timeline = document.getElementById("synaptic-monitor-events");
          const inspector = document.getElementById("synaptic-monitor-inspector");
          const filtersForm = document.getElementById("synaptic-monitor-filters");

          let snapshot = window.__synapticMonitorInitialSnapshot || {};
          let selected = { type: null, id: null };

          function escapeHtml(value) {
          return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
        }

          function hasPayload(value) {
          if (value == null) return false;
          if (typeof value === "string") return value.length > 0;
          if (Array.isArray(value)) return value.length > 0;
          if (typeof value === "object") return Object.keys(value).length > 0;
          return true;
        }

          function formatPayload(value) {
          if (value == null) return "";
          if (typeof value === "string") return value;

          try {
            return JSON.stringify(value, null, 2);
          } catch (_error) {
            return String(value);
          }
        }

          function eventSubject(event) {
          return event.step || event.kind || "event";
        }

          function modalActions(event) {
          const data = event.data || {};
          const actions = [];

          if (hasPayload(data.input)) {
            actions.push({
              label: "Input",
              title: `${eventSubject(event)} input`,
              body: formatPayload(data.input)
            });
          }

          if (hasPayload(data.output)) {
            actions.push({
              label: "Output",
              title: `${eventSubject(event)} output`,
              body: formatPayload(data.output)
            });
          }

          return actions;
        }

          function renderActionButtons(actions, className = "event-actions") {
          if (!actions || actions.length === 0) return "";

          return `
            <div class="event-actions-row">
              <div class="payload-label">Inspect</div>
              <div class="${className}">
                ${actions.map(action => `
                  <button
                    type="button"
                    class="payload-button"
                    data-monitor-modal-title="${escapeHtml(action.title)}"
                    data-monitor-modal-body="${encodeURIComponent(action.body)}"
                  >${escapeHtml(action.label)}</button>
                `).join("")}
              </div>
            </div>
          `;
        }

          function entityGroups(data) {
          return [
            { label: "Runs", type: "run", items: Object.values(data.runs || {}) },
            { label: "Workflows", type: "workflow", items: Object.values(data.workflows || {}) },
            { label: "Instances", type: "instance", items: Object.values(data.instances || {}) },
            { label: "Task refs", type: "task_ref", items: Object.values(data.task_refs || {}) },
            { label: "Services", type: "service", items: Object.values(data.services || {}) }
          ].filter(group => group.items.length > 0);
          }

          function graphContext(data) {
          const nowMs = Date.now();
          const runs = Object.values(data.runs || {});
          const activeRuns = runs.filter(run => ["running", "waiting_for_human"].includes(String(run.status || "")));
          const byWorkflow = Object.create(null);
          const byService = Object.create(null);
          const byInstance = Object.create(null);
          const byTaskRef = Object.create(null);

          activeRuns.forEach(run => {
            if (run.workflow) byWorkflow[run.workflow] = (byWorkflow[run.workflow] || 0) + 1;
            if (run.service_id) byService[run.service_id] = (byService[run.service_id] || 0) + 1;
            if (run.instance_id) byInstance[run.instance_id] = (byInstance[run.instance_id] || 0) + 1;
            if (run.task_ref_id) byTaskRef[run.task_ref_id] = (byTaskRef[run.task_ref_id] || 0) + 1;
          });

          return {
            nowMs,
            activeRuns,
            byWorkflow,
            byService,
            byInstance,
            byTaskRef,
            selectedRef: selected.type && selected.id ? `${selected.type}:${selected.id}` : null,
            focusRunId: focusRun(data, selectedEntity(data))?.run_id || null
          };
        }

          function recency(updatedAtMs, nowMs) {
          const ageMs = Math.max(0, nowMs - Number(updatedAtMs || 0));
          if (ageMs <= 8000) return "hot";
          if (ageMs <= 30000) return "warm";
          return "cold";
        }

          function activeCount(entity, type, context) {
          if (type === "run") return ["running", "waiting_for_human"].includes(String(entity.status || "")) ? 1 : 0;
          if (type === "workflow") return context.byWorkflow[entity.id] || 0;
          if (type === "service") return context.byService[entity.id] || 0;
          if (type === "instance") return context.byInstance[entity.id] || 0;
          if (type === "task_ref") return context.byTaskRef[entity.id] || 0;
          return 0;
        }

          function graphSecondary(item, type, context) {
          if (type === "run") return currentStep(item) || shortId(item.run_id);
          if (type === "workflow" || type === "service") {
            const count = activeCount(item, type, context);
            return count > 0 ? `${count} active` : String(item.status || "idle");
          }
          if (type === "instance") return currentStep(focusRun(snapshot, item)) || shortId(item.instance_id);
          if (type === "task_ref") return shortId(item.task_ref_id || item.id);
          return String(item.status || "");
        }

          function graphPayload(data) {
          const context = graphContext(data);

          const nodes = entityGroups(data).flatMap(group =>
            group.items.map(item => ({
              data: {
                id: `${group.type}:${item.id}`,
                label: item.label || item.id,
                display_label: [entityTitle(item), graphSecondary(item, group.type, context)].filter(Boolean).join("\\n"),
                node_type: group.type,
                status: item.status || "unknown",
                current_step: currentStep(item),
                recency: recency(item.updated_at_ms, context.nowMs),
                is_selected: String(context.selectedRef === `${group.type}:${item.id}`),
                is_focus: String(group.type === "run" && item.run_id === context.focusRunId),
                active_count: activeCount(item, group.type, context)
              }
            }))
          );

          const edges = (data.edges || []).map(edge => ({
            data: {
              id: `${edge.kind}:${edge.from_id}:${edge.to_id}`,
              source: `${edge.from_type}:${edge.from_id}`,
              target: `${edge.to_type}:${edge.to_id}`,
              edge_type: edge.kind,
              status: edge.status || "unknown",
              label: edge.purpose || (edge.kind === "caller_callee" ? "delegates" : ""),
              recency: recency(edge.updated_at_ms, context.nowMs)
            }
          }));

          return {
            nodes,
            edges,
            meta: {
              overview: [
                `${nodes.length} nodes`,
                `${edges.length} links`,
                `${context.activeRuns.length} active`,
                context.activeRuns.filter(run => run.status === "waiting_for_human").length > 0
                  ? `${context.activeRuns.filter(run => run.status === "waiting_for_human").length} waiting`
                  : null
              ].filter(Boolean).join(" • ")
            }
          };
        }

          function shortId(value) {
          const text = String(value || "");
          return text.length > 14 ? `${text.slice(0, 6)}…${text.slice(-4)}` : text;
        }

          function shortWorkflow(value) {
          const text = String(value || "");
          const parts = text.split(".");
          return parts[parts.length - 1] || text;
        }

          function currentStep(run) {
          return run?.step || run?.metadata?.current_step || null;
        }

          function entityTitle(entity) {
          if (!entity) return "Unknown";
          if (entity.type === "run") return shortWorkflow(entity.workflow || entity.label || entity.id);
          if (entity.type === "workflow") return shortWorkflow(entity.workflow || entity.label || entity.id);
          return entity.label || entity.service_id || entity.instance_id || entity.run_id || entity.task_ref_id || entity.id;
        }

          function entityMeta(entity) {
          if (!entity) return "unknown";
          const parts = [entity.status || "unknown"];
          if (entity.type === "run" && currentStep(entity)) parts.push(`step ${currentStep(entity)}`);
          if (entity.type === "run" && entity.run_id) parts.push(shortId(entity.run_id));
          if (entity.type === "instance" && entity.instance_id) parts.push(shortId(entity.instance_id));
          return parts.join(" · ");
        }

          function currentFilters() {
          const formData = new FormData(filtersForm);
          return Object.fromEntries(formData.entries());
        }

          function filteredEvents(events) {
          const filters = currentFilters();

          return (events || []).filter(event => {
            return Object.entries(filters).every(([key, value]) => {
              if (!value) return true;
              return String(event[key] || "") === value;
            });
          });
        }

          function firstEntity(data) {
          const activeRun = Object.values(data.runs || {})
            .filter(run => ["running", "waiting_for_human"].includes(String(run.status || "")))
            .sort((a, b) => (b.updated_at_ms || 0) - (a.updated_at_ms || 0))[0];

          if (activeRun) return activeRun;

          const groups = entityGroups(data);
          return groups[0] && groups[0].items[0];
        }

          function selectedEntity(data) {
          if (!selected.type || !selected.id) return firstEntity(data);
          const collection = data[`${selected.type}s`] || {};
          return collection[selected.id] || firstEntity(data);
        }

          function latestRun(data, predicate) {
          return Object.values(data.runs || {})
            .filter(predicate)
            .sort((a, b) => (b.updated_at_ms || 0) - (a.updated_at_ms || 0))[0] || null;
        }

          function focusRun(data, entity) {
          if (!entity) return latestRun(data, () => true);
          if (entity.type === "run") return entity;
          if (entity.type === "workflow") return latestRun(data, run => run.workflow === entity.id);
          if (entity.type === "service") return latestRun(data, run => run.service_id === entity.id);
          if (entity.type === "instance") return latestRun(data, run => run.instance_id === entity.id);
          if (entity.type === "task_ref") return latestRun(data, run => run.task_ref_id === entity.id);
          return latestRun(data, () => true);
        }

          function focusEvents(data, entity) {
          const run = focusRun(data, entity);
          const events = data.events || [];

          if (run?.run_id) return events.filter(event => event.run_id === run.run_id);
          if (entity?.type === "service") return events.filter(event => event.service_id === entity.id || event.target_service_id === entity.id || event.caller_agent_id === entity.id);
          if (entity?.type === "instance") return events.filter(event => event.instance_id === entity.id);
          if (entity?.type === "task_ref") return events.filter(event => event.task_ref_id === entity.id);
          if (entity?.type === "workflow") return events.filter(event => event.workflow === entity.id);
          return events;
        }

          function stepStatus(event) {
          const eventName = event?.data?.event || event?.status;
          if (eventName === "step_completed") return "completed";
          if (eventName === "waiting_for_human") return "waiting";
          if (eventName === "failed") return "failed";
          if (eventName === "stopped") return "stopped";
          if (eventName === "completed") return "completed";
          if (eventName === "running") return "running";
          return String(event?.status || "running");
        }

          function stepHistory(data, entity) {
          const run = focusRun(data, entity);
          const runEvents = focusEvents(data, entity)
            .filter(event => event.kind === "run" && event.step)
            .sort((a, b) => (a.ts_ms || 0) - (b.ts_ms || 0));

          const entries = [];

          for (const event of runEvents) {
            const step = String(event.step);
            const entry = {
              step,
              status: stepStatus(event),
              summary: event.summary,
              ts_ms: event.ts_ms,
              actions: modalActions(event)
            };

            const idx = entries.findIndex(item => item.step === step);
            if (idx === -1) entries.push(entry);
            else entries[idx] = {...entries[idx], ...entry, actions: entry.actions.length > 0 ? entry.actions : (entries[idx].actions || [])};
          }

          const current = currentStep(run);
          if (current && !entries.some(entry => entry.step === String(current))) {
            entries.push({
              step: String(current),
              status: String(run?.status || "running"),
              summary: run?.summary || "Current step",
              ts_ms: run?.updated_at_ms || Date.now()
            });
          }

          return entries;
        }

          function waitingMessage(events) {
          const waitingEvent = events.find(event => event.status === "waiting_for_human" || event?.data?.event === "waiting_for_human");
          return waitingEvent?.summary || null;
        }

          function humanizeToken(value) {
          const text = String(value || "");
          return text ? text.replaceAll("_", " ") : "";
        }

          function formatAge(tsMs) {
          if (!tsMs) return "n/a";

          const delta = Math.max(0, Date.now() - Number(tsMs));
          if (delta < 1000) return "just now";
          if (delta < 60000) return `${Math.floor(delta / 1000)}s ago`;
          if (delta < 3600000) return `${Math.floor(delta / 60000)}m ago`;
          return `${Math.floor(delta / 3600000)}h ago`;
        }

          function primaryNodeLabel(node) {
          return String(node?.display_label || node?.label || node?.id || "Unknown")
            .split("\\n")[0];
        }

          function outlinePriority(item) {
          if (String(item?.is_selected) === "true") return 30;
          if (String(item?.is_focus) === "true") return 20;
          if (item?.recency === "hot") return 10;
          if (item?.recency === "warm") return 5;
          return 0;
        }

          function outlineEdgePriority(item) {
          if (item?.recency === "hot") return 10;
          if (item?.status === "failed" || item?.status === "stopped") return 5;
          return 0;
        }

          function topologyOutline(data, graphState) {
          const entity = selectedEntity(data);
          const run = focusRun(data, entity);
          const nodeData = (graphState.nodes || []).map(item => item.data || item);
          const edgeData = (graphState.edges || []).map(item => item.data || item);
          const nodeIndex = Object.fromEntries(nodeData.map(node => [node.id, node]));

          const nodes = [...nodeData]
            .sort((left, right) => outlinePriority(right) - outlinePriority(left) || primaryNodeLabel(left).localeCompare(primaryNodeLabel(right)))
            .slice(0, 8)
            .map(node => ({
              label: primaryNodeLabel(node),
              meta: [
                humanizeToken(node.node_type),
                humanizeToken(node.status),
                node.current_step ? `step ${node.current_step}` : null,
                Number(node.active_count || 0) > 0 && node.node_type !== "run" ? `${node.active_count} active` : null
              ].filter(Boolean).join(" · "),
              emphasis: String(node.is_selected) === "true" ? "selected" : String(node.is_focus) === "true" ? "focus" : node.recency === "hot" ? "hot" : ""
            }));

          const edges = [...edgeData]
            .sort((left, right) => outlineEdgePriority(right) - outlineEdgePriority(left) || String(left.id || "").localeCompare(String(right.id || "")))
            .slice(0, 6)
            .map(edge => ({
              label: `${primaryNodeLabel(nodeIndex[edge.source])} -> ${primaryNodeLabel(nodeIndex[edge.target])}`,
              meta: [humanizeToken(edge.edge_type), humanizeToken(edge.status), edge.label || null].filter(Boolean).join(" · "),
              emphasis: edge.recency === "hot" ? "hot" : ""
            }));

          return {
            rows: [
              ["Selected", entity ? entityTitle(entity) : "n/a"],
              ["Selected Type", entity?.type ? humanizeToken(entity.type) : "n/a"],
              ["Focus Run", run?.run_id ? `${entityTitle(run)} (${shortId(run.run_id)})` : "n/a"],
              ["Overview", graphState.meta?.overview || "n/a"]
            ],
            nodes,
            edges
          };
        }

          function renderTopology(data, graphState) {
          const topology = document.getElementById("synaptic-monitor-topology-outline");
          if (!topology) return;

          const outline = topologyOutline(data, graphState);
          const renderSection = (title, items) => {
            if (!items || items.length === 0) return "";

            return `
              <div class="outline-section">
                <div class="detail-key">${escapeHtml(title)}</div>
                <div class="outline-list">
                  ${items.map(item => `
                    <div class="outline-item ${escapeHtml(item.emphasis || "")}">
                      <div class="outline-title">${escapeHtml(item.label)}</div>
                      <div class="outline-meta">${escapeHtml(item.meta || "n/a")}</div>
                    </div>
                  `).join("")}
                </div>
              </div>
            `;
          };

          topology.innerHTML = `
            <div class="detail-card topology-outline-card" aria-label="Topology snapshot">
              <h3>Topology Snapshot</h3>
              <div class="detail-grid outline-summary">
                ${outline.rows.map(([label, value]) => `
                  <div class="detail-row">
                    <div class="detail-key">${escapeHtml(label)}</div>
                    <div>${escapeHtml(value || "n/a")}</div>
                  </div>
                `).join("")}
              </div>
              ${renderSection("Visible Nodes", outline.nodes)}
              ${renderSection("Visible Links", outline.edges)}
            </div>
          `;
        }

          function renderEntities(data) {
          entities.innerHTML = entityGroups(data).map(group => `
            <section class="pane">
              <h3>${group.label}</h3>
              <div class="entity-list">
                ${group.items.map(item => `
                  <button type="button" class="entity-button ${selected.type === group.type && selected.id === item.id ? "active" : ""}" data-type="${group.type}" data-id="${item.id}" title="${escapeHtml(entityTitle(item))}">
                    <div class="entity-name">${entityTitle(item)}</div>
                    <div class="entity-meta">${entityMeta(item)}</div>
                  </button>
                `).join("")}
              </div>
            </section>
          `).join("");

          entities.querySelectorAll("[data-type][data-id]").forEach(button => {
            button.addEventListener("click", () => {
              selected = { type: button.dataset.type, id: button.dataset.id };
              render();
            });
          });
        }

        function renderFocus(data) {
          const entity = selectedEntity(data);
          const run = focusRun(data, entity);
          const events = focusEvents(data, entity);
          const summaryCards = [
            ["Focus", entityTitle(run || entity)],
            ["Workflow", run?.workflow ? shortWorkflow(run.workflow) : "n/a"],
            ["Run", run?.run_id ? shortId(run.run_id) : "n/a"],
            ["Updated", events[0]?.ts_ms ? new Date(events[0].ts_ms).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"}) : "n/a"],
            ["Entity Type", entity?.type ? humanizeToken(entity.type) : "n/a"],
            ["Events", String(events.length)],
            ["Last Seen", events[0]?.ts_ms ? formatAge(events[0].ts_ms) : "n/a"]
          ];

          focus.innerHTML = `
            <div class="hero-panel">
              <div class="hero-top">
                <div>
                  <div class="hero-eyebrow">Selected Run</div>
                  <div class="hero-title">${currentStep(run) || entityTitle(run || entity)}</div>
                  <div class="hero-subtitle">${waitingMessage(events) || events[0]?.summary || "No active notes for this run."}</div>
                </div>
                <div class="status-pill ${String((run || entity)?.status || "unknown")}">${String((run || entity)?.status || "unknown")}</div>
              </div>
              <div class="summary-grid">
                ${summaryCards.map(([title, value]) => `
                  <div class="summary-card">
                    <div class="summary-title">${title}</div>
                    <div class="summary-value">${value}</div>
                  </div>
                `).join("")}
              </div>
            </div>
          `;
        }

        function renderTimeline(data) {
          const baseEvents = Object.values(currentFilters()).some(Boolean)
            ? filteredEvents(data.events || [])
            : focusEvents(data, selectedEntity(data));

          const events = [...baseEvents].sort((a, b) => (b.ts_ms || 0) - (a.ts_ms || 0));
          timeline.innerHTML = events.length === 0 ? '<div class="empty">No recent events.</div>' : events.map(event => `
            <div class="event-card">
              <div class="event-time">${event.ts_ms ? new Date(event.ts_ms).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"}) : "n/a"}</div>
              <div class="event-summary">${event.summary || event.kind}</div>
              <div class="event-meta">${[event.kind, event.status, event.step || "no-step", event.run_id ? shortId(event.run_id) : "no-run"].join(" · ")}</div>
              ${renderActionButtons(modalActions(event)) || '<div class="event-actions-row"><div class="payload-label">Inspect</div><div class="payload-empty">No captured payloads</div></div>'}
            </div>
          `).join("");
        }

        function renderInspector(data) {
          const entity = selectedEntity(data);
          const run = focusRun(data, entity);
          const events = focusEvents(data, entity);
          const steps = stepHistory(data, entity);

          if (!entity) {
            inspector.innerHTML = '<div class="empty">No entities yet.</div>';
            return;
          }

          inspector.innerHTML = `
            <div class="detail-card">
              <h3>Step History</h3>
              ${steps.length === 0 ? '<div class="empty">No step data yet.</div>' : `
                <div class="step-list">
                  ${steps.map(step => `
                    <div class="step-card">
                      <div class="step-header">
                        <div class="step-name">${step.step}</div>
                        <div class="step-status ${step.status}">${step.status}</div>
                      </div>
                      <div class="step-meta">${step.summary || ""}</div>
                      ${renderActionButtons(step.actions || [], "step-actions") || '<div class="event-actions-row"><div class="payload-label">Inspect</div><div class="payload-empty">No captured payloads</div></div>'}
                    </div>
                  `).join("")}
                </div>
              `}
            </div>
            <div class="detail-card">
              <h3>Notes</h3>
              <div class="detail-grid">
                <div class="detail-row">
                  <div class="detail-key">waiting</div>
                  <div>${waitingMessage(events) || "n/a"}</div>
                </div>
                <div class="detail-row">
                  <div class="detail-key">last_event</div>
                  <div>${events[0]?.summary || "n/a"}</div>
                </div>
              </div>
            </div>
            <details class="collapsible-panel">
              <summary>Raw Entity</summary>
              <div class="collapsible-body">
                <div class="detail-grid">
                  ${Object.entries(entity).map(([key, value]) => `
                    <div class="detail-row">
                      <div class="detail-key">${key}</div>
                      <div>${typeof value === "object" ? JSON.stringify(value) : String(value)}</div>
                    </div>
                  `).join("")}
                </div>
              </div>
            </details>
          `;
        }

        function render() {
          const graphState = graphPayload(snapshot);
          renderFocus(snapshot);
          renderEntities(snapshot);
          renderTimeline(snapshot);
          renderInspector(snapshot);
          renderTopology(snapshot, graphState);
          graph.dataset.graph = JSON.stringify(graphState);
          const graphOverview = document.getElementById("synaptic-monitor-graph-overview");
          if (graphOverview) graphOverview.textContent = graphState.meta?.overview || "";
          }

          async function refresh() {
            const response = await fetch(root.dataset.snapshotUrl, { headers: { accept: "application/json" } });
            snapshot = await response.json();
            render();
          }

          filtersForm.addEventListener("input", () => renderTimeline(snapshot));
          render();
          refresh();
          setInterval(refresh, 1500);
          return true;
        }

        if (!boot()) {
          document.addEventListener("DOMContentLoaded", boot, { once: true });
        }
      })();
      """
    end

    def entity_title(entity) when is_map(entity) do
      case entity[:type] do
        :run ->
          short_workflow(entity[:workflow]) || "Run"

        :workflow ->
          short_workflow(entity[:workflow] || entity[:label] || entity[:id])

        _ ->
          entity[:label] || entity[:service_id] || entity[:instance_id] || entity[:run_id] ||
            entity[:task_ref_id] || entity[:workflow] || entity[:id]
      end
    end

    def entity_meta(entity) when is_map(entity) do
      [entity[:status] || "unknown", entity_step(entity), compact_entity_id(entity)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
    end

    def modal_markup do
      """
      <div id="synaptic-monitor-modal" class="monitor-modal" hidden>
        <div class="monitor-modal-backdrop" data-monitor-modal-close></div>
        <div class="monitor-modal-card" role="dialog" aria-modal="true" aria-labelledby="synaptic-monitor-modal-title">
          <div class="monitor-modal-header">
            <h3 id="synaptic-monitor-modal-title" class="monitor-modal-title">Payload</h3>
            <button type="button" class="monitor-modal-close" data-monitor-modal-close>Close</button>
          </div>
          <pre id="synaptic-monitor-modal-body" class="monitor-modal-body"></pre>
        </div>
      </div>
      """
    end

    def modal_actions(event) when is_map(event) do
      data = Map.get(event, :data, %{}) || %{}

      [
        modal_action("Input", modal_subject(event, :input), Map.get(data, :input)),
        modal_action("Output", modal_subject(event, :output), Map.get(data, :output)),
        modal_action("Details", modal_subject(event, :details), Map.get(data, :payload))
      ]
      |> Enum.reject(&is_nil/1)
    end

    def topology_outline_markup(snapshot, selected) do
      outline = topology_outline(snapshot, selected)

      """
      <div class="detail-card topology-outline-card" aria-label="Topology snapshot">
        <h3>Topology Snapshot</h3>
        <div class="detail-grid outline-summary">
          #{Enum.map_join(outline.rows, "", &outline_row_markup/1)}
        </div>
        #{outline_section_markup("Visible Nodes", outline.nodes)}
        #{outline_section_markup("Visible Links", outline.edges)}
      </div>
      """
    end

    def summary_rows(summary) when is_map(summary) do
      [
        {"Focus", summary.headline || "Unknown"},
        {"Status", summary.status || "unknown"},
        {"Current Step", summary.current_step || "n/a"},
        {"Workflow", short_workflow(summary.workflow) || "n/a"},
        {"Active Service", summary.service_id || "n/a"},
        {"Run", (summary.run_id && short_id(summary.run_id)) || "n/a"},
        {"Updated", format_timestamp(summary.updated_at_ms)},
        {"Last Event", display_value(summary.last_event && summary.last_event.summary) || "n/a"}
      ]
    end

    def note_rows(summary) when is_map(summary) do
      [
        {"Selected Type",
         (summary.selected_type && humanize_token(summary.selected_type)) || "n/a"},
        {"Events", summary.event_count || 0},
        {"Waiting", waiting_note(summary)},
        {"Last Seen", format_age(summary.updated_at_ms)},
        {"Last Error", display_value(summary.last_error) || "n/a"}
      ]
    end

    def event_meta(event) when is_map(event) do
      [
        format_timestamp(event[:ts_ms]),
        event[:kind],
        event[:status],
        event[:step],
        short_id(event[:run_id])
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(&to_string/1)
      |> Enum.join(" · ")
    end

    def format_timestamp(nil), do: "n/a"

    def format_timestamp(ts_ms) when is_integer(ts_ms) do
      ts_ms
      |> DateTime.from_unix!(:millisecond)
      |> Calendar.strftime("%H:%M:%S")
    rescue
      _ -> "n/a"
    end

    def format_age(nil), do: "n/a"

    def format_age(ts_ms) when is_integer(ts_ms) do
      age_ms = max(System.system_time(:millisecond) - ts_ms, 0)

      cond do
        age_ms < 1_000 -> "just now"
        age_ms < 60_000 -> "#{div(age_ms, 1_000)}s ago"
        age_ms < 3_600_000 -> "#{div(age_ms, 60_000)}m ago"
        true -> "#{div(age_ms, 3_600_000)}h ago"
      end
    end

    def entity_rows(entity) when is_map(entity) do
      entity
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == %{} end)
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    end

    defp entities(map) do
      map
      |> Map.values()
      |> Enum.sort_by(fn entity -> {Map.get(entity, :updated_at_ms, 0), entity.id} end, :desc)
    end

    defp default_entity(snapshot) do
      latest_active_run(snapshot) || first_entity(snapshot)
    end

    defp latest_active_run(snapshot) do
      latest_run(snapshot, &(Map.get(&1, :status) in [:running, :waiting_for_human]))
    end

    defp latest_run(snapshot, matcher) do
      snapshot.runs
      |> Map.values()
      |> Enum.filter(matcher)
      |> Enum.sort_by(&{Map.get(&1, :updated_at_ms, 0), &1.id}, :desc)
      |> List.first()
    end

    defp step_events(nil, _events), do: []

    defp step_events(run, events) do
      Enum.filter(events, fn event ->
        Map.get(event, :kind) == :run and Map.get(event, :run_id) == Map.get(run, :run_id) and
          not is_nil(Map.get(event, :step))
      end)
    end

    defp step_status(event) do
      case get_in(event, [:data, :event]) || event.status do
        :step_completed -> :completed
        :waiting_for_human -> :waiting
        :failed -> :failed
        :stopped -> :stopped
        :completed -> :completed
        :running -> :running
        other -> other || :running
      end
    end

    defp upsert_step_entry(entries, entry) do
      case Enum.find_index(entries, &(&1.step == entry.step)) do
        nil -> entries ++ [entry]
        index -> List.update_at(entries, index, &Map.merge(&1, entry))
      end
    end

    defp maybe_append_current_step(entries, nil, _run), do: entries

    defp maybe_append_current_step(entries, current_step, run) do
      current_step = to_string(current_step)

      if Enum.any?(entries, &(&1.step == current_step)) do
        entries
      else
        entries ++
          [
            %{
              step: current_step,
              status: (run && run.status) || :running,
              summary: (run && run.summary) || "Current step",
              ts_ms: run && run.updated_at_ms
            }
          ]
      end
    end

    defp current_step(nil), do: nil
    defp current_step(run), do: run[:step] || get_in(run, [:metadata, :current_step])

    defp waiting_message(events) do
      events
      |> Enum.find(fn event ->
        event.status == :waiting_for_human or get_in(event, [:data, :event]) == :waiting_for_human
      end)
      |> case do
        nil -> nil
        event -> event.summary
      end
    end

    defp focus_headline(nil, run), do: (run && entity_title(run)) || "No focus"

    defp focus_headline(selected, run) do
      cond do
        run -> entity_title(run)
        selected -> entity_title(selected)
        true -> "No focus"
      end
    end

    defp blank_filters?(filters) do
      Enum.all?(filters, fn {_key, value} -> value in [nil, ""] end)
    end

    defp normalize_filters(filters) do
      filters
      |> Map.new()
      |> Enum.into(%{}, fn {key, value} -> {normalize_key(key), value} end)
    end

    defp normalize_key(key) when is_atom(key), do: key
    defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)

    defp entity_label(entity), do: entity_title(entity)

    defp first_entity(snapshot) do
      snapshot
      |> entity_groups()
      |> Enum.find_value(fn %{items: items} -> List.first(items) end)
    end

    defp edge_id(edge), do: "#{edge.kind}:#{edge.from_id}:#{edge.to_id}"

    defp graph_context(snapshot, selected, now_ms) do
      runs = Map.values(snapshot.runs)
      active_runs = Enum.filter(runs, &active_status?(Map.get(&1, :status)))
      focus_run = focus_run(snapshot, selected)

      %{
        snapshot: snapshot,
        now_ms: now_ms,
        selected_ref: selected && "#{selected.type}:#{selected.id}",
        focus_run_id: focus_run && Map.get(focus_run, :run_id),
        active_runs_count: length(active_runs),
        waiting_runs_count:
          Enum.count(active_runs, &(Map.get(&1, :status) == :waiting_for_human)),
        active_by_workflow: Enum.frequencies_by(active_runs, &Map.get(&1, :workflow)),
        active_by_service: Enum.frequencies_by(active_runs, &Map.get(&1, :service_id)),
        active_by_instance: Enum.frequencies_by(active_runs, &Map.get(&1, :instance_id)),
        active_by_task_ref: Enum.frequencies_by(active_runs, &Map.get(&1, :task_ref_id))
      }
    end

    defp graph_node(entity, type, context) do
      node_id = "#{type}:#{entity.id}"

      %{
        data: %{
          id: node_id,
          label: entity_label(entity),
          display_label:
            [entity_title(entity), graph_secondary(entity, type, context)]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("\n"),
          node_type: type,
          status: Map.get(entity, :status, :unknown),
          recency: recency_bucket(Map.get(entity, :updated_at_ms), context.now_ms),
          current_step: current_step(entity),
          active_count: active_count(type, entity.id, entity, context),
          is_selected: to_string(context.selected_ref == node_id),
          is_focus: to_string(type == :run and Map.get(entity, :run_id) == context.focus_run_id)
        }
      }
    end

    defp graph_edge(edge, context) do
      %{
        data: %{
          id: edge_id(edge),
          source: "#{edge.from_type}:#{edge.from_id}",
          target: "#{edge.to_type}:#{edge.to_id}",
          edge_type: edge.kind,
          status: edge.status,
          label: graph_edge_label(edge),
          recency: recency_bucket(Map.get(edge, :updated_at_ms), context.now_ms)
        }
      }
    end

    defp graph_secondary(entity, :run, _context) do
      current_step(entity) || short_id(entity[:run_id])
    end

    defp graph_secondary(entity, :workflow, context) do
      graph_active_label(Map.get(context.active_by_workflow, entity.id, 0), entity[:status])
    end

    defp graph_secondary(entity, :service, context) do
      graph_active_label(Map.get(context.active_by_service, entity.id, 0), entity[:status])
    end

    defp graph_secondary(entity, :instance, context) do
      latest_run(context.snapshot, &(Map.get(&1, :instance_id) == entity.id))
      |> current_step()
      |> case do
        nil -> short_id(entity[:instance_id])
        step -> to_string(step)
      end
    end

    defp graph_secondary(entity, :task_ref, context) do
      count = Map.get(context.active_by_task_ref, entity.id, 0)

      if count > 0 do
        "#{count} active"
      else
        short_id(entity[:task_ref_id])
      end
    end

    defp graph_secondary(entity, _type, _context), do: to_string(entity[:status] || "")

    defp graph_edge_label(%{kind: :caller_callee, purpose: purpose}) when is_binary(purpose),
      do: purpose

    defp graph_edge_label(%{kind: :caller_callee}), do: "delegates"
    defp graph_edge_label(_edge), do: ""

    defp graph_active_label(count, _status) when count > 0, do: "#{count} active"
    defp graph_active_label(_count, status) when is_atom(status), do: Atom.to_string(status)
    defp graph_active_label(_count, status) when is_binary(status), do: status
    defp graph_active_label(_count, _status), do: "idle"

    defp active_count(:run, _id, entity, _context),
      do: if(active_status?(entity[:status]), do: 1, else: 0)

    defp active_count(:workflow, id, _entity, context),
      do: Map.get(context.active_by_workflow, id, 0)

    defp active_count(:service, id, _entity, context),
      do: Map.get(context.active_by_service, id, 0)

    defp active_count(:instance, id, _entity, context),
      do: Map.get(context.active_by_instance, id, 0)

    defp active_count(:task_ref, id, _entity, context),
      do: Map.get(context.active_by_task_ref, id, 0)

    defp active_count(_type, _id, _entity, _context), do: 0

    defp recency_bucket(nil, _now_ms), do: "cold"

    defp recency_bucket(updated_at_ms, now_ms) when is_integer(updated_at_ms) do
      age_ms = max(now_ms - updated_at_ms, 0)

      cond do
        age_ms <= 8_000 -> "hot"
        age_ms <= 30_000 -> "warm"
        true -> "cold"
      end
    end

    defp recency_bucket(_updated_at_ms, _now_ms), do: "cold"

    defp active_status?(status), do: status in [:running, :waiting_for_human]

    defp topology_outline(snapshot, selected) do
      graph_state = graph(snapshot, selected)
      focus = focus_run(snapshot, selected)
      node_index = Map.new(graph_state.nodes, fn %{data: data} -> {data.id, data} end)

      %{
        rows: [
          {"Selected", (selected && entity_title(selected)) || "n/a"},
          {"Selected Type", (selected && humanize_token(selected.type)) || "n/a"},
          {"Focus Run", (focus && "#{entity_title(focus)} (#{short_id(focus.run_id)})") || "n/a"},
          {"Overview", get_in(graph_state, [:meta, :overview]) || "n/a"}
        ],
        nodes:
          graph_state.nodes
          |> Enum.map(&outline_node(&1.data))
          |> Enum.sort_by(&{-outline_priority(&1), &1.label})
          |> Enum.take(8),
        edges:
          graph_state.edges
          |> Enum.map(&outline_edge(&1.data, node_index))
          |> Enum.sort_by(&{-outline_edge_priority(&1), &1.label})
          |> Enum.take(6)
      }
    end

    defp outline_row_markup({label, value}) do
      """
      <div class="detail-row">
        <div class="detail-key">#{escape_html(label)}</div>
        <div>#{escape_html(value || "n/a")}</div>
      </div>
      """
    end

    defp outline_section_markup(_title, []), do: ""

    defp outline_section_markup(title, items) do
      """
      <div class="outline-section">
        <div class="detail-key">#{escape_html(title)}</div>
        <div class="outline-list">
          #{Enum.map_join(items, "", &outline_item_markup/1)}
        </div>
      </div>
      """
    end

    defp outline_item_markup(item) do
      """
      <div class="outline-item #{outline_emphasis_class(item.emphasis)}">
        <div class="outline-title">#{escape_html(item.label)}</div>
        <div class="outline-meta">#{escape_html(item.meta || "n/a")}</div>
      </div>
      """
    end

    defp outline_node(data) do
      %{
        label: graph_primary_label(data),
        meta:
          [
            humanize_token(data.node_type),
            humanize_token(data.status),
            data.current_step && "step #{data.current_step}",
            data.node_type != "run" && data.active_count > 0 && "#{data.active_count} active"
          ]
          |> Enum.reject(&(&1 in [nil, false, ""]))
          |> Enum.join(" · "),
        emphasis: outline_emphasis(data)
      }
    end

    defp outline_edge(data, node_index) do
      %{
        label:
          "#{graph_primary_label(Map.get(node_index, data.source))} -> " <>
            graph_primary_label(Map.get(node_index, data.target)),
        meta:
          [humanize_token(data.edge_type), humanize_token(data.status), data.label]
          |> Enum.reject(&(&1 in [nil, false, ""]))
          |> Enum.join(" · "),
        emphasis: if(data.recency == "hot", do: :hot, else: nil)
      }
    end

    defp outline_priority(%{emphasis: :selected}), do: 30
    defp outline_priority(%{emphasis: :focus}), do: 20
    defp outline_priority(%{emphasis: :hot}), do: 10
    defp outline_priority(_item), do: 0

    defp outline_edge_priority(%{emphasis: :hot}), do: 10
    defp outline_edge_priority(_item), do: 0

    defp outline_emphasis(%{is_selected: "true"}), do: :selected
    defp outline_emphasis(%{is_focus: "true"}), do: :focus
    defp outline_emphasis(%{recency: "hot"}), do: :hot
    defp outline_emphasis(_data), do: nil

    defp outline_emphasis_class(:selected), do: "selected"
    defp outline_emphasis_class(:focus), do: "focus"
    defp outline_emphasis_class(:hot), do: "hot"
    defp outline_emphasis_class(_emphasis), do: ""

    defp maybe_put_step_actions(entry, event) do
      case modal_actions(event) do
        [] -> entry
        actions -> Map.put(entry, :actions, actions)
      end
    end

    defp modal_action(_label, _title, value) when value in [nil, %{}, [], ""], do: nil

    defp modal_action(label, title, value) do
      %{
        label: label,
        title: title,
        body: payload_dump(value)
      }
    end

    defp modal_subject(event, kind) do
      subject =
        Map.get(event, :step) ||
          Map.get(event, :kind) ||
          "event"

      "#{subject} #{kind}"
    end

    defp payload_dump(%Date{} = value), do: Date.to_iso8601(value)
    defp payload_dump(%DateTime{} = value), do: DateTime.to_iso8601(value)
    defp payload_dump(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
    defp payload_dump(%Time{} = value), do: Time.to_iso8601(value)
    defp payload_dump(value) when is_binary(value), do: value

    defp payload_dump(value) when is_map(value) do
      if Kernel.is_exception(value) do
        Exception.message(value)
      else
        inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
      end
    end

    defp payload_dump(value) do
      inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)
    end

    defp entity_step(%{type: :run} = entity) do
      case current_step(entity) do
        nil -> nil
        step -> "step #{step}"
      end
    end

    defp entity_step(_entity), do: nil

    defp compact_entity_id(%{type: :run, run_id: run_id}) when is_binary(run_id),
      do: short_id(run_id)

    defp compact_entity_id(%{type: :instance, instance_id: id}) when is_binary(id),
      do: short_id(id)

    defp compact_entity_id(%{type: :task_ref, task_ref_id: id}) when is_binary(id),
      do: short_id(id)

    defp compact_entity_id(_entity), do: nil

    defp short_workflow(nil), do: nil

    defp short_workflow(workflow) do
      workflow
      |> to_string()
      |> String.split(".")
      |> List.last()
    end

    defp short_id(nil), do: nil

    defp short_id(value) do
      value = to_string(value)

      if String.length(value) > 14 do
        String.slice(value, 0, 6) <> "…" <> String.slice(value, -4, 4)
      else
        value
      end
    end

    defp display_value(nil), do: nil
    defp display_value(%Date{} = value), do: value
    defp display_value(%DateTime{} = value), do: value
    defp display_value(%NaiveDateTime{} = value), do: value
    defp display_value(%Time{} = value), do: value

    defp display_value(value) when is_map(value) do
      if Kernel.is_exception(value) do
        Exception.message(value)
      else
        inspect(value, pretty: true)
      end
    end

    defp display_value(value) when is_tuple(value), do: inspect(value, pretty: true)
    defp display_value(value), do: value

    defp waiting_note(%{waiting_message: nil}), do: "n/a"
    defp waiting_note(%{waiting_message: message, waiting_at_ms: nil}), do: message

    defp waiting_note(%{waiting_message: message, waiting_at_ms: ts_ms}) do
      "#{message} (since #{format_timestamp(ts_ms)}, #{format_age(ts_ms)})"
    end

    defp humanize_token(nil), do: nil

    defp humanize_token(value) do
      value
      |> to_string()
      |> String.replace("_", " ")
    end

    defp graph_primary_label(nil), do: "Unknown"

    defp graph_primary_label(data) do
      data
      |> Map.get(:display_label, Map.get(data, :label, Map.get(data, :id, "Unknown")))
      |> to_string()
      |> String.split("\n")
      |> List.first()
    end

    defp escape_html(value) do
      value
      |> to_string()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
    end
  end
end
