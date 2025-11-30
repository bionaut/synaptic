defmodule Synaptic.Runner do
  @moduledoc """
  GenServer that executes a workflow definition, tracking context, waiting
  states, retries, history, PubSub events, and suspend/resume logic.
  """

  use GenServer
  require Logger

  alias Synaptic.{Registry, Step}
  alias Phoenix.PubSub

  @pubsub Synaptic.PubSub

  @type state :: %{
          run_id: String.t(),
          workflow: module(),
          steps: [Step.t()],
          current_step_index: non_neg_integer(),
          context: map(),
          status: :running | :waiting_for_human | :completed | :failed | :stopped,
          waiting: map() | nil,
          history: list(map()),
          retry_budget: map(),
          last_error: term(),
          async_tasks: %{optional(pid()) => %{step: Step.t(), monitor_ref: reference()}}
        }

  # Client API
  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {:synaptic_runner, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(run_id))
  end

  def resume(run_id, payload) do
    GenServer.call(Registry.via(run_id), {:resume, payload})
  end

  def snapshot(run_id) do
    GenServer.call(Registry.via(run_id), :snapshot)
  end

  def history(run_id) do
    GenServer.call(Registry.via(run_id), :history)
  end

  def stop(run_id, reason \\ :canceled) do
    try do
      GenServer.call(Registry.via(run_id), {:stop, reason})
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
    end
  end

  # Server callbacks
  @impl true
  def init(opts) do
    definition = Keyword.fetch!(opts, :definition)
    steps = definition.steps

    state = %{
      run_id: Keyword.fetch!(opts, :run_id),
      workflow: definition.module,
      steps: steps,
      current_step_index: 0,
      context: Keyword.get(opts, :context, %{}),
      status: :running,
      waiting: nil,
      history: [],
      retry_budget: Map.new(steps, &{&1.name, &1.max_retries}),
      last_error: nil,
      async_tasks: %{}
    }

    {:ok, state, {:continue, :process_next_step}}
  end

  @impl true
  def handle_continue(:process_next_step, state) do
    case maybe_process_step(state) do
      {:continue, new_state} ->
        {:noreply, new_state, {:continue, :process_next_step}}

      {:halt, new_state} ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply = %{
      run_id: state.run_id,
      status: state.status,
      current_step: current_step_name(state),
      context: state.context,
      waiting: state.waiting,
      last_error: state.last_error,
      retries: state.retry_budget
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call(:history, _from, state) do
    {:reply, Enum.reverse(state.history), state}
  end

  @impl true
  def handle_call({:stop, reason}, _from, state) do
    new_state =
      state
      |> Map.put(:status, :stopped)
      |> push_history(%{event: :stopped, reason: reason})
      |> publish_event(%{event: :stopped, reason: reason})

    {:stop, {:shutdown, reason}, :ok, new_state}
  end

  @impl true
  def handle_call({:resume, payload}, _from, %{status: :waiting_for_human} = state) do
    with :ok <- validate_resume_payload(state, payload) do
      new_state =
        state
        |> Map.put(:status, :running)
        |> Map.put(:waiting, nil)
        |> Map.update!(:context, &Map.put(&1, :human_input, payload))
        |> push_history(%{event: :resumed, payload: payload})
        |> publish_event(%{event: :resumed, payload: payload})

      {:reply, :ok, new_state, {:continue, :process_next_step}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, _payload}, _from, state) do
    {:reply, {:error, :not_waiting_for_human}, state}
  end

  defp maybe_process_step(%{status: status} = state) when status != :running,
    do: {:halt, state}

  defp maybe_process_step(state) do
    case Enum.at(state.steps, state.current_step_index) do
      nil ->
        cond do
          state.status != :running ->
            {:halt, state}

          async_pending?(state) ->
            {:halt, state}

          true ->
            new_state =
              state
              |> push_history(%{event: :completed})
              |> publish_event(%{event: :completed})

            {:halt, Map.put(new_state, :status, :completed)}
        end

      step ->
        execute_step(step, state)
    end
  end

  defp execute_step(%Step{type: :parallel} = step, state) do
    Logger.metadata(run_id: state.run_id, step: step.name)
    Logger.debug("running parallel step #{step.name}")

    case invoke_step(step, state) do
      {:error, reason} ->
        handle_step_error(step, reason, state)

      tasks when is_list(tasks) ->
        case run_parallel_tasks(tasks, state.context) do
          {:ok, data} ->
            new_state = handle_step_success(state, step, data)
            {:continue, new_state}

          {:error, reason} ->
            handle_step_error(step, reason, state)
        end

      other ->
        handle_step_error(step, {:invalid_parallel_return, other}, state)
    end
  end

  defp execute_step(%Step{type: :async} = step, state) do
    Logger.metadata(run_id: state.run_id, step: step.name)
    Logger.debug("starting async step #{step.name}")

    new_state =
      state
      |> launch_async_step(step)
      |> increment_step()

    {:continue, new_state}
  end

  defp execute_step(step, state) do
    Logger.metadata(run_id: state.run_id, step: step.name)
    Logger.debug("running step #{step.name}")

    case invoke_step(step, state) do
      {:ok, data} when is_map(data) ->
        new_state = handle_step_success(state, step, data)
        {:continue, new_state}

      {:suspend, info} when is_map(info) ->
        message = Map.get(info, :message)
        metadata = Map.get(info, :metadata, %{})
        context_updates = Map.get(info, :context_updates, %{})

        new_context =
          state.context
          |> Map.merge(context_updates)
          |> Map.delete(:human_input)

        new_state =
          state
          |> Map.put(:context, new_context)
          |> Map.put(:status, :waiting_for_human)
          |> Map.put(:waiting, %{
            step: step.name,
            message: message,
            metadata: metadata,
            resume_schema: step.resume_schema
          })
          |> push_history(%{step: step.name, status: :waiting, message: message})
          |> publish_event(%{event: :waiting_for_human, step: step.name, message: message})
          |> publish_event(%{event: :waiting_for_human, step: step.name})

        {:halt, new_state}

      {:error, reason} ->
        handle_step_error(step, reason, state)

      other ->
        handle_step_error(step, {:invalid_return, other}, state)
    end
  end

  defp invoke_step(step, state) do
    Task.async(fn -> run_step_fun(step, state.workflow, state.context) end)
    |> Task.await(:infinity)
  end

  defp handle_step_success(state, step, data) do
    state
    |> Map.update!(:context, fn ctx ->
      ctx
      |> Map.merge(data)
      |> Map.delete(:human_input)
    end)
    |> increment_step()
    |> push_history(%{step: step.name, status: :ok})
    |> publish_event(%{event: :step_completed, step: step.name})
  end

  defp increment_step(state) do
    Map.update!(state, :current_step_index, &(&1 + 1))
  end

  defp push_history(state, entry) do
    timestamped = Map.put(entry, :timestamp, DateTime.utc_now())
    Map.update!(state, :history, &[timestamped | &1])
  end

  defp publish_event(state, payload) do
    event =
      payload
      |> Map.put(:run_id, state.run_id)
      |> Map.put(:current_step, current_step_name(state))

    PubSub.broadcast(@pubsub, topic(state.run_id), {:synaptic_event, event})
    state
  end

  defp run_parallel_tasks(tasks, context) when is_list(tasks) do
    stream =
      Task.async_stream(tasks, &run_parallel_task(&1, context), timeout: :infinity, ordered: false)

    Enum.reduce_while(stream, {:ok, %{}}, fn
      {:ok, {:ok, data}}, {:ok, acc} when is_map(data) ->
        {:cont, {:ok, Map.merge(acc, data)}}

      {:ok, {:ok, invalid}}, _acc ->
        {:halt, {:error, {:invalid_parallel_task_return, {:ok, invalid}}}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:ok, other}, _acc ->
        {:halt, {:error, {:invalid_parallel_task_return, other}}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:parallel_task_crash, reason}}}
    end)
  end

  defp run_parallel_tasks(_tasks, _context), do: {:error, :invalid_parallel_tasks}

  defp run_parallel_task(fun, context) when is_function(fun, 1), do: fun.(context)
  defp run_parallel_task(fun, _context) when is_function(fun, 0), do: fun.()
  defp run_parallel_task(_other, _context), do: {:error, :invalid_parallel_task}

  defp async_pending?(state), do: map_size(state.async_tasks) > 0

  @impl true
  def handle_info({:async_step_result, pid, result}, state) do
    case Map.pop(state.async_tasks, pid) do
      {nil, _} ->
        {:noreply, state}

      {%{monitor_ref: ref, step: step}, async_tasks} ->
        Process.demonitor(ref, [:flush])

        new_state =
          state
          |> Map.put(:async_tasks, async_tasks)
          |> process_async_result(step, result)

        {:noreply, new_state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.async_tasks, pid) do
      nil ->
        {:noreply, state}

      %{monitor_ref: ^ref, step: step} ->
        if reason == :normal do
          {:noreply, state}
        else
          async_tasks = Map.delete(state.async_tasks, pid)

          new_state =
            state
            |> Map.put(:async_tasks, async_tasks)
            |> process_async_result(step, {:error, {:exit, reason}})

          {:noreply, new_state}
        end
    end
  end

  defp process_async_result(%{status: :running} = state, step, result) do
    handle_async_result(step, result, state)
  end

  defp process_async_result(state, _step, _result), do: state

  defp handle_async_result(step, {:ok, data}, state) when is_map(data) do
    state
    |> Map.update!(:context, fn ctx ->
      ctx
      |> Map.merge(data)
      |> Map.delete(:human_input)
    end)
    |> push_history(%{step: step.name, status: :ok, async: true})
    |> publish_event(%{event: :step_completed, step: step.name, async: true})
    |> maybe_mark_completed()
  end

  defp handle_async_result(step, {:error, reason}, state) do
    handle_async_failure(step, reason, state)
  end

  defp handle_async_result(step, other, state) do
    handle_async_failure(step, {:invalid_return, other}, state)
  end

  defp handle_async_failure(step, reason, state) do
    remaining = Map.get(state.retry_budget, step.name, 0)

    state =
      state
      |> push_history(%{
        step: step.name,
        status: :error,
        reason: reason,
        retries_remaining: remaining,
        async: true
      })
      |> publish_event(%{
        event: :step_error,
        step: step.name,
        reason: reason,
        retries_remaining: remaining,
        async: true
      })

    cond do
      remaining > 0 ->
        Logger.warning("retrying async step #{step.name}, #{remaining} retries remaining")

        state
        |> Map.update!(:retry_budget, &Map.put(&1, step.name, remaining - 1))
        |> publish_event(%{
          event: :retrying,
          step: step.name,
          retries_remaining: remaining - 1,
          reason: reason,
          async: true
        })
        |> launch_async_step(step)

      true ->
        Logger.error("async step #{step.name} failed permanently: #{inspect(reason)}")

        state
        |> Map.put(:status, :failed)
        |> Map.put(:last_error, reason)
        |> publish_event(%{event: :failed, step: step.name, reason: reason})
    end
  end

  defp maybe_mark_completed(state) do
    if state.status == :running and state.current_step_index >= length(state.steps) and
         not async_pending?(state) do
      state
      |> push_history(%{event: :completed})
      |> publish_event(%{event: :completed})
      |> Map.put(:status, :completed)
    else
      state
    end
  end

  defp launch_async_step(state, step) do
    parent = self()
    workflow = state.workflow
    context = state.context

    {:ok, pid} =
      Task.start(fn ->
        result = run_step_fun(step, workflow, context)
        send(parent, {:async_step_result, self(), result})
      end)

    ref = Process.monitor(pid)

    state
    |> Map.update!(:async_tasks, &Map.put(&1, pid, %{monitor_ref: ref, step: step}))
    |> push_history(%{step: step.name, status: :async_started, async: true})
    |> publish_event(%{event: :async_step_started, step: step.name})
  end

  defp topic(run_id), do: "synaptic:run:" <> run_id

  defp handle_step_error(step, reason, state) do
    remaining = Map.get(state.retry_budget, step.name, 0)

    state =
      state
      |> push_history(%{
        step: step.name,
        status: :error,
        reason: reason,
        retries_remaining: remaining
      })
      |> publish_event(%{
        event: :step_error,
        step: step.name,
        reason: reason,
        retries_remaining: remaining
      })

    cond do
      remaining > 0 ->
        Logger.warning("retrying step #{step.name}, #{remaining} retries remaining")

        new_state =
          state
          |> Map.update!(:retry_budget, &Map.put(&1, step.name, remaining - 1))
          |> Map.put(:last_error, reason)
          |> publish_event(%{
            event: :retrying,
            step: step.name,
            retries_remaining: remaining - 1,
            reason: reason
          })

        {:continue, new_state}

      true ->
        Logger.error("step #{step.name} failed permanently: #{inspect(reason)}")

        failed_state =
          state
          |> Map.put(:status, :failed)
          |> Map.put(:last_error, reason)
          |> publish_event(%{event: :failed, step: step.name, reason: reason})

        {:halt, failed_state}
    end
  end

  defp validate_resume_payload(state, payload) when is_map(payload) do
    schema =
      case Enum.at(state.steps, state.current_step_index) do
        %Step{} = step -> Map.get(step, :resume_schema, %{})
        _ -> %{}
      end

    missing =
      schema
      |> Enum.reject(fn {key, _type} -> Map.has_key?(payload, key) end)
      |> Enum.map(&elem(&1, 0))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      invalid_type?(schema, payload) ->
        {:error, :invalid_payload}

      true ->
        :ok
    end
  end

  defp validate_resume_payload(_state, _payload), do: {:error, :invalid_payload}

  defp invalid_type?(schema, payload) do
    Enum.any?(schema, fn {key, type} ->
      not matches_type?(Map.get(payload, key), type)
    end)
  end

  defp matches_type?(value, :string), do: is_binary(value)
  defp matches_type?(value, :boolean), do: is_boolean(value)
  defp matches_type?(value, :integer), do: is_integer(value)
  defp matches_type?(value, :float), do: is_float(value)
  defp matches_type?(value, :map), do: is_map(value)
  defp matches_type?(value, :binary), do: is_binary(value)
  defp matches_type?(_value, _type), do: true

  defp current_step_name(state) do
    case Enum.at(state.steps, state.current_step_index) do
      nil -> nil
      step -> step.name
    end
  end

  defp run_step_fun(step, workflow, context) do
    try do
      Step.run(step, workflow, context)
    catch
      kind, reason ->
        Logger.error("step #{step.name} crashed: #{inspect({kind, reason})}")
        {:error, {kind, reason}}
    end
  end
end
