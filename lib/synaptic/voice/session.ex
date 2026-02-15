defmodule Synaptic.Voice.Session do
  @moduledoc """
  GenServer managing one headless voice session bound to a Synaptic run.
  """

  use GenServer

  alias Phoenix.PubSub
  alias Synaptic.Voice.{Event, TextSegmenter}

  @type mode :: :duplex | :turn_based

  @type state :: %{
          session_id: String.t(),
          run_id: String.t(),
          mode: mode(),
          status: atom(),
          seq: non_neg_integer(),
          keep_alive: boolean(),
          end_turn_requested: boolean(),
          resume_mapper: (String.t(), map() -> map()),
          stt_adapter: module(),
          stt_pid: pid(),
          tts_adapter: module(),
          tts_pid: pid(),
          tts_buffer: String.t(),
          latest_partial: String.t() | nil,
          latest_final: String.t() | nil,
          turn_started_at: integer() | nil,
          latency: map()
        }

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
    GenServer.start_link(__MODULE__, opts, name: Synaptic.Voice.Registry.via(session_id))
  end

  def push_audio(session_id, audio_chunk, opts \\ []) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), {:push_audio, audio_chunk, opts})
  end

  def push_text(session_id, text, opts \\ []) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), {:push_text, text, opts})
  end

  def end_turn(session_id, opts \\ []) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), {:end_turn, opts})
  end

  def cancel_output(session_id) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), :cancel_output)
  end

  def stop_session(session_id, reason \\ :normal) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), {:stop_session, reason})
  end

  def inspect_session(session_id) do
    GenServer.call(Synaptic.Voice.Registry.via(session_id), :inspect_session)
  end

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    keep_alive = Keyword.get(opts, :keep_alive, false)

    mode =
      Keyword.get(opts, :voice_mode) ||
        Application.get_env(:synaptic, Synaptic.Voice, [])[:default_voice_mode] || :duplex

    stt_adapter =
      Keyword.get(opts, :stt_adapter) ||
        Application.get_env(:synaptic, Synaptic.Voice, [])[:stt_adapter] ||
        Synaptic.Voice.OpenAI.STTAdapter

    tts_adapter =
      Keyword.get(opts, :tts_adapter) ||
        Application.get_env(:synaptic, Synaptic.Voice, [])[:tts_adapter] ||
        Synaptic.Voice.OpenAI.TTSAdapter

    resume_mapper = Keyword.get(opts, :resume_mapper, &default_resume_mapper/2)

    with {:ok, stt_pid} <- stt_adapter.start_link(self(), Keyword.get(opts, :stt_opts, [])),
         {:ok, tts_pid} <- tts_adapter.start_link(self(), Keyword.get(opts, :tts_opts, [])) do
      :ok = PubSub.subscribe(Synaptic.PubSub, run_topic(run_id))

      now_ms = now_ms()

      state = %{
        session_id: session_id,
        run_id: run_id,
        mode: mode,
        status: :listening,
        seq: 0,
        keep_alive: keep_alive,
        end_turn_requested: false,
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

      :telemetry.execute(
        [:synaptic, :voice, :session, :start],
        %{},
        %{session_id: session_id, run_id: run_id, mode: mode}
      )

      {:ok, emit(state, :duplex_state_changed, %{status: :listening, mode: mode}) |> emit(:turn_started, %{})}
    end
  end

  @impl true
  def handle_call({:push_audio, audio_chunk, opts}, _from, state) when is_binary(audio_chunk) do
    state = maybe_interrupt_for_input(state)
    :ok = state.stt_adapter.push_audio(state.stt_pid, audio_chunk, opts)
    {:reply, :ok, state}
  end

  def handle_call({:push_text, text, _opts}, _from, state) when is_binary(text) do
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
    state = Map.put(state, :end_turn_requested, true)

    state =
      case state.latest_final do
        text when is_binary(text) and text != "" ->
          resume_with_text(state, text, opts)

        _ ->
          :ok = state.stt_adapter.end_turn(state.stt_pid, opts)
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(:cancel_output, _from, state) do
    :ok = state.tts_adapter.cancel_output(state.tts_pid)
    {:reply, :ok, emit(state, :duplex_interruption, %{reason: :cancel_output})}
  end

  def handle_call({:stop_session, reason}, _from, state) do
    {:stop, reason, :ok, state}
  end

  def handle_call(:inspect_session, _from, state) do
    payload =
      Map.take(state, [
        :session_id,
        :run_id,
        :mode,
        :status,
        :seq,
        :keep_alive,
        :latest_partial,
        :latest_final,
        :end_turn_requested,
        :latency
      ])

    {:reply, payload, state}
  end

  @impl true
  def handle_info({:synaptic_event, %{event: :stream_chunk, chunk: chunk}}, state)
      when is_binary(chunk) do
    state =
      state
      |> update_status(:speaking)
      |> mark_llm_latency()
      |> emit(:assistant_text_chunk, %{text: chunk})

    {segments, tts_buffer} = TextSegmenter.consume(state.tts_buffer, chunk)

    Enum.each(segments, fn segment ->
      :ok = state.tts_adapter.synthesize_segment(state.tts_pid, segment, [])
    end)

    {:noreply, %{state | tts_buffer: tts_buffer}}
  end

  def handle_info({:synaptic_event, %{event: :stream_done}}, state) do
    state = emit(state, :assistant_text_done, %{})

    state.tts_buffer
    |> TextSegmenter.flush()
    |> Enum.each(fn segment ->
      :ok = state.tts_adapter.synthesize_segment(state.tts_pid, segment, [])
    end)

    :ok = state.tts_adapter.flush(state.tts_pid, [])

    {:noreply, %{state | tts_buffer: ""}}
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human}}, state) do
    state =
      state
      |> update_status(:listening)
      |> emit(:duplex_state_changed, %{status: :listening, mode: state.mode})
      |> emit(:turn_started, %{})
      |> reset_turn_state()

    {:noreply, state}
  end

  def handle_info({:synaptic_event, %{event: event}}, state)
      when event in [:completed, :failed, :stopped] do
    if state.keep_alive do
      {:noreply, state}
    else
      {:stop, {:run_terminal, event}, state}
    end
  end

  def handle_info({:synaptic_voice, :stt_partial, text, _meta}, state) do
    state =
      state
      |> maybe_interrupt_for_input()
      |> Map.put(:latest_partial, text)
      |> mark_stt_latency()
      |> emit(:input_partial_text, %{text: text})

    :telemetry.execute(
      [:synaptic, :voice, :stt, :partial],
      %{},
      %{session_id: state.session_id, run_id: state.run_id}
    )

    {:noreply, state}
  end

  def handle_info({:synaptic_voice, :stt_final, text, meta}, state) do
    trimmed = String.trim(text || "")

    if trimmed == "" do
      :telemetry.execute(
        [:synaptic, :voice, :stt, :error],
        %{},
        %{session_id: state.session_id, run_id: state.run_id, reason: :empty_transcript}
      )

      new_state =
        state
        |> Map.put(:latest_final, nil)
        |> Map.put(:end_turn_requested, false)
        |> update_status(:listening)
        |> emit(:duplex_state_changed, %{status: :listening, mode: state.mode})
        |> emit(:session_error, %{source: :stt, reason: :empty_transcript, meta: meta})

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
        %{session_id: state.session_id, run_id: state.run_id}
      )

      new_state =
        if new_state.end_turn_requested do
          resume_with_text(new_state, trimmed, [])
        else
          new_state
        end

      {:noreply, new_state}
    end
  end

  def handle_info({:synaptic_voice, :stt_error, reason}, state) do
    :telemetry.execute(
      [:synaptic, :voice, :stt, :error],
      %{},
      %{session_id: state.session_id, run_id: state.run_id, reason: reason}
    )

    new_state =
      state
      |> Map.put(:end_turn_requested, false)
      |> update_status(:listening)
      |> emit(:duplex_state_changed, %{status: :listening, mode: state.mode})
      |> emit(:session_error, %{source: :stt, reason: inspect(reason)})

    {:noreply, new_state}
  end

  def handle_info({:synaptic_voice, :tts_chunk, audio_chunk, meta}, state)
      when is_binary(audio_chunk) and is_map(meta) do
    state = mark_tts_latency(state)

    :telemetry.execute(
      [:synaptic, :voice, :tts, :chunk],
      %{bytes: byte_size(audio_chunk)},
      %{session_id: state.session_id, run_id: state.run_id}
    )

    data =
      meta
      |> Map.put(:audio_chunk, audio_chunk)
      |> Map.put_new(:audio_bytes, byte_size(audio_chunk))

    {:noreply, emit(state, :assistant_audio_chunk, data)}
  end

  def handle_info({:synaptic_voice, :tts_done, meta}, state) when is_map(meta) do
    :telemetry.execute(
      [:synaptic, :voice, :tts, :done],
      %{},
      %{session_id: state.session_id, run_id: state.run_id}
    )

    {:noreply, emit(state, :assistant_audio_done, meta)}
  end

  def handle_info({:synaptic_voice, :tts_error, reason}, state) do
    :telemetry.execute(
      [:synaptic, :voice, :tts, :error],
      %{},
      %{session_id: state.session_id, run_id: state.run_id, reason: reason}
    )

    {:noreply, emit(state, :session_error, %{source: :tts, reason: inspect(reason)})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    _ = safe_stop_adapter(state.stt_adapter, state.stt_pid, reason)
    _ = safe_stop_adapter(state.tts_adapter, state.tts_pid, reason)

    state =
      state
      |> maybe_record_turn_total()
      |> emit(:session_stopped, %{reason: inspect(reason)})

    :telemetry.execute(
      [:synaptic, :voice, :session, :stop],
      %{},
      %{session_id: state.session_id, run_id: state.run_id, reason: reason}
    )

    :ok
  end

  defp maybe_interrupt_for_input(%{mode: :duplex, status: :speaking} = state) do
    :ok = state.tts_adapter.cancel_output(state.tts_pid)

    :telemetry.execute(
      [:synaptic, :voice, :duplex, :interruption],
      %{},
      %{session_id: state.session_id, run_id: state.run_id}
    )

    state
    |> update_status(:duplex_overlap)
    |> emit(:duplex_interruption, %{reason: :user_input})
    |> update_status(:listening)
    |> emit(:duplex_state_changed, %{status: :listening, mode: :duplex})
  end

  defp maybe_interrupt_for_input(state), do: state

  defp resume_with_text(state, text, _opts) do
    payload = state.resume_mapper.(text, state)

    state =
      case Synaptic.resume(state.run_id, payload) do
        :ok ->
          state
          |> update_status(:thinking)
          |> emit(:duplex_state_changed, %{status: :thinking, mode: state.mode})
          |> Map.put(:end_turn_requested, false)

        {:error, reason} ->
          emit(state, :session_error, %{source: :resume, reason: inspect(reason)})
      end

    state
  end

  defp emit(state, event, data) do
    seq = state.seq + 1
    payload = Event.build(state.session_id, state.run_id, seq, event, data)

    if Event.valid?(payload) do
      PubSub.broadcast(Synaptic.PubSub, session_topic(state.session_id), {:synaptic_voice_event, payload})
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
    _ -> :ok
  end

  defp update_status(state, status), do: %{state | status: status}

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
      %{session_id: state.session_id, run_id: state.run_id}
    )

    %{state | latency: latency}
  end

  defp reset_turn_state(state) do
    %{state | latest_partial: nil, latest_final: nil, turn_started_at: now_ms()}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
