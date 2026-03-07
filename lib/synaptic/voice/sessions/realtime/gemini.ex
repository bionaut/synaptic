defmodule Synaptic.Voice.Sessions.Realtime.Gemini do
  @moduledoc false

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Synaptic.Voice.{Event, SessionRegistry}
  alias Synaptic.Voice.Providers.Gemini.Live.{Connection, EventMapper, SessionBootstrap}

  @default_timeout_ms 30_000
  @default_input_mime_type "audio/pcm;rate=16000"
  @default_output_format %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}

  @default_backchannel_phrases [
    "Got it. Let me check that now.",
    "Sure, I can look that up.",
    "Okay, give me a moment while I verify that."
  ]

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:synaptic_voice_realtime_session_gemini, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    metadata = Keyword.get(opts, :registry_metadata, %{})
    GenServer.start_link(__MODULE__, opts, name: SessionRegistry.via(session_id, metadata))
  end

  def stop_session(pid, reason \\ :normal), do: GenServer.call(pid, {:stop_session, reason})
  def inspect_session(pid), do: GenServer.call(pid, :inspect_session)
  def push_audio(pid, chunk, opts \\ []), do: GenServer.call(pid, {:push_audio, chunk, opts})
  def push_text(pid, text, opts \\ []), do: GenServer.call(pid, {:push_text, text, opts})
  def end_turn(pid, opts \\ []), do: GenServer.call(pid, {:end_turn, opts})
  def cancel_output(pid), do: GenServer.call(pid, :cancel_output)
  def client_connected(_pid, _meta), do: {:error, :unsupported_for_mode}
  def client_disconnected(_pid, _meta), do: {:error, :unsupported_for_mode}
  def ingest_provider_event(_pid, _payload), do: {:error, :unsupported_for_mode}

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    provider_modules = Keyword.fetch!(opts, :provider_modules)
    stack = Keyword.fetch!(opts, :stack)
    stack_opts = Keyword.get(opts, :stack_opts, %{})

    config = Application.get_env(:synaptic, Synaptic.Voice.Providers.Gemini, [])
    realtime_opts = provider_opts(stack_opts, :realtime)

    model =
      Keyword.get(
        realtime_opts,
        :model,
        config[:live_model] || "gemini-2.5-flash-native-audio-preview"
      )

    voice = Keyword.get(realtime_opts, :voice, config[:live_voice] || config[:voice] || "Kore")

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

    bootstrap_fun =
      Keyword.get(opts, :gemini_session_bootstrap_fun, &SessionBootstrap.create_session_config/1)

    connection_adapter =
      Keyword.get(opts, :gemini_live_connection, config[:live_connection] || Connection)

    input_mime_type =
      Keyword.get(
        realtime_opts,
        :input_mime_type,
        config[:live_input_mime_type] || @default_input_mime_type
      )

    bootstrap_opts =
      realtime_opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:voice, voice)
      |> Keyword.put_new(:preferred_language, preferred_language)

    with {:ok, bootstrap} <- bootstrap_fun.(bootstrap_opts),
         {:ok, connection_pid} <-
           connection_adapter.start_link(
             owner: self(),
             api_key: bootstrap.api_key,
             ws_endpoint: bootstrap.ws_endpoint,
             setup_message: bootstrap.setup_message,
             input_mime_type: input_mime_type
           ) do
      Process.unlink(connection_pid)
      connection_ref = Process.monitor(connection_pid)
      :ok = PubSub.subscribe(Synaptic.PubSub, run_topic(run_id))

      state = %{
        session_id: session_id,
        run_id: run_id,
        mode: :realtime,
        stack: stack,
        provider_modules: provider_modules,
        status: :connecting,
        seq: 0,
        keep_alive: keep_alive,
        transport: bootstrap.transport,
        model: model,
        voice: voice,
        preferred_language: preferred_language,
        cancel_on_interrupt: cancel_on_interrupt,
        workflow_timeout_ms: workflow_timeout_ms,
        backchannel_phrases: backchannel_phrases,
        backchannel_enabled: backchannel_enabled,
        suppress_provider_responses_during_workflow: suppress_provider_responses_during_workflow,
        connection_adapter: connection_adapter,
        connection_pid: connection_pid,
        connection_ref: connection_ref,
        input_mime_type: input_mime_type,
        current_task: nil,
        response_active: false,
        manual_suppression: false,
        last_final_input: nil,
        telemetry_marks: %{},
        latency: %{}
      }

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :start],
        %{},
        telemetry_metadata(state)
      )

      {:ok,
       state
       |> emit(:session_started, %{mode: :realtime, stack: stack, transport: state.transport})
       |> emit(:duplex_state_changed, %{status: :connecting, mode: :realtime})}
    end
  end

  @impl true
  def handle_call(:inspect_session, _from, state), do: {:reply, public_state(state), state}

  def handle_call({:push_audio, chunk, opts}, _from, state) do
    mime_type = Keyword.get(opts, :mime_type, state.input_mime_type)
    :ok = state.connection_adapter.send_audio(state.connection_pid, chunk, mime_type)
    {:reply, :ok, state}
  end

  def handle_call({:push_text, text, _opts}, _from, state) do
    :ok = send_client_turn(state, text)
    {:reply, :ok, state}
  end

  def handle_call({:end_turn, _opts}, _from, state) do
    :ok = state.connection_adapter.end_turn(state.connection_pid)
    {:reply, :ok, state}
  end

  def handle_call(:cancel_output, _from, state) do
    :ok = state.connection_adapter.cancel_output(state.connection_pid)

    {:reply, :ok,
     state
     |> Map.put(:manual_suppression, true)
     |> Map.put(:response_active, false)
     |> emit(:assistant_response_suppressed, %{reason: :cancel_output})}
  end

  def handle_call({:stop_session, reason}, _from, state), do: {:stop, reason, :ok, state}

  @impl true
  def handle_info({:gemini_live, :setup_complete}, state) do
    {:noreply,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})}
  end

  def handle_info({:gemini_live, :decode_error, payload}, state) do
    {:noreply,
     emit(state, :session_error, %{source: :provider, reason: :decode_error, payload: payload})}
  end

  def handle_info({:gemini_live, :event, payload}, state) do
    {:noreply, process_provider_event(payload, state)}
  end

  def handle_info({:gemini_live, :disconnected, reason}, state) do
    new_state =
      state
      |> update_status(:connecting)
      |> emit(:session_error, %{
        source: :provider,
        reason: :disconnected,
        details: inspect(reason)
      })
      |> emit(:duplex_state_changed, %{status: :connecting, mode: :realtime})

    if state.keep_alive do
      {:noreply, new_state}
    else
      {:stop, {:provider_disconnected, reason}, new_state}
    end
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human}}, state) do
    {:noreply,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})}
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
        Map.put(telemetry_metadata(state), :reason, reason)
      )
    end

    {:noreply, %{state | current_task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connection_ref: ref} = state) do
    new_state =
      state
      |> update_status(:connecting)
      |> emit(:session_error, %{
        source: :provider,
        reason: :connection_down,
        details: inspect(reason)
      })
      |> emit(:duplex_state_changed, %{status: :connecting, mode: :realtime})

    if state.keep_alive do
      {:noreply, new_state}
    else
      {:stop, {:provider_connection_down, reason}, new_state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_inflight(state)
    _ = state.connection_adapter.stop(state.connection_pid, :shutdown)

    state
    |> emit(:session_stopped, %{reason: inspect(reason)})
    |> then(fn final_state ->
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :stop],
        %{},
        Map.put(telemetry_metadata(final_state), :reason, reason)
      )
    end)

    :ok
  end

  defp process_provider_event(payload, state) do
    case EventMapper.normalize_event(payload) do
      {:ok, %{event: :session_ready}} ->
        state
        |> update_status(:listening)
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})

      {:ok, %{event: :input_partial_text, data: %{text: text}}} ->
        state
        |> update_status(:listening)
        |> emit(:input_partial_text, %{text: text})

      {:ok, %{event: :input_final_text, data: data}} ->
        on_final_input(data, state)

      {:ok, %{event: :model_turn_parts, data: data}} ->
        process_model_turn_parts(data, state)

      {:ok, %{event: :assistant_response_done, data: data}} ->
        if suppress_provider_response?(state) do
          %{state | response_active: false}
        else
          state
          |> update_status(:listening)
          |> Map.put(:response_active, false)
          |> Map.put(:manual_suppression, false)
          |> emit(:assistant_response_done, data)
          |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
        end

      {:ok, %{event: :duplex_interruption, data: data}} ->
        state
        |> maybe_interrupt_response_only()
        |> emit(:duplex_interruption, data)
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})

      {:ok, %{event: :provider_outbound, data: data}} ->
        emit(state, :provider_outbound, data)

      {:ok, %{event: :session_error, data: data}} ->
        emit(state, :session_error, data)

      {:ignore, _} ->
        state
    end
  end

  defp process_model_turn_parts(
         %{parts: parts, turn_complete: turn_complete, interrupted: interrupted},
         state
       ) do
    {state, had_output} =
      Enum.reduce(parts, {state, false}, fn part, {acc, had_output} ->
        process_turn_part(part, acc, had_output)
      end)

    state =
      if interrupted do
        state
        |> Map.put(:response_active, false)
        |> update_status(:listening)
        |> emit(:duplex_interruption, %{reason: :speech_started})
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
      else
        state
      end

    if turn_complete do
      if suppress_provider_response?(state) do
        %{state | response_active: false, manual_suppression: false}
      else
        state
        |> Map.put(:response_active, false)
        |> Map.put(:manual_suppression, false)
        |> update_status(:listening)
        |> emit(:assistant_response_done, %{})
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
      end
    else
      if had_output and not suppress_provider_response?(state) do
        state
        |> Map.put(:response_active, true)
        |> update_status(:speaking)
      else
        state
      end
    end
  end

  defp process_turn_part(part, state, had_output) do
    if suppress_provider_response?(state) do
      if had_output do
        {state, true}
      else
        {emit(state, :assistant_response_suppressed, %{reason: suppression_reason(state)}), true}
      end
    else
      do_process_turn_part(part, state, had_output)
    end
  end

  defp do_process_turn_part({:text, text}, state, had_output) when is_binary(text) do
    state =
      maybe_emit_assistant_response_started(state)
      |> emit(:assistant_text_chunk, %{text: text})

    {state, had_output or text != ""}
  end

  defp do_process_turn_part({:audio, %{data: data, mime_type: mime_type}}, state, had_output)
       when is_binary(data) and is_binary(mime_type) do
    with {:ok, audio_chunk} <- Base.decode64(data) do
      meta = audio_meta(mime_type, audio_chunk)

      state =
        maybe_emit_assistant_response_started(state)
        |> emit(:assistant_audio_chunk, Map.put(meta, :audio_chunk, audio_chunk))

      {state, had_output or byte_size(audio_chunk) > 0}
    else
      _ ->
        {state, had_output}
    end
  end

  defp do_process_turn_part(_part, state, had_output), do: {state, had_output}

  defp on_final_input(%{text: text}, state) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      emit(state, :session_error, %{source: :stt, reason: :empty_transcript})
    else
      now_ms = System.monotonic_time(:millisecond)

      if duplicate_final_input?(state.last_final_input, trimmed, now_ms) do
        state
      else
        state =
          state
          |> Map.put(:last_final_input, %{text: trimmed, at_ms: now_ms})
          |> maybe_interrupt()
          |> update_status(:thinking)
          |> put_telemetry_mark(:user_final_at_ms, now_ms)
          |> emit(:input_final_text, %{text: trimmed})
          |> emit(:duplex_state_changed, %{status: :thinking, mode: :realtime})

        state
        |> maybe_send_backchannel()
        |> start_workflow_task(trimmed)
      end
    end
  end

  defp on_final_input(_data, state), do: state

  defp maybe_interrupt(state) do
    if state.cancel_on_interrupt do
      state = cancel_inflight(state)

      state =
        if state.response_active do
          state
          |> Map.put(:manual_suppression, true)
          |> Map.put(:response_active, false)
          |> emit(:assistant_response_suppressed, %{reason: :interrupted})
        else
          state
        end

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        telemetry_metadata(state)
      )

      emit(state, :duplex_interruption, %{reason: :cancel_and_restart})
    else
      state
    end
  end

  defp maybe_interrupt_response_only(state) do
    if state.cancel_on_interrupt and state.response_active do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        Map.put(telemetry_metadata(state), :scope, :response_only)
      )

      state
      |> Map.put(:manual_suppression, true)
      |> Map.put(:response_active, false)
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
        telemetry_metadata(state)
      )
    end

    text =
      [
        "SERVER ORCHESTRATION MODE.",
        language_instruction(state),
        "This is a backchannel acknowledgement only.",
        "Do not answer the user's question.",
        "Say exactly this sentence and nothing else:",
        phrase
      ]
      |> Enum.join("\n")

    _ = send_client_turn(state, text)

    state
    |> Map.put(:response_active, true)
    |> emit(:backchannel_sent, %{text: phrase})
    |> emit(:assistant_response_started, %{source: :backchannel})
  end

  defp start_workflow_task(state, input_text) do
    timeout_ms = state.workflow_timeout_ms
    run_id = state.run_id

    :telemetry.execute(
      [:synaptic, :voice, :realtime, :workflow, :start],
      %{},
      telemetry_metadata(state)
    )

    task = Task.async(fn -> run_workflow_turn(run_id, input_text, timeout_ms) end)

    state
    |> Map.put(:manual_suppression, state.suppress_provider_responses_during_workflow)
    |> Map.put(:current_task, %{task: task, input: input_text})
    |> emit(:workflow_started, %{input: input_text})
  end

  defp handle_workflow_result({:ok, answer}, state) do
    now_ms = System.monotonic_time(:millisecond)
    mark = Map.get(state.telemetry_marks, :user_final_at_ms)

    if is_integer(mark) do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :workflow, :stop],
        %{user_final_to_assistant_start_ms: max(now_ms - mark, 0)},
        telemetry_metadata(state)
      )
    end

    text =
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

    _ = send_client_turn(state, text)

    state
    |> Map.put(:manual_suppression, false)
    |> Map.put(:response_active, true)
    |> emit(:assistant_response_started, %{source: :workflow})
    |> update_status(:speaking)
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp handle_workflow_result({:error, reason}, state) do
    state
    |> Map.put(:response_active, false)
    |> Map.put(:manual_suppression, false)
    |> emit(:session_error, %{source: :workflow, reason: reason})
    |> update_status(:listening)
    |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
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

  defp fallback_answer(snapshot, _input_text) do
    Enum.find_value([:answer, :response, :reply], fn key ->
      value = get_in(snapshot, [:context, key])

      if is_binary(value) and String.trim(value) != "" do
        value
      end
    end)
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
            Logger.debug(
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
      Map.put(telemetry_metadata(state), :reason, :interrupted)
    )

    state
    |> Map.put(:current_task, nil)
    |> emit(:workflow_canceled, %{reason: :interrupted})
  end

  defp maybe_emit_assistant_response_started(%{response_active: true} = state), do: state

  defp maybe_emit_assistant_response_started(state) do
    state
    |> Map.put(:response_active, true)
    |> update_status(:speaking)
    |> emit(:assistant_response_started, %{source: :provider})
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp suppression_reason(%{
         current_task: task,
         suppress_provider_responses_during_workflow: true
       })
       when not is_nil(task),
       do: :workflow_in_progress

  defp suppression_reason(%{manual_suppression: true}), do: :manual
  defp suppression_reason(_), do: :unknown

  defp suppress_provider_response?(%{
         manual_suppression: true
       }),
       do: true

  defp suppress_provider_response?(%{
         suppress_provider_responses_during_workflow: true,
         current_task: current_task
       })
       when not is_nil(current_task),
       do: true

  defp suppress_provider_response?(_), do: false

  defp duplicate_final_input?(nil, _text, _now_ms), do: false

  defp duplicate_final_input?(%{text: prev_text, at_ms: prev_ms}, text, now_ms) do
    prev_text == text and now_ms - prev_ms <= 2_000
  end

  defp send_client_turn(state, text) when is_binary(text) do
    payload = %{
      "clientContent" => %{
        "turns" => [
          %{
            "role" => "user",
            "parts" => [%{"text" => text}]
          }
        ],
        "turnComplete" => true
      }
    }

    state.connection_adapter.send_json(state.connection_pid, payload)
  end

  defp provider_opts(stack_opts, role) do
    case Map.get(stack_opts, role) do
      {_provider, opts} -> opts
      _ -> []
    end
  end

  defp audio_meta(mime_type, audio_chunk) do
    rate = parse_rate_hz(mime_type) || @default_output_format.sample_rate_hz

    %{
      provider: :gemini,
      audio_bytes: byte_size(audio_chunk),
      audio_format: %{encoding: :pcm16le, sample_rate_hz: rate, channels: 1},
      content_type: "audio/L16"
    }
  end

  defp parse_rate_hz(mime_type) when is_binary(mime_type) do
    case Regex.run(~r/rate=(\d+)/, mime_type) do
      [_, value] ->
        case Integer.parse(value) do
          {rate, ""} -> rate
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_rate_hz(_), do: nil

  defp public_state(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: :realtime,
      status: state.status,
      seq: state.seq,
      stack: state.stack,
      provider_modules: Map.take(state.provider_modules, [:stt, :tts, :realtime]),
      transport: state.transport,
      latency: state.latency,
      engine_state: %{
        response_active: state.response_active,
        current_task_active: not is_nil(state.current_task),
        last_final_input: state.last_final_input,
        preferred_language: state.preferred_language
      }
    }
  end

  defp language_instruction(%{preferred_language: "sk"}),
    do: "Speak only in Slovak (sk-SK)."

  defp language_instruction(%{preferred_language: "en"}),
    do: "Speak only in English (en-US)."

  defp language_instruction(%{preferred_language: code}) when is_binary(code),
    do: "Speak only in language code #{code}."

  defp choose_backchannel_phrase([]), do: "One moment while I check that."
  defp choose_backchannel_phrase([single]), do: single
  defp choose_backchannel_phrase(phrases), do: Enum.random(phrases)

  defp update_status(state, status), do: %{state | status: status}

  defp put_telemetry_mark(state, key, value) do
    update_in(state.telemetry_marks, &Map.put(&1, key, value))
  end

  defp emit(state, name, data) do
    event = Event.build(state.session_id, state.run_id, state.seq + 1, name, data)

    PubSub.broadcast(
      Synaptic.PubSub,
      session_topic(state.session_id),
      {:synaptic_voice_event, event}
    )

    %{state | seq: state.seq + 1}
  end

  defp run_topic(run_id), do: "synaptic:run:" <> run_id
  defp session_topic(session_id), do: "synaptic:voice:session:" <> session_id

  defp telemetry_metadata(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: :realtime,
      stt_provider: nil,
      tts_provider: nil,
      realtime_provider: state.stack.realtime
    }
  end
end
