defmodule Synaptic.Voice.Sessions.Headless do
  @moduledoc false

  use GenServer
  require Logger

  alias Phoenix.PubSub
  alias Synaptic.Voice.{Event, SessionRegistry, TextSegmenter}
  alias Synaptic.Voice.Sessions.Headless.Lifecycle

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

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    keep_alive = Keyword.get(opts, :keep_alive, false)
    mode = Keyword.get(opts, :mode, :duplex)
    provider_modules = Keyword.fetch!(opts, :provider_modules)
    stack = Keyword.fetch!(opts, :stack)
    stack_opts = Keyword.get(opts, :stack_opts, %{})
    resume_mapper = Keyword.get(opts, :resume_mapper, &default_resume_mapper/2)

    stt_adapter = provider_modules.stt
    tts_adapter = provider_modules.tts
    stt_opts = provider_opts(stack_opts, :stt)
    tts_opts = provider_opts(stack_opts, :tts)

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
              transport: nil,
              status: :listening,
              seq: 0,
              keep_alive: keep_alive,
              end_turn_requested: false,
              waiting_for_human_pending: false,
              output_in_progress: false,
              playback_drain_pending: false,
              resume_mapper: resume_mapper,
              stt_adapter: stt_adapter,
              stt_pid: stt_pid,
              tts_adapter: tts_adapter,
              tts_pid: tts_pid,
              tts_buffer: "",
              latest_partial: nil,
              latest_final: nil,
              turn_started_at: now_ms,
              latency: %{
                stt_first_partial_ms: nil,
                llm_first_chunk_ms: nil,
                tts_first_chunk_ms: nil,
                turn_total_ms: nil
              }
            }

            telemetry_metadata = telemetry_metadata(state)

            :telemetry.execute(
              [:synaptic, :voice, :session, :start],
              %{},
              telemetry_metadata
            )

            log_flow(state, "init_session", %{mode: mode, stack: stack, keep_alive: keep_alive})

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
    state = maybe_interrupt_for_input(state)

    state =
      state
      |> Map.put(:latest_partial, text)
      |> Map.put(:latest_final, text)
      |> mark_stt_latency()
      |> emit(:input_final_text, %{text: text})

    {:reply, :ok, state}
  end

  def handle_call({:end_turn, opts}, _from, state) do
    log_flow(state, "end_turn_requested", %{
      opts: summarize_opts(opts),
      has_latest_final: is_binary(state.latest_final) and state.latest_final != "",
      status: state.status
    })

    state = Map.put(state, :end_turn_requested, true)

    state =
      case state.latest_final do
        text when is_binary(text) and text != "" ->
          log_flow(state, "end_turn_reuse_latest_final", %{chars: String.length(text)})
          resume_with_text(state, text, opts)

        _ ->
          log_flow(state, "end_turn_forward_to_stt", %{})
          :ok = state.stt_adapter.end_turn(state.stt_pid, opts)
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(:cancel_output, _from, state) do
    log_flow(state, "cancel_output", %{status: state.status})
    :ok = state.tts_adapter.cancel_output(state.tts_pid)

    state = apply_lifecycle_event(state, :cancel_output)

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
  def handle_info({:synaptic_event, %{event: :stream_chunk, chunk: chunk}}, state)
      when is_binary(chunk) do
    log_flow(state, "workflow_stream_chunk", %{chars: String.length(chunk)})

    state =
      state
      |> apply_lifecycle_event(:workflow_stream_chunk_started)
      |> mark_llm_latency()
      |> emit(:assistant_text_chunk, %{text: chunk})

    {segments, tts_buffer} = TextSegmenter.consume(state.tts_buffer, chunk)

    Enum.each(segments, fn segment ->
      :ok = state.tts_adapter.synthesize_segment(state.tts_pid, segment, [])
    end)

    {:noreply, %{state | tts_buffer: tts_buffer}}
  end

  def handle_info({:synaptic_event, %{event: :stream_done}}, state) do
    log_flow(state, "workflow_stream_done", %{tts_buffer_chars: String.length(state.tts_buffer)})

    state =
      state
      |> apply_lifecycle_event(:workflow_stream_done)
      |> emit(:assistant_text_done, %{})

    state.tts_buffer
    |> TextSegmenter.flush()
    |> Enum.each(fn segment ->
      :ok = state.tts_adapter.synthesize_segment(state.tts_pid, segment, [])
    end)

    :ok = state.tts_adapter.flush(state.tts_pid, [])

    {:noreply, %{state | tts_buffer: ""}}
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human}}, state) do
    log_flow(state, "workflow_waiting_for_human", %{status: state.status})

    state = apply_lifecycle_event(state, :workflow_waiting_for_human)

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
      new_state =
        state
        |> maybe_interrupt_for_input()
        |> Map.put(:latest_final, trimmed)
        |> emit(:input_final_text, %{text: trimmed})

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
        if should_resume do
          resume_with_text(new_state, trimmed, [])
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

  def handle_info({:synaptic_voice, :tts_chunk, audio_chunk, meta}, state)
      when is_binary(audio_chunk) and is_map(meta) do
    log_flow(state, "tts_chunk", %{bytes: byte_size(audio_chunk), meta: summarize_map(meta)})

    state = mark_tts_latency(state)

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
      transport: state.transport,
      latency: state.latency,
      engine_state: %{
        turn_phase: turn_phase(state),
        latest_partial: state.latest_partial,
        latest_final: state.latest_final,
        end_turn_requested: state.end_turn_requested,
        tts_buffer: state.tts_buffer,
        waiting_for_human_pending: state.waiting_for_human_pending,
        output_in_progress: state.output_in_progress,
        playback_drain_pending: state.playback_drain_pending
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
        |> clear_consumed_transcript()
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
        %{type: :transcription_failed, detail: normalize_error_reason(detail), meta: summarize_map(meta)}

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
    %{state | latest_partial: nil, latest_final: nil, turn_started_at: now_ms()}
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
      realtime_provider: state.stack.realtime
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
          end_turn_requested: state.end_turn_requested
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
