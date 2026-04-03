defmodule Synaptic.MonitorDisabledTest do
  use ExUnit.Case, async: false

  alias Synaptic.Monitor

  test "monitor APIs are inert when the monitor is not started" do
    Application.put_env(:synaptic, Synaptic.Monitor, enabled: false)

    assert Monitor.child_specs() == []
    assert Monitor.snapshot() == Monitor.empty_snapshot()
    assert Monitor.recent_events() == []
    assert Monitor.entity(:run, "missing") == nil
    assert :ok = Monitor.capture(%{kind: :custom, status: :ok, summary: "disabled"})
  end
end
