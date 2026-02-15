defmodule Synaptic.Voice.Realtime.Session do
  @moduledoc """
  GenServer that orchestrates realtime voice sessions with workflow-per-turn execution.
  """

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Synaptic.Voice.Event
  alias Synaptic.Voice.OpenAI.{RealtimeMapper, RealtimeSideband, WebRTCHelper}

  @default_timeout_ms 30_000

  @default_backchannel_phrases [
    "Got it. Let me check that now.",
    "Sure, I can look that up.",
    "Okay, give me a moment while I verify that."
  ]

  @type state :: %{
          session_id: String.t(),
          run_id: String.t(),
          status: atom(),
          seq: non_neg_integer(),
          keep_alive: boolean(),
          realtime: map(),
          model: String.t(),
          voice: String.t(),
          preferred_language: String.t(),
          sideband_adapter: module(),
          sideband_pid: pid(),
          cancel_on_interrupt: boolean(),
          workflow_timeout_ms: pos_integer(),
          backchannel_phrases: [String.t()],
          backchannel_enabled: boolean(),
          suppress_provider_responses_during_workflow: boolean(),
          current_task: %{task: Task.t(), input: String.t()} | nil,
          response_active: boolean(),
          last_final_input:
            %{item_id: String.t() | nil, text: String.t(), at_ms: integer()} | nil,
          telemetry_marks: map()
        }

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:synaptic_voice_realtime_session, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Synaptic.Voice.Realtime.Registry.via(session_id))
  end

  def stop_session(session_id, reason \\ :normal) do
    GenServer.call(Synaptic.Voice.Realtime.Registry.via(session_id), {:stop_session, reason})
  end

  def inspect_session(session_id) do
    GenServer.call(Synaptic.Voice.Realtime.Registry.via(session_id), :inspect_session)
  end

  def ingest_provider_event(session_id, payload) when is_map(payload) do
    GenServer.call(
      Synaptic.Voice.Realtime.Registry.via(session_id),
      {:ingest_provider_event, payload}
    )
  end

  def client_connected(session_id, meta \\ %{}) when is_map(meta) do
    GenServer.call(Synaptic.Voice.Realtime.Registry.via(session_id), {:client_connected, meta})
  end

  def client_disconnected(session_id, meta \\ %{}) when is_map(meta) do
    GenServer.call(Synaptic.Voice.Realtime.Registry.via(session_id), {:client_disconnected, meta})
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)

    config = Application.get_env(:synaptic, Synaptic.Voice.Realtime, [])

    model = Keyword.get(opts, :model, config[:model] || "gpt-4o-realtime-preview")
    voice = Keyword.get(opts, :voice, config[:voice] || "alloy")

    preferred_language =
      Keyword.get(opts, :preferred_language, config[:preferred_language] || "en")

    keep_alive = Keyword.get(opts, :keep_alive, false)

    cancel_on_interrupt =
      Keyword.get(opts, :cancel_on_interrupt, config[:cancel_on_interrupt] != false)

    workflow_timeout_ms =
      Keyword.get(opts, :workflow_timeout_ms, config[:workflow_timeout_ms] || @default_timeout_ms)

    backchannel_phrases =
      Keyword.get(
        opts,
        :backchannel_phrases,
        config[:backchannel_phrases] || @default_backchannel_phrases
      )

    backchannel_enabled =
      Keyword.get(opts, :backchannel_enabled, config[:backchannel_enabled] != false)

    suppress_provider_responses_during_workflow =
      Keyword.get(
        opts,
        :suppress_provider_responses_during_workflow,
        config[:suppress_provider_responses_during_workflow] != false
      )

    sideband_adapter =
      Keyword.get(opts, :sideband_adapter, config[:sideband_adapter] || RealtimeSideband)

    bootstrap_fun =
      Keyword.get(opts, :webrtc_bootstrap_fun, &WebRTCHelper.create_browser_bootstrap/1)

    bootstrap_opts =
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:voice, voice)
      |> Keyword.put_new(:transcription_language, preferred_language)

    with {:ok, realtime} <- bootstrap_fun.(bootstrap_opts),
         {:ok, sideband_pid} <-
           sideband_adapter.start_link(self(), session_id: session_id, run_id: run_id) do
      :ok = PubSub.subscribe(Synaptic.PubSub, run_topic(run_id))

      state = %{
        session_id: session_id,
        run_id: run_id,
        status: :connecting,
        seq: 0,
        keep_alive: keep_alive,
        realtime: realtime,
        model: model,
        voice: voice,
        preferred_language: preferred_language,
        sideband_adapter: sideband_adapter,
        sideband_pid: sideband_pid,
        cancel_on_interrupt: cancel_on_interrupt,
        workflow_timeout_ms: workflow_timeout_ms,
        backchannel_phrases: backchannel_phrases,
        backchannel_enabled: backchannel_enabled,
        suppress_provider_responses_during_workflow: suppress_provider_responses_during_workflow,
        current_task: nil,
        response_active: false,
        last_final_input: nil,
        telemetry_marks: %{}
      }

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :start],
        %{},
        %{session_id: session_id, run_id: run_id, model: model, voice: voice}
      )

      {:ok,
       state
       |> emit(:session_started, %{realtime: public_realtime(realtime)})
       |> emit(:duplex_state_changed, %{status: :connecting, mode: :duplex})}
    end
  end

  @impl true
  def handle_call(:inspect_session, _from, state) do
    payload =
      Map.take(state, [
        :session_id,
        :run_id,
        :status,
        :seq,
        :keep_alive,
        :model,
        :voice,
        :preferred_language,
        :cancel_on_interrupt,
        :workflow_timeout_ms,
        :response_active,
        :realtime
      ])

    {:reply, payload, state}
  end

  def handle_call({:client_connected, meta}, _from, state) do
    {:reply, :ok,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex, meta: meta})}
  end

  def handle_call({:client_disconnected, meta}, _from, state) do
    state = emit(state, :duplex_state_changed, %{status: :connecting, mode: :duplex, meta: meta})

    if state.keep_alive do
      {:reply, :ok, %{state | status: :connecting}}
    else
      {:stop, {:client_disconnected, meta}, :ok, state}
    end
  end

  def handle_call({:ingest_provider_event, payload}, _from, state) do
    :ok = state.sideband_adapter.ingest_provider_event(state.sideband_pid, payload)
    {:reply, :ok, state}
  end

  def handle_call({:stop_session, reason}, _from, state) do
    {:stop, reason, :ok, state}
  end

  @impl true
  def handle_info({:synaptic_voice_realtime_sideband, :provider_event, payload}, state) do
    {:noreply, process_provider_event(payload, state)}
  end

  def handle_info({:synaptic_voice_realtime_sideband, :outbound_event, event}, state) do
    {:noreply, emit(state, :provider_outbound, %{event: event})}
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human}}, state) do
    {:noreply,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})}
  end

  def handle_info({:synaptic_event, %{event: event}}, state)
      when event in [:completed, :failed, :stopped] do
    if state.keep_alive do
      {:noreply, state}
    else
      {:stop, {:run_terminal, event}, state}
    end
  end

  def handle_info({ref, result}, %{current_task: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_workflow_result(result, %{state | current_task: nil})}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_task: %{task: %Task{ref: ref}}} = state
      ) do
    if reason != :normal do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :workflow, :cancel],
        %{},
        %{session_id: state.session_id, run_id: state.run_id, reason: reason}
      )
    end

    {:noreply, %{state | current_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_inflight(state)
    _ = state.sideband_adapter.stop(state.sideband_pid, :shutdown)

    state
    |> emit(:session_stopped, %{reason: inspect(reason)})
    |> then(fn new_state ->
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :stop],
        %{},
        %{session_id: new_state.session_id, run_id: new_state.run_id, reason: reason}
      )
    end)

    :ok
  end

  defp process_provider_event(payload, state) do
    case RealtimeMapper.normalize_event(payload) do
      {:ok, %{event: :input_partial_text, data: %{text: text}}} ->
        state
        |> update_status(:listening)
        |> emit(:input_partial_text, %{text: text})

      {:ok, %{event: :input_final_text, data: data}} ->
        on_final_input(data, state)

      {:ok, %{event: :assistant_text_chunk, data: data}} ->
        if suppress_provider_response?(state) do
          state
        else
          log_assistant_chunk(state, data)

          state
          |> update_status(:speaking)
          |> emit(:assistant_text_chunk, data)
        end

      {:ok, %{event: :assistant_response_started, data: data}} ->
        if suppress_provider_response?(state) do
          _ = send_provider_event(state, %{"type" => "response.cancel"})

          state
          |> Map.put(:response_active, false)
          |> emit(:assistant_response_suppressed, %{reason: :workflow_in_progress})
        else
          state
          |> update_status(:speaking)
          |> Map.put(:response_active, true)
          |> emit(:assistant_response_started, data)
          |> emit(:duplex_state_changed, %{status: :speaking, mode: :duplex})
        end

      {:ok, %{event: :assistant_response_done, data: data}} ->
        if suppress_provider_response?(state) do
          state
        else
          state
          |> update_status(:listening)
          |> Map.put(:response_active, false)
          |> emit(:assistant_response_done, data)
          |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})
        end

      {:ok, %{event: :duplex_interruption, data: data}} ->
        state
        |> maybe_interrupt_response_only()
        |> emit(:duplex_interruption, data)
        |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})

      {:ok, %{event: :session_error, data: data}} ->
        log_provider_error(state, data)
        emit(state, :session_error, data)

      {:ignore, _} ->
        state
    end
  end

  defp on_final_input(%{text: text} = data, state) do
    trimmed = String.trim(text || "")
    item_id = Map.get(data, :item_id)

    if trimmed == "" do
      emit(state, :session_error, %{source: :stt, reason: :empty_transcript})
    else
      now_ms = System.monotonic_time(:millisecond)

      if duplicate_final_input?(state.last_final_input, item_id, trimmed, now_ms) do
        Logger.info(
          "[voice.realtime] input_final_duplicate_ignored session=#{state.session_id} run=#{state.run_id} item_id=#{inspect(item_id)}"
        )

        state
      else
        Logger.info(
          "[voice.realtime] input_final session=#{state.session_id} run=#{state.run_id} text=#{inspect(trimmed)}"
        )

        started_at = now_ms

        state =
          state
          |> Map.put(:last_final_input, %{item_id: item_id, text: trimmed, at_ms: now_ms})
          |> maybe_interrupt()
          |> update_status(:thinking)
          |> put_telemetry_mark(:user_final_at_ms, started_at)
          |> emit(:input_final_text, %{text: trimmed})
          |> emit(:duplex_state_changed, %{status: :thinking, mode: :duplex})

        state
        |> maybe_send_backchannel()
        |> start_workflow_task(trimmed)
      end
    end
  end

  defp on_final_input(_other, state), do: state

  defp duplicate_final_input?(nil, _item_id, _text, _now_ms), do: false

  defp duplicate_final_input?(%{item_id: prev_item_id}, item_id, _text, _now_ms)
       when is_binary(prev_item_id) and is_binary(item_id) and prev_item_id == item_id do
    true
  end

  defp duplicate_final_input?(%{text: prev_text, at_ms: prev_ms}, _item_id, text, now_ms) do
    prev_text == text and now_ms - prev_ms <= 2_000
  end

  defp maybe_interrupt(state) do
    if state.cancel_on_interrupt do
      state = cancel_inflight(state)

      if state.response_active do
        _ = send_provider_event(state, %{"type" => "response.cancel"})
      end

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        %{session_id: state.session_id, run_id: state.run_id}
      )

      emit(state, :duplex_interruption, %{reason: :cancel_and_restart})
    else
      state
    end
  end

  # Speech-start interruptions should stop active provider speech quickly, but
  # should not cancel the in-flight workflow until we receive finalized input.
  defp maybe_interrupt_response_only(state) do
    if state.cancel_on_interrupt do
      if state.response_active do
        _ = send_provider_event(state, %{"type" => "response.cancel"})
      end

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        %{session_id: state.session_id, run_id: state.run_id, scope: :response_only}
      )

      state
    else
      state
    end
  end

  defp maybe_send_backchannel(%{backchannel_enabled: false} = state), do: state
  defp maybe_send_backchannel(state), do: send_backchannel(state)

  defp send_backchannel(state) do
    phrase = choose_backchannel_phrase(state.backchannel_phrases)

    now_ms = System.monotonic_time(:millisecond)
    mark = Map.get(state.telemetry_marks, :user_final_at_ms)

    if is_integer(mark) do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :backchannel, :sent],
        %{user_final_to_backchannel_ms: max(now_ms - mark, 0)},
        %{session_id: state.session_id, run_id: state.run_id}
      )
    end

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "modalities" => ["audio", "text"],
          "max_output_tokens" => 64,
          "instructions" =>
            [
              "SERVER ORCHESTRATION MODE.",
              language_instruction(state),
              "This is a backchannel acknowledgement only.",
              "Do not answer the user's question.",
              "Say exactly this sentence and nothing else:",
              phrase
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> emit(:backchannel_sent, %{text: phrase})
    |> emit(:assistant_response_started, %{source: :backchannel})
  end

  defp start_workflow_task(state, input_text) do
    timeout_ms = state.workflow_timeout_ms
    run_id = state.run_id

    Logger.info(
      "[voice.realtime] workflow_start session=#{state.session_id} run=#{run_id} query=#{inspect(input_text)}"
    )

    :telemetry.execute(
      [:synaptic, :voice, :realtime, :workflow, :start],
      %{},
      %{session_id: state.session_id, run_id: run_id}
    )

    task =
      Task.async(fn ->
        run_workflow_turn(run_id, input_text, timeout_ms)
      end)

    state
    |> Map.put(:current_task, %{task: task, input: input_text})
    |> emit(:workflow_started, %{input: input_text})
  end

  defp handle_workflow_result({:ok, answer}, state) do
    Logger.info(
      "[voice.realtime] workflow_ok session=#{state.session_id} run=#{state.run_id} answer_chars=#{String.length(answer || "")}"
    )

    Logger.info(
      "[voice.realtime] workflow_answer session=#{state.session_id} run=#{state.run_id} preview=#{inspect(truncate_for_log(answer, 240))}"
    )

    now_ms = System.monotonic_time(:millisecond)
    mark = Map.get(state.telemetry_marks, :user_final_at_ms)

    if is_integer(mark) do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :workflow, :stop],
        %{user_final_to_assistant_start_ms: max(now_ms - mark, 0)},
        %{session_id: state.session_id, run_id: state.run_id}
      )
    end

    if state.response_active do
      _ = send_provider_event(state, %{"type" => "response.cancel"})
    end

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "modalities" => ["audio", "text"],
          "max_output_tokens" => 800,
          "instructions" =>
            [
              "SERVER ORCHESTRATION MODE.",
              language_instruction(state),
              "Read the answer below to the user.",
              "Keep factual details intact.",
              "Do not add disclaimers or unrelated caveats.",
              "ANSWER:",
              answer
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> emit(:assistant_response_started, %{source: :workflow})
    |> update_status(:speaking)
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :duplex})
  end

  defp handle_workflow_result({:error, reason}, state) do
    Logger.error(
      "[voice.realtime] workflow_error session=#{state.session_id} run=#{state.run_id} reason=#{inspect(reason)}"
    )

    state
    |> Map.put(:response_active, false)
    |> emit(:session_error, %{source: :workflow, reason: reason})
    |> update_status(:listening)
    |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})
  end

  defp run_workflow_turn(run_id, input_text, timeout_ms) do
    with :ok <- Synaptic.resume(run_id, %{human_input_text: input_text}),
         {:ok, snapshot} <- await_workflow_snapshot(run_id, timeout_ms) do
      assistant_answer = get_in(snapshot, [:context, :assistant_answer])

      if is_binary(assistant_answer) and String.trim(assistant_answer) != "" do
        {:ok, assistant_answer}
      else
        fallback = fallback_answer(snapshot, input_text)

        if is_binary(fallback) and String.trim(fallback) != "" do
          {:ok, fallback}
        else
          {:error, :missing_assistant_answer}
        end
      end
    end
  catch
    :exit, reason -> {:error, {:run_exit, reason}}
  end

  defp fallback_answer(snapshot, input_text) do
    github_summary = get_in(snapshot, [:context, :github_summary])

    cond do
      is_binary(github_summary) and String.trim(github_summary) != "" ->
        "I checked GitHub for your request '#{input_text}'. #{github_summary}"

      true ->
        nil
    end
  end

  defp await_workflow_snapshot(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_snapshot(run_id, deadline, 0)
  end

  defp do_await_snapshot(run_id, deadline_ms, attempts) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline_ms do
      {:error, :workflow_timeout}
    else
      case safe_inspect(run_id, 1_000) do
        {:ok, snapshot} ->
          case snapshot.status do
            status when status in [:waiting_for_human, :completed] ->
              {:ok, snapshot}

            :failed ->
              {:error, {:workflow_failed, snapshot.last_error}}

            :stopped ->
              {:error, {:workflow_stopped, snapshot.last_error}}

            _ ->
              Process.sleep(100)
              do_await_snapshot(run_id, deadline_ms, attempts + 1)
          end

        {:error, :busy_timeout} ->
          if rem(attempts + 1, 10) == 0 do
            Logger.info(
              "[voice.realtime] workflow_waiting session_run=#{run_id} reason=runner_busy attempts=#{attempts + 1}"
            )
          end

          Process.sleep(100)
          do_await_snapshot(run_id, deadline_ms, attempts + 1)

        {:error, reason} ->
          {:error, {:workflow_snapshot_error, reason}}
      end
    end
  end

  defp safe_inspect(run_id, timeout_ms) do
    {:ok, Synaptic.inspect(run_id, timeout_ms)}
  catch
    :exit, {:timeout, _} -> {:error, :busy_timeout}
    :exit, reason -> {:error, {:inspect_exit, reason}}
  end

  defp cancel_inflight(%{current_task: nil} = state), do: state

  defp cancel_inflight(%{current_task: %{task: task}} = state) do
    _ = Task.shutdown(task, :brutal_kill)

    :telemetry.execute(
      [:synaptic, :voice, :realtime, :workflow, :cancel],
      %{},
      %{session_id: state.session_id, run_id: state.run_id, reason: :interrupted}
    )

    state
    |> Map.put(:current_task, nil)
    |> emit(:workflow_canceled, %{reason: :interrupted})
  end

  defp send_provider_event(state, event) do
    state.sideband_adapter.send_event(state.sideband_pid, event)
  end

  defp update_status(state, status), do: %{state | status: status}

  defp put_telemetry_mark(state, key, value) do
    update_in(state.telemetry_marks, &Map.put(&1, key, value))
  end

  defp emit(state, name, data) do
    event = Event.build(state.session_id, state.run_id, state.seq + 1, name, data)

    PubSub.broadcast(
      Synaptic.PubSub,
      session_topic(state.session_id),
      {:synaptic_voice_realtime_event, event}
    )

    %{state | seq: state.seq + 1}
  end

  defp run_topic(run_id), do: "synaptic:run:" <> run_id
  defp session_topic(session_id), do: "synaptic:voice:realtime:session:" <> session_id

  defp public_realtime(realtime) when is_map(realtime) do
    Map.take(realtime, [:model, :voice, :session_id, :expires_at])
  end

  defp choose_backchannel_phrase([]), do: "One moment while I check that."
  defp choose_backchannel_phrase([single]), do: single
  defp choose_backchannel_phrase(phrases), do: Enum.random(phrases)

  defp language_instruction(%{preferred_language: "sk"}),
    do: "Speak only in Slovak (sk-SK)."

  defp language_instruction(%{preferred_language: "en"}),
    do: "Speak only in English (en-US)."

  defp language_instruction(%{preferred_language: code}) when is_binary(code),
    do: "Speak only in language code #{code}."

  defp log_provider_error(state, data) do
    Logger.error(
      "[voice.realtime] provider_error session=#{state.session_id} run=#{state.run_id} details=#{inspect(data, pretty: true, limit: 30)}"
    )
  end

  defp log_assistant_chunk(state, %{text: text}) when is_binary(text) do
    Logger.info(
      "[voice.realtime] assistant_chunk session=#{state.session_id} run=#{state.run_id} chars=#{String.length(text)} text=#{inspect(truncate_for_log(text, 240))}"
    )
  end

  defp log_assistant_chunk(_state, _data), do: :ok

  defp suppress_provider_response?(%{
         suppress_provider_responses_during_workflow: true,
         current_task: current_task
       })
       when not is_nil(current_task),
       do: true

  defp suppress_provider_response?(_state), do: false

  defp truncate_for_log(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end
end
