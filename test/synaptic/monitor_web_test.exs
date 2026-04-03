defmodule Synaptic.MonitorWebTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  require Phoenix.LiveViewTest

  alias Synaptic.Monitor

  defmodule Router do
    use Phoenix.Router
    import Phoenix.LiveView.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
    end

    scope "/" do
      pipe_through(:browser)
      live("/monitor", Synaptic.Monitor.Web.Live)
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :synaptic

    @session_options [
      store: :cookie,
      key: "_synaptic_monitor_key",
      signing_salt: "monitor-signing-salt"
    ]

    socket("/live", Phoenix.LiveView.Socket,
      websocket: [connect_info: [session: @session_options]],
      longpoll: false
    )

    plug(Plug.Session, @session_options)
    plug(Synaptic.MonitorWebTest.Router)
  end

  @endpoint Endpoint

  setup_all do
    Application.put_env(:synaptic, Endpoint,
      url: [host: "localhost"],
      secret_key_base: String.duplicate("monitor_test_secret_", 4),
      live_view: [signing_salt: "monitor-signing-salt"],
      pubsub_server: Synaptic.PubSub,
      debug_errors: true,
      server: false
    )

    :ok
  end

  setup do
    original_monitor = Application.get_env(:synaptic, Synaptic.Monitor)

    Application.put_env(:synaptic, Synaptic.Monitor,
      enabled: true,
      history_limit: 10,
      retention_ms: 300_000,
      cleanup_interval_ms: 20
    )

    start_supervised!(Synaptic.Monitor.Store)
    start_supervised!(Synaptic.Monitor.Bus)
    start_supervised!(Synaptic.Monitor.Collector)
    start_supervised!(Endpoint)

    Monitor.capture(%{
      kind: :service,
      status: :registered,
      service_id: "svc.alpha",
      summary: "Service alpha",
      data: %{provider: {:workflow_module, __MODULE__}}
    })

    Monitor.capture(%{
      kind: :service,
      status: :registered,
      service_id: "svc.beta",
      summary: "Service beta"
    })

    Monitor.capture(%{
      kind: :run,
      status: :running,
      run_id: "run_123",
      workflow: "DemoWorkflow",
      service_id: "svc.alpha",
      step: :prepare,
      summary: "Run active",
      data: %{event: :step_completed}
    })

    Monitor.capture(%{
      kind: :run,
      status: :waiting_for_human,
      run_id: "run_123",
      workflow: "DemoWorkflow",
      service_id: "svc.alpha",
      step: :review,
      summary: "Waiting for human input",
      data: %{event: :waiting_for_human}
    })

    Monitor.capture(%{
      kind: :mcp_call,
      status: :completed,
      run_id: "run_123",
      workflow: "DemoWorkflow",
      service_id: "svc.alpha",
      step: :review,
      summary: "MCP tool get_session",
      data: %{
        input: %{query: "tesla", region: "eu"},
        output: %{session_id: "sess_123", status: "ok"}
      }
    })

    Monitor.capture(%{
      kind: :instance,
      status: :running,
      service_id: "svc.alpha",
      instance_id: "inst_alpha",
      run_id: "run_123",
      summary: "Instance alpha",
      data: %{endpoint_type: :pid, endpoint_ref: self()}
    })

    Monitor.capture(%{
      kind: :run,
      status: :failed,
      run_id: "run_456",
      workflow: "DemoWorkflow",
      service_id: "svc.beta",
      step: :route_query,
      summary: "Run failed",
      data: %{last_error: RuntimeError.exception("Synaptic OpenAI adapter requires an API key")}
    })

    on_exit(fn ->
      if original_monitor do
        Application.put_env(:synaptic, Synaptic.Monitor, original_monitor)
      else
        Application.delete_env(:synaptic, Synaptic.Monitor)
      end
    end)

    :ok
  end

  test "embedded LiveView renders topology and updates inspector selection" do
    conn = build_conn() |> put_private(:phoenix_endpoint, Endpoint)

    {:ok, view, html} =
      Phoenix.LiveViewTest.live_isolated(conn, Synaptic.Monitor.Web.Live, session: %{})

    assert html =~ "Synaptic Monitor"
    assert html =~ "DemoWorkflow"
    assert html =~ "Current Step"
    assert html =~ "review"
    assert html =~ "Step History"
    assert html =~ "Inspect"
    assert html =~ "Input"
    assert html =~ "Output"
    assert html =~ "Topology Snapshot"
    assert html =~ "Visible Nodes"
    assert html =~ "Visible Links"
    assert html =~ "Selected Type"

    view
    |> Phoenix.LiveViewTest.element("button[phx-value-type='service'][phx-value-id='svc.beta']")
    |> Phoenix.LiveViewTest.render_click()

    assert Phoenix.LiveViewTest.render(view) =~ "svc.beta"
  end

  test "standalone endpoint renders HTML and exposes snapshot json" do
    port = free_port()
    start_supervised!({Synaptic.Monitor.Web, port: port})

    assert_eventually(fn ->
      case Finch.build(:get, "http://127.0.0.1:#{port}/") |> Finch.request(Synaptic.Finch) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          String.contains?(body, "Synaptic Monitor") and
            String.contains?(body, "Topology Snapshot")

        _ ->
          false
      end
    end)

    {:ok, %Finch.Response{status: 200, body: body}} =
      Finch.build(:get, "http://127.0.0.1:#{port}/api/snapshot") |> Finch.request(Synaptic.Finch)

    payload = Jason.decode!(body)

    assert get_in(payload, ["services", "svc.alpha", "service_id"]) == "svc.alpha"
    assert get_in(payload, ["runs", "run_123", "run_id"]) == "run_123"

    assert get_in(payload, ["runs", "run_456", "last_error", "message"]) ==
             "Synaptic OpenAI adapter requires an API key"

    assert get_in(payload, ["instances", "inst_alpha", "metadata", "endpoint_ref"]) =~ "#PID<"

    mcp_event =
      Enum.find(payload["events"], fn event ->
        event["kind"] == "mcp_call" and get_in(event, ["data", "input", "query"]) == "tesla"
      end)

    assert mcp_event
    assert get_in(mcp_event, ["data", "output", "session_id"]) == "sess_123"
    assert Enum.all?(payload["edges"], &is_binary(&1["id"]))

    {:ok, %Finch.Response{status: 204}} =
      Finch.build(:get, "http://127.0.0.1:#{port}/favicon.ico") |> Finch.request(Synaptic.Finch)

    {:ok, %Finch.Response{status: 404, body: body}} =
      Finch.build(:get, "http://127.0.0.1:#{port}/missing") |> Finch.request(Synaptic.Finch)

    assert body =~ "Not Found"
  end

  test "collector preserves mcp telemetry payloads" do
    send(Process.whereis(Synaptic.Monitor.Collector), {
      :telemetry,
      [:synaptic, :mcp, :tool_call, :stop],
      %{duration: 12_000_000},
      %{
        run_id: "run_telemetry",
        step_name: :call_tool,
        remote_name: "get_session",
        server_name: "market",
        input: %{query: "bmw"},
        output: %{session_id: "sess_telemetry"},
        result_status: :completed
      }
    })

    assert_eventually(fn ->
      Monitor.recent_events()
      |> Enum.any?(fn event ->
        event.kind == :mcp_call and
          get_in(event, [:data, :input, :query]) == "bmw" and
          get_in(event, [:data, :output, :session_id]) == "sess_telemetry"
      end)
    end)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition not met")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
