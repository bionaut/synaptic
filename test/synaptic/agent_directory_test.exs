defmodule Synaptic.AgentDirectoryTest do
  use ExUnit.Case, async: false

  alias Synaptic.AgentDirectory

  defmodule DummyWorkflow do
    use Synaptic.Workflow

    step :ok do
      {:ok, %{ok: true}}
    end

    commit()
  end

  setup do
    AgentDirectory.reset!()
    :ok
  end

  test "services are private by default and visible to owner" do
    {:ok, _} =
      AgentDirectory.register_service(
        "search.private",
        %{
          provider: {:workflow_module, DummyWorkflow},
          capabilities: ["internet.search"],
          metadata: %{owner_user_id: "u1"}
        }
      )

    assert {:error, :invisible} = AgentDirectory.lookup_service("search.private", caller_ctx: %{user_id: "u2"})
    assert {:ok, service} = AgentDirectory.lookup_service("search.private", caller_ctx: %{user_id: "u1"})
    assert service.visibility == :private
  end

  test "task reference resolution is deterministic by alias and recency" do
    now = DateTime.utc_now()

    {:ok, _} =
      AgentDirectory.put_task_reference(%{
        tenant_id: "default",
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :completed,
        last_activity_at: DateTime.add(now, -30, :second)
      })

    {:ok, newer} =
      AgentDirectory.put_task_reference(%{
        tenant_id: "default",
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :waiting_for_human,
        last_activity_at: now
      })

    assert {:ok, resolved} =
             AgentDirectory.resolve_task_reference(%{
               user_id: "u1",
               capability: "internet.search",
               alias: "last_search",
               recency: :latest
             })

    assert resolved.task_ref_id == newer.task_ref_id
  end

  test "task reference resolution returns ambiguity when top-ranked records tie" do
    ts = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, first} =
      AgentDirectory.put_task_reference(%{
        tenant_id: "default",
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :running,
        last_activity_at: ts,
        inserted_at: ts
      })

    {:ok, second} =
      AgentDirectory.put_task_reference(%{
        tenant_id: "default",
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["last_search"],
        status: :running,
        last_activity_at: ts,
        inserted_at: ts
      })

    assert {:error, :ambiguous_task_reference, candidates} =
             AgentDirectory.resolve_task_reference(%{
               user_id: "u1",
               capability: "internet.search",
               alias: "last_search"
             })

    ids = Enum.map(candidates, & &1.task_ref_id)
    assert first.task_ref_id in ids
    assert second.task_ref_id in ids
  end

  test "list_user_tasks can filter active tasks by status" do
    {:ok, _} =
      AgentDirectory.put_task_reference(%{
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        status: :completed
      })

    {:ok, active} =
      AgentDirectory.put_task_reference(%{
        user_id: "u1",
        service_id: "internet.search",
        capability: "internet.search",
        status: :waiting_for_human
      })

    tasks = AgentDirectory.list_user_tasks("u1", %{status: [:waiting_for_human]})

    assert Enum.map(tasks, & &1.task_ref_id) == [active.task_ref_id]
  end

  test "task reference recency supports :oldest and {:within_ms, n}" do
    now = DateTime.utc_now()

    {:ok, oldest} =
      AgentDirectory.put_task_reference(%{
        user_id: "u2",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["search"],
        status: :completed,
        last_activity_at: DateTime.add(now, -120, :second)
      })

    {:ok, recent} =
      AgentDirectory.put_task_reference(%{
        user_id: "u2",
        service_id: "internet.search",
        capability: "internet.search",
        alias_keys: ["search"],
        status: :running,
        last_activity_at: now
      })

    assert {:ok, resolved_oldest} =
             AgentDirectory.resolve_task_reference(%{
               user_id: "u2",
               capability: "internet.search",
               alias: "search",
               recency: :oldest
             })

    assert resolved_oldest.task_ref_id == oldest.task_ref_id

    assert {:ok, resolved_recent} =
             AgentDirectory.resolve_task_reference(%{
               user_id: "u2",
               capability: "internet.search",
               alias: "search",
               recency: {:within_ms, 10_000}
             })

    assert resolved_recent.task_ref_id == recent.task_ref_id
  end

  test "update_instance and heartbeat_instance update timestamps/status and return not_found when missing" do
    {:ok, inst} =
      AgentDirectory.register_instance(%{
        instance_id: "inst_1",
        service_id: "internet.search",
        user_id: "u1",
        status: :starting,
        endpoint_type: :pid,
        endpoint_ref: self(),
        visibility: :tenant
      })

    first_activity = inst.last_activity_at

    assert {:ok, updated} =
             AgentDirectory.update_instance("inst_1", %{status: :ready}, caller_ctx: %{user_id: "u1"})

    assert updated.status == :ready

    Process.sleep(5)

    assert {:ok, heartbeated} =
             AgentDirectory.heartbeat_instance("inst_1", %{health: :healthy}, caller_ctx: %{user_id: "u1"})

    assert heartbeated.health == :healthy
    assert DateTime.compare(heartbeated.last_activity_at, first_activity) in [:gt, :eq]

    assert {:error, :not_found} =
             AgentDirectory.update_instance("missing_inst", %{status: :ready})

    assert {:error, :not_found} =
             AgentDirectory.heartbeat_instance("missing_inst")
  end

  test "lookup_instance and lookup_task_reference return not_found for missing records" do
    assert {:error, :not_found} = AgentDirectory.lookup_instance("missing", caller_ctx: %{user_id: "u1"})
    assert {:error, :not_found} = AgentDirectory.lookup_task_reference("missing")
  end
end
