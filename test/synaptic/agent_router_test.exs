defmodule Synaptic.AgentRouterTest do
  use ExUnit.Case, async: false

  alias Synaptic.{Agent, AgentDirectory, AgentRouter}

  defmodule DenyAllPolicy do
    @behaviour Synaptic.AgentPolicy

    @impl true
    def authorize_discovery(_caller_ctx, _record, _action), do: {:deny, :invisible}

    @impl true
    def authorize_invoke(_caller_ctx, _caller_identity, _callee_record, _invocation),
      do: {:deny, :unauthorized}

    @impl true
    def filter_visible_records(_caller_ctx, _records), do: []

    @impl true
    def scope_defaults(_caller_ctx), do: %{tenant_id: "default"}
  end

  defmodule DiscoveryAllowInvokeDenyPolicy do
    @behaviour Synaptic.AgentPolicy

    @impl true
    def authorize_discovery(_caller_ctx, _record, _action), do: :allow

    @impl true
    def authorize_invoke(_caller_ctx, _caller_identity, _callee_record, _invocation),
      do: {:deny, :unauthorized}

    @impl true
    def filter_visible_records(_caller_ctx, records), do: records

    @impl true
    def scope_defaults(_caller_ctx), do: %{tenant_id: "default"}
  end

  defmodule EchoAgent do
    use GenServer

    def start_link(_opts \\ []) do
      GenServer.start_link(__MODULE__, %{})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:echo, payload}, _from, state), do: {:reply, {:ok, payload}, state}

    @impl true
    def handle_cast({:remember, payload}, _state), do: {:noreply, %{last: payload}}
  end

  defmodule SearchWorkflow do
    use Synaptic.Workflow

    step :prepare do
      {:ok, %{query: context.query, prepared: true}}
    end

    step :confirm, suspend: true, resume_schema: %{approved: :boolean} do
      case get_in(context, [:human_input, :approved]) do
        nil -> suspend_for_human("Approve search")
        true -> {:ok, %{approved: true}}
        false -> {:stop, :rejected}
      end
    end

    step :finalize do
      {:ok, %{result: "ok:" <> to_string(context.query)}}
    end

    commit()
  end

  defmodule SlowWorkflow do
    use Synaptic.Workflow

    step :slow do
      Process.sleep(400)
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule BusyWorkflow do
    use Synaptic.Workflow

    step :busy do
      # Simulates a long-running workflow step that blocks snapshot calls long enough
      # to exceed the default GenServer.call timeout used by Synaptic.inspect/2.
      Process.sleep(5_200)
      {:ok, %{done: true}}
    end

    commit()
  end

  setup do
    AgentDirectory.reset!()

    original_policy = Application.get_env(:synaptic, :agent_policy_module)

    on_exit(fn ->
      if original_policy do
        Application.put_env(:synaptic, :agent_policy_module, original_policy)
      else
        Application.delete_env(:synaptic, :agent_policy_module)
      end
    end)

    :ok
  end

  test "registers workflow service, invokes via router, tracks task ref, and resumes" do
    caller_ctx = %{tenant_id: "default", user_id: "u1", caller_agent_id: "voice.command"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          lifecycle_mode: :spawn_on_demand,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    assert {:ok, response} =
             AgentRouter.call(
               "internet.search",
               %{query: "elixir books", purpose: "book_search"},
               caller_ctx: caller_ctx,
               aliases: ["last_search"]
             )

    assert response.snapshot.status == :waiting_for_human
    assert response.instance.service_id == "internet.search"
    assert is_binary(response.handle.instance_id)
    assert is_binary(response.handle.task_ref_id)

    assert {:ok, task_ref} =
             AgentDirectory.resolve_task_reference(%{
               user_id: "u1",
               capability: "internet.search",
               alias: "last_search",
               require_active: true
             })

    assert task_ref.instance_id == response.instance.instance_id

    assert {:ok, resume_response} =
             AgentRouter.call(
               response.handle,
               %{action: :resume, payload: %{approved: true}},
               caller_ctx: caller_ctx,
               timeout: 5_000
             )

    assert resume_response.snapshot.status == :completed
    assert resume_response.snapshot.context.result == "ok:elixir books"

    # Allow PubSub-driven status tracker to update the task reference after completion.
    assert_eventually(fn ->
      case AgentDirectory.lookup_task_reference(response.handle.task_ref_id) do
        {:ok, updated_task_ref} -> updated_task_ref.status == :completed
        _ -> false
      end
    end)
  end

  test "supports routing by instance id and by task reference query map" do
    caller_ctx = %{tenant_id: "default", user_id: "u1", caller_agent_id: "voice.command"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          lifecycle_mode: :spawn_on_demand,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    {:ok, first_call} =
      AgentRouter.call(
        "internet.search",
        %{query: "phoenix", purpose: "phoenix_search"},
        caller_ctx: caller_ctx,
        aliases: ["last_search"]
      )

    assert {:ok, by_instance} =
             AgentRouter.call(first_call.instance.instance_id, %{action: :inspect},
               caller_ctx: caller_ctx
             )

    assert by_instance.snapshot.status == :waiting_for_human

    assert {:ok, by_query} =
             AgentRouter.call(
               %{
                 user_id: "u1",
                 capability: "internet.search",
                 alias: "last_search",
                 require_active: true
               },
               %{action: :inspect},
               caller_ctx: caller_ctx
             )

    assert by_query.run_id == first_call.run_id
    assert by_query.snapshot.status == :waiting_for_human
  end

  test "returns unsupported_mode for sync call to async-only service" do
    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search.async",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          routing_mode: :async,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    assert {:error, :unsupported_mode} =
             AgentRouter.call("internet.search.async", %{query: "x"}, caller_ctx: caller_ctx)
  end

  test "router async jobs can be started and queried" do
    caller_ctx = %{tenant_id: "default", user_id: "u1", caller_agent_id: "voice.command"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          lifecycle_mode: :spawn_on_demand,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    assert {:ok, job_handle} =
             AgentRouter.start_job(
               "internet.search",
               %{query: "async contract", purpose: "async_search"},
               caller_ctx: caller_ctx
             )

    assert {:ok, status1} = AgentRouter.job_status(job_handle.job_id)
    assert status1.status in [:running, :completed]

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :completed, result: {:ok, _}}},
        AgentRouter.job_status(job_handle.job_id)
      )
    end)
  end

  test "authorization denial hides service and blocks router calls" do
    Application.put_env(:synaptic, :agent_policy_module, DenyAllPolicy)

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    assert [] = AgentDirectory.list_services(%{}, caller_ctx: caller_ctx)

    assert {:error, :invisible} =
             AgentDirectory.lookup_service("internet.search", caller_ctx: caller_ctx)

    assert {:error, :invisible} =
             AgentRouter.call("internet.search", %{query: "denied"}, caller_ctx: caller_ctx)
  end

  test "cancel_job marks running router job as canceled" do
    {:ok, _service} =
      Agent.register_service(
        "slow.workflow",
        %{
          kind: :workflow,
          capabilities: ["slow.workflow"],
          visibility: :tenant,
          provider: {:workflow_module, SlowWorkflow}
        }
      )

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, job_handle} =
      AgentRouter.start_job(
        "slow.workflow",
        %{},
        caller_ctx: caller_ctx
      )

    :ok = AgentRouter.cancel_job(job_handle.job_id)
    assert {:ok, %{status: :canceled}} = AgentRouter.job_status(job_handle.job_id)
  end

  test "workflow service call does not crash when snapshot polling times out while step is busy" do
    caller_ctx = %{tenant_id: "default", user_id: "u1", caller_agent_id: "voice.command"}

    {:ok, _service} =
      Agent.register_service(
        "busy.workflow",
        %{
          kind: :workflow,
          capabilities: ["busy.workflow"],
          visibility: :tenant,
          provider: {:workflow_module, BusyWorkflow}
        }
      )

    assert {:ok, response} =
             AgentRouter.call(
               "busy.workflow",
               %{},
               caller_ctx: caller_ctx,
               timeout: 7_000
             )

    assert response.snapshot.status == :completed
    assert response.snapshot.context.done == true
  end

  test "pid-backed provider supports direct call and cast actions" do
    {:ok, pid} = start_supervised(EchoAgent)

    {:ok, _service} =
      Agent.register_service(
        "echo.pid",
        %{
          kind: :agent,
          capabilities: ["echo"],
          visibility: :tenant,
          provider: {:pid, pid}
        }
      )

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, started} = AgentRouter.call("echo.pid", %{}, caller_ctx: caller_ctx)
    inst_id = started.instance.instance_id

    assert {:ok, %{result: {:ok, %{msg: "hello"}}}} =
             AgentRouter.call(inst_id, %{action: :call, message: {:echo, %{msg: "hello"}}},
               caller_ctx: caller_ctx
             )

    assert {:ok, %{cast: true}} =
             AgentRouter.call(inst_id, %{action: :cast, message: {:remember, 123}},
               caller_ctx: caller_ctx
             )
  end

  test "invalid router target and unsupported actions return contract errors" do
    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    assert {:error, :invalid_target} = AgentRouter.call(123, %{}, caller_ctx: caller_ctx)

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    {:ok, first_call} =
      AgentRouter.call("internet.search", %{query: "contracts"}, caller_ctx: caller_ctx)

    assert {:error, {:unsupported_action, :bogus}} =
             AgentRouter.call(first_call.handle, %{action: :bogus}, caller_ctx: caller_ctx)
  end

  test "task-reference query ambiguity propagates through router call" do
    caller_ctx = %{tenant_id: "default", user_id: "u1"}
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      AgentDirectory.put_task_reference(%{
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :running,
        last_activity_at: ts,
        inserted_at: ts
      })

    {:ok, _} =
      AgentDirectory.put_task_reference(%{
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :running,
        last_activity_at: ts,
        inserted_at: ts
      })

    assert {:error, :ambiguous_task_reference, _candidates} =
             AgentRouter.call(
               %{user_id: "u1", capability: "internet.search", alias: "last_search"},
               %{action: :inspect},
               caller_ctx: caller_ctx
             )
  end

  test "job_status and cancel_job return not_found for unknown job id" do
    assert {:error, :not_found} = AgentRouter.job_status("job_missing")
    assert {:error, :not_found} = AgentRouter.cancel_job("job_missing")
  end

  test "policy can allow discovery but deny invocation" do
    Application.put_env(:synaptic, :agent_policy_module, DiscoveryAllowInvokeDenyPolicy)

    caller_ctx = %{tenant_id: "default", user_id: "u1"}

    {:ok, _service} =
      Agent.register_service(
        "internet.search",
        %{
          kind: :workflow,
          capabilities: ["internet.search"],
          visibility: :tenant,
          provider: {:workflow_module, SearchWorkflow}
        }
      )

    assert {:ok, _service} =
             AgentDirectory.lookup_service("internet.search", caller_ctx: caller_ctx)

    assert {:error, :unauthorized} =
             AgentRouter.call("internet.search", %{query: "nope"}, caller_ctx: caller_ctx)
  end

  test "pid-backed instance returns unsupported_action for unknown action" do
    {:ok, pid} = start_supervised(EchoAgent)

    {:ok, _service} =
      Agent.register_service(
        "echo.pid.unsupported",
        %{
          kind: :agent,
          capabilities: ["echo"],
          visibility: :tenant,
          provider: {:pid, pid}
        }
      )

    caller_ctx = %{tenant_id: "default", user_id: "u1"}
    {:ok, started} = AgentRouter.call("echo.pid.unsupported", %{}, caller_ctx: caller_ctx)

    assert {:error, :unsupported_action} =
             AgentRouter.call(started.instance.instance_id, %{action: :unknown},
               caller_ctx: caller_ctx
             )
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
