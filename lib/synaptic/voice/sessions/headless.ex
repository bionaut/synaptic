defmodule Synaptic.Voice.Sessions.Headless do
  @moduledoc false

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Synaptic.Voice.{Event, SessionRegistry, TurnAdmission}
  alias Synaptic.Voice.Headless.{ProviderCapabilities, Strategy}
  alias Synaptic.Voice.Sessions.Headless.{Lifecycle, Output}

  @type mode :: :duplex | :turn_based

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:synaptic_voice_session, session_id},
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

  def push_audio(pid, audio_chunk, opts \\ []),
    do: GenServer.call(pid, {:push_audio, audio_chunk, opts})

  def push_text(pid, text, opts \\ []), do: GenServer.call(pid, {:push_text, text, opts})
  def end_turn(pid, opts \\ []), do: GenServer.call(pid, {:end_turn, opts})
  def playback_drained(pid), do: GenServer.call(pid, :playback_drained)
  def cancel_output(pid), do: GenServer.call(pid, :cancel_output)
  def client_connected(_pid, _meta), do: {:error, :unsupported_for_mode}
  def client_disconnected(_pid, _meta), do: {:error, :unsupported_for_mode}
  def ingest_provider_event(_pid, _payload), do: {:error, :unsupported_for_mode}
  def approve_capability(_pid, _name), do: {:error, :unsupported_for_mode}

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    keep_alive = Keyword.get(opts, :keep_alive, false)
    mode = Keyword.get(opts, :mode, :duplex)
    provider_modules = Keyword.fetch!(opts, :provider_modules)

    provider_capabilities =
      Keyword.get(opts, :provider_capabilities, ProviderCapabilities.default())

    stack = Keyword.fetch!(opts, :stack)
    stack_opts = Keyword.get(opts, :stack_opts, %{})
    resume_mapper = Keyword.get(opts, :resume_mapper, &default_resume_mapper/2)
    turn_admission = Keyword.get(opts, :turn_admission)
    turn_admission_opts = Keyword.get(opts, :turn_admission_opts, [])

    stt_final_mode =
      Keyword.get(opts, :stt_final_mode, provider_capabilities.stt_final_mode)

    stt_adapter = provider_modules.stt
    tts_adapter = provider_modules.tts
    stt_opts = provider_opts(stack_opts, :stt)
    tts_opts = provider_opts(stack_opts, :tts)
    tts_strategy = Strategy.select_tts(provider_capabilities)

    case stt_adapter.start_link(self(), stt_opts) do
      {:ok, stt_pid} ->
        case tts_adapter.start_link(self(), tts_opts) do
          {:ok, tts_pid} ->
            :ok = PubSub.subscribe(Synaptic.PubSub, run_topic(run_id))

            now_ms = now_ms()

            state = %{
              session_id: session_id,
              run_id: run_id,
              mode: mode,
              stack: stack,
              provider_modules: provider_modules,
              provider_capabilities: provider_capabilities,
              transport: nil,
              status: :listening,
              seq: 0,
              keep_alive: keep_alive,
              end_turn_requested: false,
              waiting_for_human_pending: false,
              output_in_progress: false,
              playback_drain_pending: false,
              resume_mapper: resume_mapper,
              turn_admission: turn_admission,
              turn_admission_opts: turn_admission_opts,
              turn_admission_ref: nil,
              turn_admission_monitor_ref: nil,
              turn_admission_text: nil,
              pending_end_turn_opts: [],
              current_voice_turn_id: nil,
              end_turn_started_at: nil,
              stt_final_mode: stt_final_mode,
              stt_adapter: stt_adapter,
              stt_pid: stt_pid,
              tts_adapter: tts_adapter,
              tts_pid: tts_pid,
              tts_strategy: tts_strategy,
              output_state: Output.new(tts_strategy),
              tts_buffer: "",
              latest_partial: nil,
              latest_final: nil,
              current_prompt_message: waiting_prompt(run_id),
              turn_segments: [],
              last_turn_admission: nil,
              committed_turn_text: nil,
              turn_started_at: now_ms,
              latency: empty_latency()
            }

            telemetry_metadata = telemetry_metadata(state)

            :telemetry.execute(
              [:synaptic, :voice, :session, :start],
              %{},
              telemetry_metadata
            )

            log_flow(state, "init_session", %{
              mode: mode,
              stack: stack,
              keep_alive: keep_alive,
              tts_strategy: tts_strategy
            })

            {:ok,
             state
             |> emit(:session_started, %{mode: mode, stack: stack, transport: nil})
             |> execute_lifecycle_commands([
               {:set_status, :listening},
               {:emit_state_changed, :listening}
             ])
             |> emit(:turn_started, %{})}

          {:error, reason} ->
            _ = safe_stop_adapter(stt_adapter, stt_pid, {:startup_failed, :tts})
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:push_audio, audio_chunk, opts}, _from, state) when is_binary(audio_chunk) do
    log_flow(state, "push_audio", %{
      bytes: byte_size(audio_chunk),
      opts: summarize_opts(opts),
      status: state.status
    })

    state = maybe_interrupt_for_input(state)
    :ok = state.stt_adapter.push_audio(state.stt_pid, audio_chunk, opts)
    {:reply, :ok, state}
  end

  def handle_call({:push_text, text, _opts}, _from, state) when is_binary(text) do
    log_flow(state, "push_text", %{chars: String.length(text), status: state.status})
    state = record_final_transcript(state, text)

    {:reply, :ok, state}
  end

  def handle_call({:end_turn, opts}, _from, state) do
    voice_turn_id = Keyword.get(opts, :voice_turn_id)

    log_flow(state, "end_turn_requested", %{
      opts: summarize_opts(opts),
      has_latest_final: is_binary(state.latest_final) and state.latest_final != "",
      status: state.status
    })

    state =
      if end_turn_ignored?(state) do
        log_flow(state, "end_turn_ignored", %{status: state.status})
        state
      else
        state =
          state
          |> Map.put(:end_turn_requested, true)
          |> Map.put(:pending_end_turn_opts, opts)
          |> Map.put(:current_voice_turn_id, voice_turn_id)
          |> Map.put(:end_turn_started_at, now_ms())
          |> reset_finish_latency()

        case state.latest_final do
          text when is_binary(text) and text != "" ->
            log_flow(state, "end_turn_reuse_latest_final", %{chars: String.length(text)})
            start_turn_admission(state, text)

          _ ->
            log_flow(state, "end_turn_forward_to_stt", %{})
            :ok = state.stt_adapter.end_turn(state.stt_pid, opts)
            Map.put(state, :committed_turn_text, nil)
        end
      end

    {:reply, :ok, state}
  end

  def handle_call(:cancel_output, _from, state) do
    log_flow(state, "cancel_output", %{status: state.status})
    :ok = state.tts_adapter.cancel_output(state.tts_pid)

    state =
      state
      |> Map.update!(:output_state, &Output.cancel/1)
      |> then(fn new_state ->
        %{new_state | tts_buffer: Output.tts_buffer(new_state.output_state)}
      end)
      |> apply_lifecycle_event(:cancel_output)

    {:reply, :ok, state}
  end

  def handle_call(:playback_drained, _from, state) do
    log_flow(state, "playback_drained", %{})

    state = apply_lifecycle_event(state, :playback_drained)

    {:reply, :ok, state}
  end

  def handle_call({:stop_session, reason}, _from, state) do
    log_flow(state, "stop_session", %{reason: inspect(reason)})
    {:stop, reason, :ok, state}
  end

  def handle_call(:inspect_session, _from, state) do
    {:reply, public_state(state), state}
  end

  @impl true
  def handle_info({:synaptic_event, %{event: :stream_chunk, chunk: chunk} = event}, state)
      when is_binary(chunk) do
    log_flow(state, "workflow_stream_chunk", %{chars: String.length(chunk)})

    if Output.suppressed?(state.output_state) do
      {:noreply, state}
    else
      state =
        state
        |> mark_finish_latency(:first_text_ms)
        |> apply_lifecycle_event(:workflow_stream_chunk_started)
        |> mark_llm_latency()
        |> emit(:assistant_text_chunk, Map.put(stream_metadata(event), :text, chunk))

      synthesis_opts =
        event
        |> Map.get(:tts_opts, [])
        |> normalize_tts_opts()
        |> Keyword.put(:metadata, stream_metadata(event))

      {actions, output_state} = Output.consume_chunk(state.output_state, chunk, synthesis_opts)
      state = %{state | output_state: output_state, tts_buffer: Output.tts_buffer(output_state)}
      :ok = dispatch_output_actions(state, actions)

      {:noreply, state}
    end
  end

  def handle_info({:synaptic_event, %{event: :stream_done}}, state) do
    log_flow(state, "workflow_stream_done", %{tts_buffer_chars: String.length(state.tts_buffer)})

    if Output.suppressed?(state.output_state) do
      output_state = Output.reset_turn(state.output_state)

      {:noreply,
       %{state | output_state: output_state, tts_buffer: Output.tts_buffer(output_state)}}
    else
      state =
        state
        |> apply_lifecycle_event(:workflow_stream_done)
        |> emit(:assistant_text_done, %{})

      {actions, should_flush?, output_state} = Output.finalize(state.output_state)
      state = %{state | output_state: output_state, tts_buffer: Output.tts_buffer(output_state)}
      :ok = dispatch_output_actions(state, actions)

      if should_flush? do
        :ok = state.tts_adapter.flush(state.tts_pid, [])
      end

      {:noreply, state}
    end
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human} = event}, state) do
    log_flow(state, "workflow_waiting_for_human", %{status: state.status})

    state =
      state
      |> Map.put(
        :current_prompt_message,
        Map.get(event, :message) || state.current_prompt_message
      )
      |> apply_lifecycle_event(:workflow_waiting_for_human)

    {:noreply, state}
  end

  def handle_info({:synaptic_event, %{event: event}}, state)
      when event in [:completed, :failed, :stopped] do
    log_flow(state, "workflow_terminal_event", %{event: event, keep_alive: state.keep_alive})

    if state.keep_alive do
      {:noreply, state}
    else
      {:stop, {:run_terminal, event}, state}
    end
  end

  def handle_info({:synaptic_voice, :stt_partial, text, _meta}, state) do
    log_flow(state, "stt_partial", %{chars: String.length(text)})

    state =
      state
      |> maybe_interrupt_for_input()
      |> Map.put(:latest_partial, text)
      |> mark_stt_latency()
      |> emit(:input_partial_text, %{text: text})

    :telemetry.execute(
      [:synaptic, :voice, :stt, :partial],
      %{},
      telemetry_metadata(state)
    )

    {:noreply, state}
  end

  def handle_info({:synaptic_voice, :stt_final, text, meta}, state) do
    trimmed = String.trim(text || "")

    log_flow(state, "stt_final_received", %{
      chars: String.length(trimmed),
      meta: summarize_map(meta)
    })

    if trimmed == "" do
      :telemetry.execute(
        [:synaptic, :voice, :stt, :error],
        %{},
        Map.put(telemetry_metadata(state), :reason, :empty_transcript)
      )

      new_state =
        state
        |> apply_lifecycle_event({:stt_empty_final, meta})

      {:noreply, new_state}
    else
      new_state = record_final_transcript(state, trimmed)

      :telemetry.execute(
        [:synaptic, :voice, :stt, :final],
        %{},
        telemetry_metadata(state)
      )

      # In turn-based mode, STT final results are emitted only after an end-turn
      # request, but async ordering can clear the flag before this callback runs.
      # Resume defensively so the transcript is always processed.
      should_resume = new_state.end_turn_requested or state.mode == :turn_based

      new_state =
        if should_resume and is_binary(new_state.latest_final) and new_state.latest_final != "" do
          start_turn_admission(new_state, new_state.latest_final)
        else
          new_state
        end

      {:noreply, new_state}
    end
  end

  def handle_info({:synaptic_voice, :stt_error, reason}, state) do
    log_flow(state, "stt_error", %{reason: inspect(reason)})

    :telemetry.execute(
      [:synaptic, :voice, :stt, :error],
      %{},
      Map.put(telemetry_metadata(state), :reason, reason)
    )

    new_state =
      state
      |> apply_lifecycle_event({:stt_error, normalize_error_reason(reason)})

    {:noreply, new_state}
  end

  def handle_info({:turn_admission_result, ref, result}, %{turn_admission_ref: ref} = state) do
    {:noreply, apply_turn_admission_result(state, result)}
  end

  def handle_info({:turn_admission_result, _ref, _result}, state) do
    log_flow(state, "stale_turn_admission_result", %{})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %{turn_admission_monitor_ref: monitor_ref} = state
      ) do
    {:noreply, apply_turn_admission_result(state, {:error, {:policy_process_exit, reason}})}
  end

  def handle_info({:synaptic_voice, :tts_chunk, audio_chunk, meta}, state)
      when is_binary(audio_chunk) and is_map(meta) do
    log_flow(state, "tts_chunk", %{bytes: byte_size(audio_chunk), meta: summarize_map(meta)})

    state = state |> mark_finish_latency(:first_audio_ms) |> mark_tts_latency()

    :telemetry.execute(
      [:synaptic, :voice, :tts, :chunk],
      %{bytes: byte_size(audio_chunk)},
      telemetry_metadata(state)
    )

    data =
      meta
      |> Map.put(:audio_chunk, audio_chunk)
      |> Map.put_new(:audio_bytes, byte_size(audio_chunk))

    {:noreply, emit(state, :assistant_audio_chunk, data)}
  end

  def handle_info({:synaptic_voice, :tts_done, meta}, state) when is_map(meta) do
    log_flow(state, "tts_done", %{meta: summarize_map(meta)})

    :telemetry.execute(
      [:synaptic, :voice, :tts, :done],
      %{},
      telemetry_metadata(state)
    )

    state =
      state
      |> emit(:assistant_audio_done, meta)
      |> apply_lifecycle_event(:tts_done)

    {:noreply, state}
  end

  def handle_info({:synaptic_voice, :tts_error, reason}, state) do
    log_flow(state, "tts_error", %{reason: inspect(reason)})

    :telemetry.execute(
      [:synaptic, :voice, :tts, :error],
      %{},
      Map.put(telemetry_metadata(state), :reason, reason)
    )

    state =
      state
      |> apply_lifecycle_event({:tts_error, normalize_error_reason(reason)})

    {:noreply, state}
  end

  def handle_info(msg, state) do
    log_flow(state, "unknown_message", %{message_class: message_class(msg)})
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    log_flow(state, "terminate", %{reason: inspect(reason)})
    _ = safe_stop_adapter(state.stt_adapter, state.stt_pid, reason)
    _ = safe_stop_adapter(state.tts_adapter, state.tts_pid, reason)

    state =
      state
      |> maybe_record_turn_total()
      |> emit(:session_stopped, %{reason: inspect(reason)})

    :telemetry.execute(
      [:synaptic, :voice, :session, :stop],
      %{},
      Map.put(telemetry_metadata(state), :reason, reason)
    )

    :ok
  end

  defp provider_opts(stack_opts, role) do
    case Map.get(stack_opts, role) do
      {_provider, opts} -> opts
      _ -> []
    end
  end

  defp public_state(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: state.mode,
      status: state.status,
      seq: state.seq,
      stack: state.stack,
      provider_modules: Map.take(state.provider_modules, [:stt, :tts, :realtime]),
      provider_capabilities: state.provider_capabilities,
      transport: state.transport,
      latency: state.latency,
      engine_state: %{
        turn_phase: turn_phase(state),
        tts_strategy: state.tts_strategy,
        latest_partial: state.latest_partial,
        latest_final: state.latest_final,
        end_turn_requested: state.end_turn_requested,
        tts_buffer: state.tts_buffer,
        waiting_for_human_pending: state.waiting_for_human_pending,
        output_in_progress: state.output_in_progress,
        playback_drain_pending: state.playback_drain_pending,
        stt_final_mode: state.stt_final_mode,
        pending_end_turn_opts: state.pending_end_turn_opts,
        current_voice_turn_id: state.current_voice_turn_id,
        current_prompt_message: state.current_prompt_message,
        turn_segments: state.turn_segments,
        last_turn_admission: state.last_turn_admission,
        committed_turn_text: state.committed_turn_text,
        turn_admission_pending: not is_nil(state.turn_admission_ref),
        turn_admission_text: state.turn_admission_text
      }
    }
  end

  defp maybe_interrupt_for_input(%{mode: :duplex, status: :speaking} = state) do
    log_flow(state, "duplex_interrupt_for_input", %{status: state.status})
    :ok = state.tts_adapter.cancel_output(state.tts_pid)

    :telemetry.execute(
      [:synaptic, :voice, :duplex, :interruption],
      %{},
      telemetry_metadata(state)
    )

    state
    |> Map.update!(:output_state, &Output.cancel/1)
    |> then(fn new_state ->
      %{new_state | tts_buffer: Output.tts_buffer(new_state.output_state)}
    end)
    |> Map.put(:status, :duplex_overlap)
    |> emit(:duplex_interruption, %{reason: :user_input})
    |> Map.put(:status, :listening)
    |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})
  end

  defp maybe_interrupt_for_input(state), do: state

  defp resume_with_text(state, text, _opts) do
    log_flow(state, "resume_with_text", %{chars: String.length(text)})
    payload = state.resume_mapper.(text, state)

    case Synaptic.resume(state.run_id, payload) do
      :ok ->
        log_flow(state, "resume_ok", %{})

        state
        |> Map.put(:committed_turn_text, normalize_transcript(text))
        |> clear_consumed_transcript()
        |> clear_output_suppression()
        |> apply_lifecycle_event(:resume_ok)

      {:error, reason} ->
        log_flow(state, "resume_error", %{reason: inspect(reason)})

        state
        |> apply_lifecycle_event({:resume_error, normalize_error_reason(reason)})
    end
  end

  defp clear_consumed_transcript(state) do
    state
    |> Map.put(:latest_partial, nil)
    |> Map.put(:latest_final, nil)
    |> Map.put(:pending_end_turn_opts, [])
  end

  defp clear_output_suppression(state) do
    output_state = Output.reset_turn(state.output_state)
    %{state | output_state: output_state, tts_buffer: Output.tts_buffer(output_state)}
  end

  defp emit(state, event, data) do
    log_flow(state, "emit_event", %{event: event, data: summarize_map(data)})
    seq = state.seq + 1
    payload = Event.build(state.session_id, state.run_id, seq, event, data)

    if Event.valid?(payload) do
      PubSub.broadcast(
        Synaptic.PubSub,
        session_topic(state.session_id),
        {:synaptic_voice_event, payload}
      )
    else
      Logger.warning(
        "[voice.headless] invalid_event_dropped event=#{event} session_id=#{state.session_id} run_id=#{state.run_id}"
      )
    end

    %{state | seq: seq}
  end

  defp run_topic(run_id), do: "synaptic:run:" <> run_id
  defp session_topic(session_id), do: "synaptic:voice:session:" <> session_id

  defp default_resume_mapper(text, %{run_id: run_id}) do
    case Synaptic.inspect(run_id) do
      %{waiting: %{resume_schema: schema}} when is_map(schema) ->
        if Map.has_key?(schema, :answer) or Map.has_key?(schema, "answer") do
          %{answer: text}
        else
          %{human_input_text: text}
        end

      _ ->
        %{human_input_text: text}
    end
  end

  defp waiting_prompt(run_id) do
    case Synaptic.inspect(run_id) do
      %{waiting: %{message: message}} when is_binary(message) -> message
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp safe_stop_adapter(module, pid, reason) do
    module.stop(pid, reason)
  rescue
    error ->
      Logger.warning(
        "[voice.headless] safe_stop_adapter_failed module=#{inspect(module)} pid=#{inspect(pid)} reason=#{inspect(reason)} error=#{inspect(error)}"
      )

      :ok
  end

  defp turn_phase(state), do: Lifecycle.turn_phase(lifecycle_context(state))

  defp normalize_error_reason(reason) do
    case reason do
      :empty_transcript ->
        :empty_transcript

      {:empty_transcript, meta} ->
        %{type: :empty_transcript, meta: summarize_map(meta)}

      {:transcription_failed, detail, meta} ->
        %{
          type: :transcription_failed,
          detail: normalize_error_reason(detail),
          meta: summarize_map(meta)
        }

      {:upstream_error, status, _body} ->
        %{type: :upstream_error, status: status}

      {:run_terminal, event} ->
        %{type: :run_terminal, event: event}

      %{type: _} = normalized ->
        normalized

      other ->
        %{type: :unknown, detail: inspect(other)}
    end
  end

  defp mark_stt_latency(%{turn_started_at: nil} = state), do: state

  defp mark_stt_latency(state) do
    if state.latency.stt_first_partial_ms do
      state
    else
      ms = now_ms() - state.turn_started_at
      put_in(state, [:latency, :stt_first_partial_ms], ms)
    end
  end

  defp mark_llm_latency(%{turn_started_at: nil} = state), do: state

  defp mark_llm_latency(state) do
    if state.latency.llm_first_chunk_ms do
      state
    else
      ms = now_ms() - state.turn_started_at
      put_in(state, [:latency, :llm_first_chunk_ms], ms)
    end
  end

  defp mark_tts_latency(%{turn_started_at: nil} = state), do: state

  defp mark_tts_latency(state) do
    if state.latency.tts_first_chunk_ms do
      state
    else
      ms = now_ms() - state.turn_started_at
      put_in(state, [:latency, :tts_first_chunk_ms], ms)
    end
  end

  defp mark_finish_latency(%{end_turn_started_at: nil} = state, _key), do: state

  defp mark_finish_latency(state, key) do
    if Map.get(state.latency, key) do
      state
    else
      duration_ms = max(now_ms() - state.end_turn_started_at, 0)
      latency = Map.put(state.latency, key, duration_ms)

      :telemetry.execute(
        [:synaptic, :voice, :turn, :stage],
        %{duration_ms: duration_ms},
        Map.put(telemetry_metadata(state), :stage, key)
      )

      %{state | latency: latency}
    end
  end

  defp reset_finish_latency(state) do
    latency =
      state.latency
      |> Map.put(:stt_final_ms, nil)
      |> Map.put(:first_text_ms, nil)
      |> Map.put(:first_audio_ms, nil)

    %{state | latency: latency}
  end

  defp empty_latency do
    %{
      stt_first_partial_ms: nil,
      llm_first_chunk_ms: nil,
      tts_first_chunk_ms: nil,
      turn_total_ms: nil,
      stt_final_ms: nil,
      first_text_ms: nil,
      first_audio_ms: nil
    }
  end

  defp maybe_record_turn_total(%{turn_started_at: nil} = state), do: state

  defp maybe_record_turn_total(state) do
    total = now_ms() - state.turn_started_at
    latency = Map.put(state.latency, :turn_total_ms, total)

    :telemetry.execute(
      [:synaptic, :voice, :latency],
      latency,
      telemetry_metadata(state)
    )

    %{state | latency: latency}
  end

  defp reset_turn_state(state) do
    output_state = Output.reset_turn(state.output_state)

    %{
      state
      | latest_partial: nil,
        latest_final: nil,
        turn_segments: [],
        last_turn_admission: nil,
        turn_admission_ref: nil,
        turn_admission_monitor_ref: nil,
        turn_admission_text: nil,
        pending_end_turn_opts: [],
        current_voice_turn_id: nil,
        end_turn_started_at: nil,
        turn_started_at: now_ms(),
        latency: empty_latency(),
        output_state: output_state,
        tts_buffer: Output.tts_buffer(output_state)
    }
  end

  defp record_final_transcript(state, text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        state

      committed_turn_duplicate?(state, trimmed) ->
        log_flow(state, "stt_final_ignored_committed_duplicate", %{chars: String.length(trimmed)})
        state

      true ->
        state =
          state
          |> maybe_interrupt_for_input()
          |> append_turn_segment(trimmed)

        accumulated = accumulated_turn_text(state)

        state
        |> Map.put(:latest_partial, trimmed)
        |> Map.put(:latest_final, accumulated)
        |> mark_finish_latency(:stt_final_ms)
        |> mark_stt_latency()
        |> emit(:input_final_text, %{
          text: accumulated,
          latest_transcript: trimmed,
          pending_state: "candidate"
        })
    end
  end

  defp append_turn_segment(%{stt_final_mode: :segment} = state, text) do
    segments =
      if List.last(state.turn_segments) == text do
        state.turn_segments
      else
        state.turn_segments ++ [text]
      end

    %{state | turn_segments: segments}
  end

  defp append_turn_segment(%{stt_final_mode: :cumulative} = state, text) do
    current = accumulated_turn_text(state)

    segments =
      cond do
        current == "" -> [text]
        String.starts_with?(text, current) -> [text]
        String.starts_with?(current, text) -> state.turn_segments
        true -> [text]
      end

    %{state | turn_segments: segments}
  end

  defp append_turn_segment(state, text), do: %{state | turn_segments: [text]}

  defp accumulated_turn_text(%{stt_final_mode: :segment, turn_segments: segments}) do
    segments
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> String.trim()
  end

  defp accumulated_turn_text(%{turn_segments: segments}) do
    segments |> List.last() |> to_string() |> String.trim()
  end

  defp start_turn_admission(%{turn_admission_ref: ref} = state, _text) when not is_nil(ref),
    do: state

  defp start_turn_admission(state, text) when is_binary(text) do
    if is_nil(state.turn_admission) do
      commit_turn(state, text, %{})
    else
      ref = make_ref()
      owner = self()
      input = turn_admission_input(state, text)
      policy = state.turn_admission
      policy_opts = state.turn_admission_opts

      {_pid, monitor_ref} =
        spawn_monitor(fn ->
          send(
            owner,
            {:turn_admission_result, ref, TurnAdmission.evaluate(policy, input, policy_opts)}
          )
        end)

      state
      |> Map.put(:turn_admission_ref, ref)
      |> Map.put(:turn_admission_monitor_ref, monitor_ref)
      |> Map.put(:turn_admission_text, text)
      |> Map.put(:status, :evaluating_turn)
      |> emit(:turn_admission_started, %{
        text: text,
        transcript_count: length(state.turn_segments)
      })
      |> emit(:duplex_state_changed, %{status: :evaluating_turn, mode: state.mode})
    end
  end

  defp turn_admission_input(state, latest_text) do
    %{
      prompt: state.current_prompt_message,
      latest_transcript: state.latest_partial || latest_text,
      accumulated_transcript: accumulated_turn_text(state),
      transcript_count: length(state.turn_segments),
      end_turn_opts: state.pending_end_turn_opts
    }
  end

  defp apply_turn_admission_result(state, {:ok, :commit, metadata}) do
    text = state.turn_admission_text || state.latest_final || accumulated_turn_text(state)

    state
    |> clear_turn_admission_pending()
    |> Map.put(:last_turn_admission, %{action: :commit, metadata: metadata})
    |> emit(:turn_admission_decided, %{action: :commit, metadata: metadata})
    |> commit_turn(text, metadata)
  end

  defp apply_turn_admission_result(state, {:ok, :keep_listening, metadata}) do
    state
    |> clear_turn_admission_pending()
    |> Map.put(:pending_end_turn_opts, [])
    |> Map.put(:last_turn_admission, %{action: :keep_listening, metadata: metadata})
    |> emit(:turn_admission_decided, %{action: :keep_listening, metadata: metadata})
    |> apply_lifecycle_event(:hold_turn)
  end

  defp apply_turn_admission_result(state, {:error, reason}) do
    text = state.turn_admission_text || state.latest_final || accumulated_turn_text(state)

    state
    |> clear_turn_admission_pending()
    |> emit(:session_error, %{
      source: :turn_admission,
      reason: normalize_error_reason(reason),
      fallback: :commit
    })
    |> Map.put(:last_turn_admission, %{action: :commit, metadata: %{fallback: true}})
    |> emit(:turn_admission_decided, %{action: :commit, metadata: %{fallback: true}})
    |> commit_turn(text, %{fallback: true})
  end

  defp clear_turn_admission_pending(state) do
    if state.turn_admission_monitor_ref do
      Process.demonitor(state.turn_admission_monitor_ref, [:flush])
    end

    state
    |> Map.put(:turn_admission_ref, nil)
    |> Map.put(:turn_admission_monitor_ref, nil)
    |> Map.put(:turn_admission_text, nil)
  end

  defp commit_turn(state, text, _metadata),
    do: resume_with_text(state, text, state.pending_end_turn_opts)

  defp end_turn_ignored?(state) do
    state.status in [:thinking, :awaiting_playback_drain, :evaluating_turn]
  end

  defp committed_turn_duplicate?(state, text) do
    committed = state.committed_turn_text
    is_binary(committed) and committed != "" and committed == normalize_transcript(text)
  end

  defp normalize_transcript(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_transcript(_text), do: ""

  defp dispatch_output_actions(state, actions) do
    Enum.each(actions, fn
      {:synthesize, text, opts} ->
        :ok = state.tts_adapter.synthesize_segment(state.tts_pid, text, opts)
    end)

    :ok
  end

  defp normalize_tts_opts(opts) when is_list(opts), do: opts
  defp normalize_tts_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_tts_opts(_opts), do: []

  defp stream_metadata(event) do
    Map.take(event, [
      :speaker_id,
      :display_name,
      :voice_id,
      :gender,
      :voice_category,
      :voice_provider,
      :voice_label,
      :voice_turn_id
    ])
  end

  defp apply_lifecycle_event(state, event) do
    ctx = lifecycle_context(state)

    case Lifecycle.reduce(ctx, event) do
      {:ok, next_ctx, commands} ->
        state
        |> apply_lifecycle_context(next_ctx)
        |> execute_lifecycle_commands(commands)

      {:error, reason, _ctx, commands} ->
        Logger.debug(
          "[voice.headless] lifecycle_transition_error reason=#{inspect(reason)} event=#{inspect(event)} session_id=#{state.session_id}"
        )

        state
        |> execute_lifecycle_commands(commands)
    end
  end

  defp lifecycle_context(state) do
    %{
      status: state.status,
      mode: state.mode,
      end_turn_requested: state.end_turn_requested,
      waiting_for_human_pending: state.waiting_for_human_pending,
      output_in_progress: state.output_in_progress,
      playback_drain_pending: state.playback_drain_pending,
      latest_final: state.latest_final
    }
  end

  defp apply_lifecycle_context(state, ctx) do
    state
    |> Map.put(:status, ctx.status)
    |> Map.put(:end_turn_requested, ctx.end_turn_requested)
    |> Map.put(:waiting_for_human_pending, ctx.waiting_for_human_pending)
    |> Map.put(:output_in_progress, ctx.output_in_progress)
    |> Map.put(:playback_drain_pending, ctx.playback_drain_pending)
    |> Map.put(:latest_final, ctx.latest_final)
  end

  defp execute_lifecycle_commands(state, commands) do
    Enum.reduce(commands, state, fn command, acc ->
      case command do
        {:set_status, status} ->
          %{acc | status: status}

        {:clear_turn_flags} ->
          acc
          |> Map.put(:end_turn_requested, false)
          |> Map.put(:waiting_for_human_pending, false)
          |> Map.put(:output_in_progress, false)
          |> Map.put(:playback_drain_pending, false)

        {:emit, event, data} ->
          emit(acc, event, data)

        {:emit_state_changed, status} ->
          emit(acc, :duplex_state_changed, %{status: status, mode: acc.mode})

        {:reset_turn_state} ->
          reset_turn_state(acc)

        {:set_flag, key, value} ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp telemetry_metadata(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: state.mode,
      stt_provider: state.stack.stt,
      tts_provider: state.stack.tts,
      realtime_provider: state.stack.realtime,
      voice_turn_id: state.current_voice_turn_id
    }
  end

  defp log_flow(state, event, details) do
    Logger.debug(fn ->
      summary =
        details
        |> Map.merge(%{
          event: event,
          session_id: state.session_id,
          run_id: state.run_id,
          status: state.status,
          turn_phase: turn_phase(state),
          waiting_for_human_pending: state.waiting_for_human_pending,
          output_in_progress: state.output_in_progress,
          playback_drain_pending: state.playback_drain_pending,
          end_turn_requested: state.end_turn_requested,
          voice_turn_id: state.current_voice_turn_id
        })
        |> inspect(limit: 60)

      "[voice.headless] #{summary}"
    end)
  end

  defp summarize_opts(opts) when is_list(opts) do
    opts
    |> Enum.map(fn
      {k, v} when is_binary(v) -> {k, summarize_binary(v)}
      {k, v} when is_map(v) -> {k, summarize_map(v)}
      pair -> pair
    end)
    |> Enum.into(%{})
  end

  defp summarize_opts(_), do: %{}

  defp summarize_map(map) when is_map(map) do
    map
    |> Enum.map(fn
      {k, v} when is_binary(v) -> {k, summarize_binary(v)}
      {k, v} when is_map(v) -> {k, summarize_map(v)}
      pair -> pair
    end)
    |> Enum.into(%{})
  end

  defp summarize_map(_), do: %{}

  defp summarize_binary(value) when is_binary(value) do
    # Keep logs safe and compact: avoid dumping potential base64/raw payloads.
    byte_count = byte_size(value)

    cond do
      String.valid?(value) and String.length(value) > 180 ->
        %{type: :string, chars: String.length(value)}

      String.valid?(value) ->
        value

      true ->
        %{type: :binary, bytes: byte_count}
    end
  rescue
    _ ->
      %{type: :binary, bytes: byte_size(value)}
  end

  defp summarize_binary(value) do
    if is_binary(value) do
      %{type: :binary, bytes: byte_size(value)}
    else
      value
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp message_class({tag, _payload}) when is_atom(tag), do: tag
  defp message_class({tag, _a, _b}) when is_atom(tag), do: tag
  defp message_class(%{event: event}) when is_atom(event), do: event
  defp message_class(message) when is_atom(message), do: message
  defp message_class(message) when is_tuple(message), do: :tuple
  defp message_class(message) when is_map(message), do: :map
  defp message_class(message) when is_binary(message), do: :binary
  defp message_class(_message), do: :unknown
end
