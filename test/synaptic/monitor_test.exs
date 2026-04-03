defmodule Synaptic.MonitorTest do
  use ExUnit.Case, async: false

  alias Synaptic.{Agent, AgentDirectory, AgentRouter, Monitor}

  defmodule DirectMonitorWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{prepared: true}}
    end

    step :review, suspend: true, resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil -> suspend_for_human("Approve direct monitor workflow")
        true -> {:ok, %{approved: true}}
        false -> {:stop, :rejected}
      end
    end

    step :finalize do
      {:ok, %{result: :done}}
    end

    commit()
  end

  setup do
    AgentDirectory.reset!()

    original_monitor = Application.get_env(:synaptic, Synaptic.Monitor)
    Application.put_env(:synaptic, Synaptic.Monitor, enabled: true, history_limit: 5, retention_ms: 75, cleanup_interval_ms: 20)

    start_supervised!(Synaptic.Monitor.Store)
    start_supervised!(Synaptic.Monitor.Bus)
    start_supervised!(Synaptic.Monitor.Collector)

    on_exit(fn ->
      if original_monitor do
        Application.put_env(:synaptic, Synaptic.Monitor, original_monitor)
      else
        Application.delete_env(:synaptic, Synaptic.Monitor)
      end
    end)

    :ok
  end

  test "history ring buffer evicts the oldest events" do
    Enum.each(1..7, fn idx ->
      Monitor.capture(%{kind: :custom, status: :ok, summary: "event-#{idx}"})
    end)

    assert_eventually(fn ->
      events = Monitor.recent_events()
      length(events) == 5 and Enum.all?(events, &(not String.ends_with?(&1.summary, "1") and not String.ends_with?(&1.summary, "2")))
    end)
  end

  test "direct workflow runs create workflow edges and expire after retention" do
    {:ok, run_id} = Synaptic.start(DirectMonitorWorkflow, %{})

    run = wait_for_run_status(run_id, :waiting_for_human)
    snapshot = Monitor.snapshot()

    assert run.workflow == inspect(DirectMonitorWorkflow)
    assert Map.has_key?(snapshot.workflows, inspect(DirectMonitorWorkflow))
    assert Enum.any?(snapshot.edges, &(&1.kind == :workflow_run and &1.to_id == run_id))

    assert :ok = Synaptic.resume(run_id, %{approved: true})
    _completed = wait_for_run_status(run_id, :completed)

    assert_eventually(fn -> Monitor.entity(:run, run_id) == nil end, 120)
    refute Enum.any?(Monitor.snapshot().edges, &(&1.to_id == run_id))
  end

  test "router calls create caller/callee edges and reuse active instances" do
    caller_ctx = %{tenant_id: "default", user_id: "u-monitor", caller_agent_id: "monitor.caller"}

    {:ok, _service} =
      Agent.register_service(
        "monitor.search",
        %{
          kind: :workflow,
          capabilities: ["monitor.search"],
          visibility: :tenant,
          lifecycle_mode: :spawn_on_demand,
          provider: {:workflow_module, DirectMonitorWorkflow}
        }
      )

    {:ok, first} =
      AgentRouter.call(
        "monitor.search",
        %{query: "alpha", purpose: "monitoring", request_id: "req-1"},
        caller_ctx: caller_ctx,
        aliases: ["monitor_last_search"]
      )

    assert first.snapshot.status == :waiting_for_human

    assert_eventually(fn ->
      snapshot = Monitor.snapshot()

      Enum.any?(snapshot.edges, &(&1.kind == :caller_callee and &1.from_id == "monitor.caller" and &1.to_id == "monitor.search")) and
        Enum.any?(snapshot.edges, &(&1.kind == :service_instance and &1.from_id == "monitor.search" and &1.to_id == first.instance.instance_id)) and
        Enum.any?(snapshot.edges, &(&1.kind == :instance_run and &1.from_id == first.instance.instance_id and &1.to_id == first.run_id)) and
        Enum.any?(snapshot.edges, &(&1.kind == :task_ref_run and &1.from_id == first.task_reference.task_ref_id and &1.to_id == first.run_id)) and
        Enum.all?(snapshot.edges, &is_binary(&1.id))
    end)

    {:ok, second} =
      AgentRouter.call(
        "monitor.search",
        %{query: "alpha", purpose: "monitoring", request_id: "req-1"},
        caller_ctx: caller_ctx
      )

    assert second.instance.instance_id == first.instance.instance_id

    assert_eventually(fn ->
      Monitor.recent_events(%{request_id: "req-1"})
      |> Enum.any?(&(&1.kind == :instance_reused))
    end)
  end

  defp wait_for_run_status(run_id, status, attempts \\ 60)
  defp wait_for_run_status(_run_id, _status, 0), do: flunk("monitor run did not reach desired status")

  defp wait_for_run_status(run_id, status, attempts) do
    case Monitor.entity(:run, run_id) do
      %{status: ^status} = run ->
        run

      _other ->
        Process.sleep(20)
        wait_for_run_status(run_id, status, attempts - 1)
    end
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
end
