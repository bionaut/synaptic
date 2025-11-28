defmodule Synapse.Runner do
  @moduledoc false

  use GenServer
  require Logger

  alias Synapse.{Registry, Step}

  @type state :: %{
          run_id: String.t(),
          workflow: module(),
          steps: [Step.t()],
          current_step_index: non_neg_integer(),
          context: map(),
          status: :running | :waiting_for_human | :completed | :failed,
          waiting: map() | nil,
          history: list(map()),
          retry_budget: map(),
          last_error: term()
        }

  # Client API
  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {:synapse_runner, run_id},
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
      last_error: nil
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
  def handle_call({:resume, payload}, _from, %{status: :waiting_for_human} = state) do
    with :ok <- validate_resume_payload(state, payload) do
      new_state =
        state
        |> Map.put(:status, :running)
        |> Map.put(:waiting, nil)
        |> Map.update!(:context, &Map.put(&1, :human_input, payload))
        |> push_history(%{event: :resumed, payload: payload})

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
        if state.status == :running do
          new_state = push_history(state, %{event: :completed})
          {:halt, Map.put(new_state, :status, :completed)}
        else
          {:halt, state}
        end

      step ->
        execute_step(step, state)
    end
  end

  defp execute_step(step, state) do
    Logger.metadata(run_id: state.run_id, step: step.name)
    Logger.debug("running step #{step.name}")

    result =
      try do
        Task.async(fn -> Step.run(step, state.workflow, state.context) end)
        |> Task.await(:infinity)
      catch
        kind, reason ->
          Logger.error("step #{step.name} crashed: #{inspect({kind, reason})}")
          {:error, {kind, reason}}
      end

    case result do
      {:ok, data} when is_map(data) ->
        new_state =
          state
          |> Map.update!(:context, fn ctx ->
            ctx
            |> Map.merge(data)
            |> Map.delete(:human_input)
          end)
          |> increment_step()
          |> push_history(%{step: step.name, status: :ok})

        {:continue, new_state}

      {:suspend, info} when is_map(info) ->
        message = Map.get(info, :message)
        metadata = Map.get(info, :metadata, %{})

        new_state =
          state
          |> Map.put(:status, :waiting_for_human)
          |> Map.put(:waiting, %{
            step: step.name,
            message: message,
            metadata: metadata,
            resume_schema: step.resume_schema
          })
          |> push_history(%{step: step.name, status: :waiting, message: message})

        {:halt, new_state}

      {:error, reason} ->
        handle_step_error(step, reason, state)

      other ->
        handle_step_error(step, {:invalid_return, other}, state)
    end
  end

  defp increment_step(state) do
    Map.update!(state, :current_step_index, &(&1 + 1))
  end

  defp push_history(state, entry) do
    timestamped = Map.put(entry, :timestamp, DateTime.utc_now())
    Map.update!(state, :history, &[timestamped | &1])
  end

  defp handle_step_error(step, reason, state) do
    remaining = Map.get(state.retry_budget, step.name, 0)

    state =
      push_history(state, %{
        step: step.name,
        status: :error,
        reason: reason,
        retries_remaining: remaining
      })

    cond do
      remaining > 0 ->
        Logger.warning("retrying step #{step.name}, #{remaining} retries remaining")

        new_state =
          state
          |> Map.update!(:retry_budget, &Map.put(&1, step.name, remaining - 1))

        {:continue, new_state}

      true ->
        Logger.error("step #{step.name} failed permanently: #{inspect(reason)}")

        failed_state =
          state
          |> Map.put(:status, :failed)
          |> Map.put(:last_error, reason)

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
end
