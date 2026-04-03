defmodule Synaptic.AgentRouter do
  @moduledoc """
  Authorized routing and invocation for services, instances, and task references.
  """

  use GenServer

  alias Synaptic.{AgentDirectory, AgentHandle, AgentPolicy, AgentDirectory.Store, WorkloadManager}

  @default_timeout 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def call(target, payload, opts \\ []) do
    :telemetry.span([:synaptic, :agent_router, :call], %{}, fn ->
      result = do_call(target, payload, opts)
      {result, %{status: router_status(result)}}
    end)
  end

  def cast(target, payload, opts \\ []) do
    Task.start(fn ->
      _ = do_call(target, payload, opts)
    end)

    :ok
  end

  def start_job(target, payload, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:start_job, target, payload, opts},
      Keyword.get(opts, :timeout, @default_timeout)
    )
  end

  def job_status(job_id, _opts \\ []) do
    GenServer.call(__MODULE__, {:job_status, job_id})
  end

  def cancel_job(job_id, _opts \\ []) do
    GenServer.call(__MODULE__, {:cancel_job, job_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{jobs: %{}}}

  @impl true
  def handle_call({:start_job, target, payload, opts}, _from, state) do
    job_id = gen_id("job")
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result = do_call(target, payload, opts)
        send(parent, {:job_result, job_id, self(), result})
      end)

    ref = Process.monitor(pid)
    now = DateTime.utc_now()

    job = %{
      job_id: job_id,
      pid: pid,
      ref: ref,
      status: :running,
      result: nil,
      inserted_at: now,
      updated_at: now
    }

    handle = %AgentHandle{target_type: :job, job_id: job_id, metadata: %{status: :running}}
    {:reply, {:ok, handle}, put_in(state.jobs[job_id], job)}
  end

  def handle_call({:job_status, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      job ->
        {:reply, {:ok, Map.take(job, [:job_id, :status, :result, :updated_at, :inserted_at])},
         state}
    end
  end

  def handle_call({:cancel_job, job_id}, _from, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid} = job ->
        Process.exit(pid, :kill)
        new_job = %{job | status: :canceled, updated_at: DateTime.utc_now()}
        {:reply, :ok, put_in(state.jobs[job_id], new_job)}
    end
  end

  @impl true
  def handle_info({:job_result, job_id, pid, result}, state) do
    new_state =
      update_in(state.jobs[job_id], fn
        nil ->
          nil

        job when job.pid == pid ->
          %{job | status: :completed, result: result, updated_at: DateTime.utc_now()}

        job ->
          job
      end)

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {job_id, job} =
      Enum.find_value(state.jobs, {nil, nil}, fn {id, job} ->
        if job.ref == ref, do: {id, job}
      end)

    if job_id && job && job.status == :running do
      new_job = %{
        job
        | status: :failed,
          result: {:error, {:exit, reason}},
          updated_at: DateTime.utc_now()
      }

      {:noreply, put_in(state.jobs[job_id], new_job)}
    else
      {:noreply, state}
    end
  end

  defp do_call(target, payload, opts) do
    caller_ctx = caller_ctx(opts)
    base_monitor_ctx = build_monitor_context(target, payload, opts, caller_ctx)

    with {:ok, resolved} <- resolve_target(target, caller_ctx, opts) do
      monitor_ctx = enrich_monitor_context(base_monitor_ctx, resolved)
      capture_router_event(:started, monitor_ctx, payload, nil)

      case authorize_invoke(caller_ctx, resolved, payload) do
        :ok ->
          result =
            dispatch(
              resolved,
              payload,
              caller_ctx,
              Keyword.put(opts, :monitor_context, monitor_ctx)
            )

          capture_router_event(:finished, monitor_ctx, payload, result)
          result

        err ->
          capture_router_event(:finished, monitor_ctx, payload, err)
          err
      end
    else
      {:error, _} = err ->
        capture_router_event(:finished, base_monitor_ctx, payload, err)
        err

      {:error, _, _} = err ->
        capture_router_event(:finished, base_monitor_ctx, payload, err)
        err
    end
  end

  defp resolve_target(%AgentHandle{target_type: :task_ref, task_ref_id: id}, caller_ctx, opts)
       when is_binary(id) do
    tenant_id = Map.get(caller_ctx, :tenant_id, Keyword.get(opts, :tenant_id, "default"))

    with {:ok, task} <- AgentDirectory.lookup_task_reference(id, tenant_id: tenant_id),
         {:ok, instance} <-
           AgentDirectory.lookup_instance(task.instance_id,
             tenant_id: tenant_id,
             caller_ctx: caller_ctx
           ) do
      {:ok,
       %{kind: :instance, service_id: task.service_id, instance: instance, task_reference: task}}
    end
  end

  defp resolve_target(%AgentHandle{target_type: :instance, instance_id: id}, caller_ctx, opts)
       when is_binary(id) do
    resolve_target(id, caller_ctx, opts)
  end

  defp resolve_target(%AgentHandle{target_type: :service, service_id: id}, caller_ctx, opts)
       when is_binary(id) do
    resolve_target(id, caller_ctx, opts)
  end

  defp resolve_target(%{task_ref_id: task_ref_id}, caller_ctx, opts)
       when is_binary(task_ref_id) do
    resolve_target(
      %AgentHandle{target_type: :task_ref, task_ref_id: task_ref_id},
      caller_ctx,
      opts
    )
  end

  defp resolve_target(%{} = query, caller_ctx, opts) do
    tenant_id = Map.get(caller_ctx, :tenant_id, Keyword.get(opts, :tenant_id, "default"))

    case AgentDirectory.resolve_task_reference(Map.put_new(query, :tenant_id, tenant_id),
           tenant_id: tenant_id
         ) do
      {:ok, task} ->
        resolve_target(
          %AgentHandle{target_type: :task_ref, task_ref_id: task.task_ref_id},
          caller_ctx,
          opts
        )

      {:error, _, _} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  defp resolve_target(target, caller_ctx, opts) when is_binary(target) do
    tenant_id = Map.get(caller_ctx, :tenant_id, Keyword.get(opts, :tenant_id, "default"))

    case Store.module().get_instance(tenant_id, target) do
      {:ok, _} ->
        with {:ok, instance} <-
               AgentDirectory.lookup_instance(target,
                 tenant_id: tenant_id,
                 caller_ctx: caller_ctx
               ),
             {:ok, service} <-
               AgentDirectory.lookup_service(instance.service_id,
                 tenant_id: tenant_id,
                 caller_ctx: caller_ctx
               ) do
          {:ok,
           %{
             kind: :instance,
             service_id: service.service_id,
             service: service,
             instance: instance
           }}
        end

      :error ->
        with {:ok, service} <-
               AgentDirectory.lookup_service(target, tenant_id: tenant_id, caller_ctx: caller_ctx) do
          {:ok, %{kind: :service, service_id: service.service_id, service: service}}
        end
    end
  end

  defp resolve_target(_, _caller_ctx, _opts), do: {:error, :invalid_target}

  defp authorize_invoke(caller_ctx, %{service: service} = resolved, payload) do
    invocation = %{mode: :call, payload: payload, target_kind: resolved.kind}

    case AgentPolicy.authorize_invoke(
           caller_ctx,
           Map.get(caller_ctx, :caller_agent_id),
           service,
           invocation
         ) do
      :allow -> :ok
      {:deny, :invisible} -> {:error, :invisible}
      {:deny, _reason} -> {:error, :unauthorized}
    end
  end

  defp authorize_invoke(caller_ctx, %{service_id: service_id} = resolved, payload) do
    tenant_id = Map.get(caller_ctx, :tenant_id, "default")

    with {:ok, service} <-
           AgentDirectory.lookup_service(service_id, tenant_id: tenant_id, caller_ctx: caller_ctx) do
      authorize_invoke(caller_ctx, Map.put(resolved, :service, service), payload)
    end
  end

  defp dispatch(%{kind: :service, service: service}, payload, caller_ctx, opts) do
    if service.routing_mode in [:async] do
      {:error, :unsupported_mode}
    else
      ensure_opts =
        [
          caller_ctx: caller_ctx,
          payload: payload,
          monitor_context: Keyword.get(opts, :monitor_context, %{})
        ] ++ routing_meta_opts(payload, opts)

      with {:ok, %{instance: instance, task_reference: task, handle: handle}} <-
             WorkloadManager.ensure_instance(service.service_id, caller_ctx, ensure_opts) do
        maybe_wait_for_workflow(instance, task, handle, opts)
      end
    end
  end

  defp dispatch(
         %{kind: :instance, instance: instance, task_reference: task_ref},
         payload,
         _caller_ctx,
         opts
       ) do
    dispatch_instance(instance, payload, task_ref, opts)
  end

  defp dispatch(%{kind: :instance, instance: instance} = _resolved, payload, _caller_ctx, opts) do
    dispatch_instance(instance, payload, nil, opts)
  end

  defp dispatch_instance(instance, payload, task_ref, opts) do
    case {instance.endpoint_type, instance.endpoint_ref} do
      {:run_id, run_id} -> dispatch_workflow_instance(instance, run_id, payload, task_ref, opts)
      {:pid, pid} when is_pid(pid) -> dispatch_pid_instance(instance, pid, payload)
      _ -> {:error, :instance_unavailable}
    end
  end

  defp dispatch_workflow_instance(instance, run_id, payload, task_ref, opts)
       when is_map(payload) do
    case Map.get(payload, :action, :inspect) do
      :inspect ->
        snapshot = safe_snapshot(run_id, Keyword.get(opts, :timeout, @default_timeout))
        {:ok, %{instance: instance, run_id: run_id, snapshot: snapshot, task_reference: task_ref}}

      :history ->
        {:ok,
         %{
           instance: instance,
           run_id: run_id,
           history: Synaptic.history(run_id),
           task_reference: task_ref
         }}

      :resume ->
        resume_payload = Map.get(payload, :payload, %{})

        case Synaptic.resume(run_id, resume_payload) do
          :ok ->
            snapshot = wait_for_terminal_or_pause(run_id, opts)

            {:ok,
             %{instance: instance, run_id: run_id, snapshot: snapshot, task_reference: task_ref}}

          {:error, _} = err ->
            err
        end

      :stop ->
        reason = Map.get(payload, :reason, :canceled)

        case Synaptic.stop(run_id, reason) do
          :ok ->
            {:ok,
             %{
               instance: instance,
               run_id: run_id,
               stopped: true,
               reason: reason,
               task_reference: task_ref
             }}

          {:error, _} = err ->
            err
        end

      other ->
        {:error, {:unsupported_action, other}}
    end
  end

  defp dispatch_workflow_instance(_instance, run_id, _payload, _task_ref, _opts) do
    # For service calls, payload is consumed at spawn time; raw instance calls default to inspect.
    {:ok, %{run_id: run_id, snapshot: Synaptic.inspect(run_id)}}
  end

  defp dispatch_pid_instance(instance, pid, payload) do
    case payload do
      %{action: :call, message: msg} ->
        {:ok, %{instance: instance, result: GenServer.call(pid, msg)}}

      %{action: :cast, message: msg} ->
        GenServer.cast(pid, msg)
        {:ok, %{instance: instance, cast: true}}

      _ ->
        {:error, :unsupported_action}
    end
  end

  defp maybe_wait_for_workflow(instance, task, handle, opts) do
    run_id = handle.run_id
    snapshot = wait_for_terminal_or_pause(run_id, opts)

    {:ok,
     %{
       handle: handle,
       instance: instance,
       task_reference: task,
       run_id: run_id,
       snapshot: snapshot
     }}
  end

  defp wait_for_terminal_or_pause(run_id, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    cond do
      timeout <= 0 ->
        # Non-blocking agent calls should not risk crashing on snapshot timeouts while
        # the workflow process is still executing a long step. Try a tiny snapshot budget
        # first so already-finished workflows can still surface terminal status.
        safe_snapshot(run_id, 1)

      true ->
        deadline = System.monotonic_time(:millisecond) + timeout
        do_wait_snapshot(run_id, deadline)
    end
  end

  defp do_wait_snapshot(run_id, deadline) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline - now, 0)
    inspect_timeout = remaining |> min(250) |> max(1)
    snapshot = safe_snapshot(run_id, inspect_timeout)

    if snapshot.status in [:running] and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      do_wait_snapshot(run_id, deadline)
    else
      snapshot
    end
  end

  defp safe_snapshot(run_id, timeout) when is_integer(timeout) and timeout <= 0 do
    %{run_id: run_id, status: :running}
  end

  defp safe_snapshot(run_id, timeout) when is_integer(timeout) do
    try do
      Synaptic.inspect(run_id, timeout)
    rescue
      _ ->
        %{run_id: run_id, status: :unknown}
    catch
      :exit, {:timeout, _} ->
        # Snapshot call timed out while the workflow process was busy (often inside a long
        # step). Treat as still running so callers can keep polling within their deadline.
        %{run_id: run_id, status: :running}

      :exit, reason ->
        %{run_id: run_id, status: :unknown, last_error: {:exit, reason}}
    end
  end

  defp routing_meta_opts(payload, opts) do
    [
      purpose: Keyword.get(opts, :purpose) || Map.get(payload, :purpose),
      labels: Keyword.get(opts, :labels, %{}),
      aliases: Keyword.get(opts, :aliases, [])
    ]
  end

  defp caller_ctx(opts) do
    ctx = Keyword.get(opts, :caller_ctx, %{})
    defaults = Synaptic.AgentPolicy.scope_defaults(ctx)

    Map.merge(defaults, ctx)
    |> Map.put_new(:tenant_id, Keyword.get(opts, :tenant_id, "default"))
  end

  defp build_monitor_context(target, payload, opts, caller_ctx) do
    request_id = extract_value(payload, :request_id)
    purpose = Keyword.get(opts, :purpose) || extract_value(payload, :purpose)

    %{
      target: inspect(target),
      trace_id: extract_value(payload, :trace_id) || gen_id("trace"),
      call_id: gen_id("call"),
      parent_call_id: extract_value(payload, :parent_call_id),
      caller_agent_id: Map.get(caller_ctx, :caller_agent_id),
      target_service_id: target_service_id(target),
      request_id: request_id,
      purpose: purpose
    }
  end

  defp enrich_monitor_context(ctx, %{service_id: service_id} = resolved) do
    ctx
    |> Map.put(:target_service_id, service_id)
    |> maybe_put_monitor(:service_id, service_id)
    |> maybe_put_monitor(:instance_id, get_in(resolved, [:instance, :instance_id]))
    |> maybe_put_monitor(:task_ref_id, get_in(resolved, [:task_reference, :task_ref_id]))
  end

  defp capture_router_event(stage, ctx, payload, result) do
    {service_id, instance_id, task_ref_id, run_id, status, summary, data} =
      case {stage, result} do
        {:started, _} ->
          {ctx[:service_id] || ctx[:target_service_id], ctx[:instance_id], ctx[:task_ref_id], nil,
           :started, "Router call started",
           %{target: ctx[:target], payload_keys: payload_keys(payload), input: payload}}

        {:finished, {:ok, response}} ->
          ids = response_ids(response)
          snapshot_status = get_in(response, [:snapshot, :status])

          {
            ids.service_id || ctx[:service_id] || ctx[:target_service_id],
            ids.instance_id || ctx[:instance_id],
            ids.task_ref_id || ctx[:task_ref_id],
            ids.run_id,
            snapshot_status || :completed,
            "Router call finished",
            %{
              target: ctx[:target],
              payload_keys: payload_keys(payload),
              result_status: router_status({:ok, response}),
              input: payload,
              output: response
            }
          }

        {:finished, {:error, reason}} ->
          {ctx[:service_id] || ctx[:target_service_id], ctx[:instance_id], ctx[:task_ref_id], nil,
           :failed, "Router call failed: #{inspect(reason)}",
           %{
             target: ctx[:target],
             payload_keys: payload_keys(payload),
             error: reason,
             input: payload,
             output: %{error: reason}
           }}

        {:finished, other} ->
          {ctx[:service_id] || ctx[:target_service_id], ctx[:instance_id], ctx[:task_ref_id], nil,
           :unknown, "Router call finished",
           %{
             target: ctx[:target],
             payload_keys: payload_keys(payload),
             result: inspect(other),
             input: payload,
             output: other
           }}
      end

    Synaptic.Monitor.capture(%{
      kind: :router_call,
      status: status,
      service_id: service_id,
      instance_id: instance_id,
      task_ref_id: task_ref_id,
      run_id: run_id,
      caller_agent_id: ctx[:caller_agent_id],
      target_service_id: ctx[:target_service_id] || service_id,
      trace_id: ctx[:trace_id],
      call_id: ctx[:call_id],
      parent_call_id: ctx[:parent_call_id],
      request_id: ctx[:request_id],
      purpose: ctx[:purpose],
      summary: summary,
      data: data
    })
  end

  defp response_ids(response) do
    handle = Map.get(response, :handle) || %{}
    instance = Map.get(response, :instance) || %{}
    task_reference = Map.get(response, :task_reference) || %{}
    snapshot = Map.get(response, :snapshot) || %{}

    %{
      service_id:
        Map.get(instance, :service_id) ||
          Map.get(handle, :service_id) ||
          Map.get(task_reference, :service_id),
      instance_id:
        Map.get(instance, :instance_id) ||
          Map.get(handle, :instance_id) ||
          Map.get(task_reference, :instance_id),
      task_ref_id:
        Map.get(task_reference, :task_ref_id) ||
          Map.get(handle, :task_ref_id),
      run_id:
        Map.get(response, :run_id) ||
          Map.get(handle, :run_id) ||
          Map.get(snapshot, :run_id)
    }
  end

  defp payload_keys(payload) when is_map(payload), do: Map.keys(payload)
  defp payload_keys(_payload), do: []

  defp extract_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp extract_value(_payload, _key), do: nil

  defp target_service_id(%AgentHandle{service_id: service_id}) when is_binary(service_id),
    do: service_id

  defp target_service_id(%{task_ref_id: _task_ref_id}), do: nil
  defp target_service_id(target) when is_binary(target), do: target
  defp target_service_id(_target), do: nil

  defp maybe_put_monitor(ctx, _key, nil), do: ctx
  defp maybe_put_monitor(ctx, key, value), do: Map.put(ctx, key, value)

  defp router_status({:ok, _}), do: :ok
  defp router_status({:error, _}), do: :error
  defp router_status(_), do: :unknown

  defp gen_id(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
