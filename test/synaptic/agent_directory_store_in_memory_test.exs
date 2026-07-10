defmodule Synaptic.AgentDirectoryStoreInMemoryTest do
  use ExUnit.Case, async: false

  alias Synaptic.AgentDirectory.Store.InMemory

  setup do
    InMemory.reset!()
    :ok
  end

  test "service CRUD and tenant-scoped filtering" do
    service_a = %{tenant_id: "t1", service_id: "svc.a", visibility: :tenant, capabilities: ["a"]}
    service_b = %{tenant_id: "t2", service_id: "svc.b", visibility: :tenant, capabilities: ["b"]}

    assert {:ok, ^service_a} = InMemory.put_service(service_a)
    assert {:ok, ^service_b} = InMemory.put_service(service_b)

    assert {:ok, ^service_a} = InMemory.get_service("t1", "svc.a")
    assert :error = InMemory.get_service("t1", "svc.b")

    assert [^service_a] = InMemory.list_services(%{tenant_id: "t1"})
    assert :ok = InMemory.delete_service("t1", "svc.a")
    assert :error = InMemory.get_service("t1", "svc.a")
  end

  test "instance update and filtering by status list" do
    inst = %{
      tenant_id: "default",
      instance_id: "inst1",
      service_id: "svc",
      status: :ready,
      user_id: "u1"
    }

    assert {:ok, _} = InMemory.put_instance(inst)

    assert {:ok, updated} =
             InMemory.update_instance("default", "inst1", fn rec ->
               Map.put(rec, :status, :running)
             end)

    assert updated.status == :running
    assert :error = InMemory.update_instance("default", "missing", & &1)

    assert [one] =
             InMemory.list_instances(%{
               tenant_id: "default",
               status: [:running, :waiting_for_human]
             })

    assert one.instance_id == "inst1"
  end

  test "task reference CRUD and alias filtering" do
    ref1 = %{
      tenant_id: "default",
      task_ref_id: "task1",
      user_id: "u1",
      service_id: "svc",
      capability: "svc",
      alias_keys: ["last"],
      status: :running
    }

    ref2 = %{
      tenant_id: "default",
      task_ref_id: "task2",
      user_id: "u1",
      service_id: "svc",
      capability: "svc",
      alias_keys: ["other"],
      status: :completed
    }

    assert {:ok, _} = InMemory.put_task_reference(ref1)
    assert {:ok, _} = InMemory.put_task_reference(ref2)

    assert {:ok, fetched} = InMemory.get_task_reference("default", "task1")
    assert fetched.task_ref_id == "task1"

    assert [only] = InMemory.list_task_references(%{tenant_id: "default", alias: "last"})
    assert only.task_ref_id == "task1"

    assert {:ok, changed} =
             InMemory.update_task_reference("default", "task1", fn rec ->
               Map.put(rec, :status, :completed)
             end)

    assert changed.status == :completed
    assert :ok = InMemory.delete_task_reference("default", "task1")
    assert :error = InMemory.get_task_reference("default", "task1")
  end

  test "reset clears all record types" do
    assert {:ok, _} = InMemory.put_service(%{tenant_id: "default", service_id: "svc"})

    assert {:ok, _} =
             InMemory.put_instance(%{
               tenant_id: "default",
               instance_id: "inst",
               service_id: "svc"
             })

    assert {:ok, _} =
             InMemory.put_task_reference(%{
               tenant_id: "default",
               task_ref_id: "task",
               user_id: "u1",
               service_id: "svc",
               capability: "svc",
               status: :running
             })

    assert :ok = InMemory.reset!()
    assert [] = InMemory.list_services(%{})
    assert [] = InMemory.list_instances(%{})
    assert [] = InMemory.list_task_references(%{})
  end
end
