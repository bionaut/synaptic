defmodule Synaptic.WorkloadManager do
  @moduledoc """
  Manages workflow-backed agent instances and tracks their lifecycle in the
  AgentDirectory.
  """

  use GenServer

  alias Phoenix.PubSub
  alias Synaptic.{AgentDirectory, AgentDirectory.Store, AgentHandle}

  @active_statuses [:starting, :ready, :running, :waiting_for_human, :busy]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_instance(service_id, caller_ctx, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:ensure_instance, service_id, caller_ctx, opts},
      Keyword.get(opts, :timeout, 15_000)
    )
  end

  def start_workflow_instance(service_id, payload, opts \\ []) do
    caller_ctx = Keyword.get(opts, :caller_ctx, %{})
    ensure_instance(service_id, caller_ctx, Keyword.put(opts, :payload, payload))
  end

  def stop_instance(instance_id, reason \\ :normal, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, inst} <-
           AgentDirectory.lookup_instance(instance_id,
             tenant_id: tenant_id,
             caller_ctx: Keyword.get(opts, :caller_ctx, %{})
           ) do
      case {inst.endpoint_type, inst.endpoint_ref} do
        {:run_id, run_id} -> Synaptic.stop(run_id, reason)
        _ -> {:error, :unsupported_endpoint}
      end
    end
  end

  def instance_status(instance_id, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, "default")

    with {:ok, inst} <-
           AgentDirectory.lookup_instance(instance_id,
             tenant_id: tenant_id,
             caller_ctx: Keyword.get(opts, :caller_ctx, %{})
           ) do
      status =
        case {inst.endpoint_type, inst.endpoint_ref} do
          {:run_id, run_id} -> safe_inspect(run_id)
          _ -> nil
        end

      {:ok, %{instance: inst, runtime: status}}
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{runs: %{}}}
  end

  @impl true
  def handle_call({:ensure_instance, service_id, caller_ctx, opts}, _from, state) do
    tenant_id = Map.get(caller_ctx, :tenant_id, Keyword.get(opts, :tenant_id, "default"))
    reuse? = Keyword.get(opts, :reuse, true)

    with {:ok, service} <- get_service(tenant_id, service_id) do
      case maybe_reuse_instance(service, caller_ctx, opts, reuse?) do
        {:ok, inst} ->
          task_reference = maybe_find_task_ref(tenant_id, inst.instance_id, caller_ctx)

          Synaptic.Monitor.capture(%{
            kind: :instance_reused,
            status: inst.status || :ready,
            service_id: service.service_id,
            instance_id: inst.instance_id,
            task_ref_id: task_reference && task_reference.task_ref_id,
            run_id: if(inst.endpoint_type == :run_id, do: inst.endpoint_ref),
            caller_agent_id: Map.get(caller_ctx, :caller_agent_id),
            request_id: extract_monitor_value(opts, :request_id),
            purpose: Keyword.get(opts, :purpose),
            summary: "Reused workflow instance #{inst.instance_id}",
            data: %{tenant_id: tenant_id}
          })

          {:reply, {:ok, %{instance: inst, task_reference: task_reference}}, state}

        :none ->
          case start_instance_for_service(service, caller_ctx, opts, state) do
            {:ok, result, new_state} -> {:reply, {:ok, result}, new_state}
            {:error, reason} -> {:reply, {:error, :spawn_failed, reason}, state}
          end
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_info({:synaptic_event, event}, state) do
    run_id = event[:run_id]

    case Map.get(state.runs, run_id) do
      nil ->
        {:noreply, state}

      %{tenant_id: tenant_id, instance_id: instance_id, task_ref_id: task_ref_id} = info ->
        status = event_to_status(event)
        last_error = event[:reason]
        now = DateTime.utc_now()

        _ =
          AgentDirectory.update_instance(
            instance_id,
            %{status: status, last_error: last_error, last_activity_at: now},
            tenant_id: tenant_id
          )

        _ =
          AgentDirectory.update_task_reference(
            task_ref_id,
            %{status: status, last_activity_at: now, run_id: run_id, instance_id: instance_id},
            tenant_id: tenant_id
          )

        monitor_ctx = Map.get(info, :monitor_context, %{})

        Synaptic.Monitor.capture(%{
          kind: :status_sync,
          status: status,
          service_id: monitor_ctx[:service_id],
          instance_id: instance_id,
          task_ref_id: task_ref_id,
          run_id: run_id,
          caller_agent_id: monitor_ctx[:caller_agent_id],
          target_service_id: monitor_ctx[:target_service_id] || monitor_ctx[:service_id],
          trace_id: monitor_ctx[:trace_id],
          call_id: monitor_ctx[:call_id],
          parent_call_id: monitor_ctx[:parent_call_id],
          request_id: monitor_ctx[:request_id],
          purpose: monitor_ctx[:purpose],
          summary: "Synchronized run status #{status}",
          data: %{last_error: last_error}
        })

        new_state =
          if status in [:completed, :failed, :stopped] do
            %{state | runs: Map.delete(state.runs, run_id)}
          else
            put_in(state.runs[run_id], info)
          end

        {:noreply, new_state}
    end
  end

  defp maybe_reuse_instance(service, caller_ctx, opts, true) do
    tenant_id = service.tenant_id
    base_filters = %{tenant_id: tenant_id, service_id: service.service_id}

    filters =
      base_filters
      |> maybe_put(:user_id, Map.get(caller_ctx, :user_id))
      |> maybe_put(
        :session_id,
        Keyword.get(opts, :session_id) || Map.get(caller_ctx, :session_id)
      )

    AgentDirectory.list_instances(filters, tenant_id: tenant_id, caller_ctx: caller_ctx)
    |> Enum.filter(&(&1.status in @active_statuses))
    |> Enum.sort_by(&{&1.last_activity_at, &1.instance_id}, :desc)
    |> List.first()
    |> case do
      nil -> :none
      inst -> {:ok, inst}
    end
  end

  defp maybe_reuse_instance(_service, _caller_ctx, _opts, _reuse?), do: :none

  defp maybe_find_task_ref(tenant_id, instance_id, caller_ctx) do
    user_id = Map.get(caller_ctx, :user_id)

    if user_id do
      case AgentDirectory.resolve_task_reference(
             %{tenant_id: tenant_id, user_id: user_id, require_active: true, recency: :latest},
             tenant_id: tenant_id
           ) do
        {:ok, task} when task.instance_id == instance_id -> task
        _ -> nil
      end
    else
      nil
    end
  end

  defp start_instance_for_service(service, caller_ctx, opts, state) do
    case {service.provider, service.provider_ref} do
      {:workflow_module, workflow_module} ->
        payload = Keyword.get(opts, :payload, %{})
        instance_id = gen_id("inst")
        task_ref_id = gen_id("task")

        monitor_context =
          opts
          |> Keyword.get(:monitor_context, %{})
          |> Map.new()
          |> Map.put(:service_id, service.service_id)
          |> Map.put(:target_service_id, service.service_id)
          |> Map.put(:instance_id, instance_id)
          |> Map.put(:task_ref_id, task_ref_id)
          |> Map.put(:workflow, workflow_module)
          |> Map.put_new(:run_source, :router)
          |> Map.put_new(:caller_agent_id, Map.get(caller_ctx, :caller_agent_id))
          |> Map.put_new(:purpose, Keyword.get(opts, :purpose) || get_in(payload, [:purpose]))

        workflow_opts = Map.get(service, :spawn_config, %{}) |> Map.get(:workflow_opts, [])
        workflow_opts = maybe_put_requested_run_id(workflow_opts, payload)
        workflow_opts = Keyword.put(workflow_opts, :monitor_context, monitor_context)

        with {:ok, run_id} <- Synaptic.start(workflow_module, payload, workflow_opts) do
          {:ok, instance} =
            AgentDirectory.register_instance(
              %{
                instance_id: instance_id,
                service_id: service.service_id,
                user_id: Map.get(caller_ctx, :user_id),
                session_id: Map.get(caller_ctx, :session_id),
                purpose: Keyword.get(opts, :purpose) || get_in(payload, [:purpose]),
                labels: Keyword.get(opts, :labels, %{}),
                status: :running,
                endpoint_type: :run_id,
                endpoint_ref: run_id,
                health: :healthy,
                visibility: service.visibility,
                metadata:
                  Map.put(service.metadata || %{}, :owner_user_id, Map.get(caller_ctx, :user_id))
              },
              tenant_id: service.tenant_id
            )

          capability = List.first(service.capabilities) || service.service_id

          {:ok, task_ref} =
            AgentDirectory.put_task_reference(
              %{
                tenant_id: service.tenant_id,
                task_ref_id: task_ref_id,
                user_id: Map.get(caller_ctx, :user_id),
                session_id: Map.get(caller_ctx, :session_id),
                caller_agent_id: Map.get(caller_ctx, :caller_agent_id),
                service_id: service.service_id,
                instance_id: instance.instance_id,
                run_id: run_id,
                capability: capability,
                purpose: instance.purpose,
                alias_keys: aliases_from_opts(opts),
                status: :running,
                metadata: %{labels: instance.labels, request_id: monitor_context[:request_id]}
              },
              tenant_id: service.tenant_id
            )

          :ok = PubSub.subscribe(Synaptic.PubSub, "synaptic:run:" <> run_id)

          Synaptic.Monitor.capture(%{
            kind: :instance_spawned,
            status: :running,
            service_id: service.service_id,
            instance_id: instance.instance_id,
            task_ref_id: task_ref.task_ref_id,
            run_id: run_id,
            caller_agent_id: Map.get(caller_ctx, :caller_agent_id),
            target_service_id: service.service_id,
            trace_id: monitor_context[:trace_id],
            call_id: monitor_context[:call_id],
            parent_call_id: monitor_context[:parent_call_id],
            request_id: monitor_context[:request_id],
            purpose: monitor_context[:purpose],
            summary: "Spawned workflow instance #{instance.instance_id}",
            data: %{workflow: inspect(workflow_module), tenant_id: service.tenant_id}
          })

          new_state =
            put_in(state.runs[run_id], %{
              tenant_id: service.tenant_id,
              instance_id: instance.instance_id,
              task_ref_id: task_ref.task_ref_id,
              monitor_context: monitor_context
            })

          handle = %AgentHandle{
            target_type: :instance,
            tenant_id: service.tenant_id,
            service_id: service.service_id,
            instance_id: instance.instance_id,
            task_ref_id: task_ref.task_ref_id,
            run_id: run_id,
            metadata: %{status: :running}
          }

          {:ok, %{instance: instance, task_reference: task_ref, handle: handle}, new_state}
        end

      {:pid, pid} when is_pid(pid) ->
        instance_id = gen_id("inst")

        {:ok, instance} =
          AgentDirectory.register_instance(
            %{
              instance_id: instance_id,
              service_id: service.service_id,
              user_id: Map.get(caller_ctx, :user_id),
              session_id: Map.get(caller_ctx, :session_id),
              status: :ready,
              endpoint_type: :pid,
              endpoint_ref: pid,
              health: :healthy,
              visibility: service.visibility,
              metadata: service.metadata || %{}
            },
            tenant_id: service.tenant_id
          )

        {:ok,
         %{
           instance: instance,
           task_reference: nil,
           handle: %AgentHandle{
             target_type: :instance,
             instance_id: instance_id,
             service_id: service.service_id,
             tenant_id: service.tenant_id
           }
         }, state}

      other ->
        {:error, {:unsupported_provider, other}}
    end
  end

  defp get_service(tenant_id, service_id) do
    case Store.module().get_service(tenant_id, service_id) do
      {:ok, service} -> {:ok, service}
      :error -> {:error, :service_unregistered}
    end
  end

  defp aliases_from_opts(opts) do
    aliases = Keyword.get(opts, :aliases, [])
    if is_list(aliases), do: Enum.map(aliases, &to_string/1), else: []
  end

  defp maybe_put_requested_run_id(workflow_opts, payload)
       when is_list(workflow_opts) and is_map(payload) do
    case Map.get(payload, :run_id) do
      run_id when is_binary(run_id) and run_id != "" ->
        Keyword.put_new(workflow_opts, :run_id, run_id)

      _ ->
        workflow_opts
    end
  end

  defp maybe_put_requested_run_id(workflow_opts, _payload), do: workflow_opts

  defp event_to_status(%{event: :waiting_for_human}), do: :waiting_for_human
  defp event_to_status(%{event: :resumed}), do: :running
  defp event_to_status(%{event: :step_completed}), do: :running
  defp event_to_status(%{event: :retrying}), do: :running
  defp event_to_status(%{event: :completed}), do: :completed
  defp event_to_status(%{event: :failed}), do: :failed
  defp event_to_status(%{event: :stopped}), do: :stopped
  defp event_to_status(_), do: :running

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp extract_monitor_value(opts, key) do
    opts
    |> Keyword.get(:monitor_context, %{})
    |> Map.get(key)
  end

  defp gen_id(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp safe_inspect(run_id) do
    Synaptic.inspect(run_id)
  catch
    :exit, {:noproc, _} -> nil
    :exit, _ -> nil
  end
end
