defmodule Synaptic.WorkloadManagerTest do
  use ExUnit.Case, async: false

  alias Synaptic.{Agent, AgentDirectory, WorkloadManager}

  defmodule SuspendWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{prepared: true}}
    end

    step :wait, suspend: true, resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil -> suspend_for_human("approve")
        true -> {:ok, %{approved: true}}
        false -> {:stop, :rejected}
      end
    end

    commit()
  end

  setup do
    AgentDirectory.reset!()
    :ok
  end

  test "ensure_instance returns service_unregistered for unknown service" do
    assert {:error, :service_unregistered} =
             WorkloadManager.ensure_instance("missing.service", %{tenant_id: "default"})
  end

  test "ensure_instance can spawn and then reuse workflow-backed instance for same user" do
    {:ok, _} =
      Agent.register_service(
        "search.reuse",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          provider: {:workflow_module, SuspendWorkflow}
        }
      )

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    assert {:ok, first} =
             WorkloadManager.ensure_instance(
               "search.reuse",
               caller_ctx,
               payload: %{},
               aliases: ["last_search"]
             )

    assert {:ok, second} =
             WorkloadManager.ensure_instance(
               "search.reuse",
               caller_ctx,
               payload: %{},
               reuse: true
             )

    assert first.instance.instance_id == second.instance.instance_id
    assert second.task_reference.instance_id == second.instance.instance_id
  end

  test "instance_status returns runtime snapshot and stop_instance stops workflow-backed instance" do
    {:ok, _} =
      Agent.register_service(
        "search.stop",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          provider: {:workflow_module, SuspendWorkflow}
        }
      )

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, started} = WorkloadManager.ensure_instance("search.stop", caller_ctx, payload: %{})
    inst_id = started.instance.instance_id

    assert {:ok, %{instance: inst, runtime: runtime}} =
             WorkloadManager.instance_status(inst_id, caller_ctx: caller_ctx)

    assert inst.instance_id == inst_id
    assert runtime.status in [:waiting_for_human, :running]

    assert :ok = WorkloadManager.stop_instance(inst_id, :user_cancelled, caller_ctx: caller_ctx)

    assert_eventually(fn ->
      case WorkloadManager.instance_status(inst_id, caller_ctx: caller_ctx) do
        {:ok, %{instance: %{status: :stopped}, runtime: nil}} -> true
        {:ok, %{runtime: %{status: :stopped}}} -> true
        _ -> false
      end
    end)
  end

  test "stop_instance returns unsupported_endpoint for pid-backed instances" do
    pid = self()

    {:ok, _} =
      AgentDirectory.register_instance(%{
        instance_id: "inst_pid_1",
        service_id: "echo",
        user_id: "u1",
        status: :ready,
        endpoint_type: :pid,
        endpoint_ref: pid,
        visibility: :tenant
      })

    assert {:error, :unsupported_endpoint} =
             WorkloadManager.stop_instance("inst_pid_1", :normal,
               caller_ctx: %{tenant_id: "default", user_id: "u1"}
             )
  end

  test "unsupported provider returns spawn_failed tuple via ensure_instance" do
    {:ok, _} =
      Agent.register_service(
        "unsupported.provider",
        %{
          kind: :custom,
          capabilities: ["custom"],
          visibility: :tenant,
          provider: :adapter,
          provider_ref: :noop
        }
      )

    assert {:error, :spawn_failed, {:unsupported_provider, {:adapter, :noop}}} =
             WorkloadManager.ensure_instance("unsupported.provider", %{
               tenant_id: "default",
               user_id: "u1"
             })
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition not met")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end
end
