defmodule Synaptic.Voice.SessionTest do
  use ExUnit.Case

  alias Phoenix.PubSub

  defmodule VoiceWorkflow do
    use Synaptic.Workflow

    step :ask, suspend: true, resume_schema: %{answer: :string} do
      case get_in(context, [:human_input, :answer]) do
        nil -> suspend_for_human("Say something")
        answer -> {:ok, %{heard: answer}}
      end
    end

    step :finish do
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule MultiTurnWorkflow do
    use Synaptic.Workflow

    step :first_turn, suspend: true, resume_schema: %{answer: :string} do
      case get_in(context, [:human_input, :answer]) do
        nil -> suspend_for_human("Say the first thing")
        answer -> {:ok, %{first_heard: answer}}
      end
    end

    step :second_turn, suspend: true, resume_schema: %{answer: :string} do
      case get_in(context, [:human_input, :answer]) do
        nil -> suspend_for_human("Say the second thing")
        answer -> {:ok, %{second_heard: answer}}
      end
    end

    step :finish do
      {:ok, %{done: true}}
    end

    commit()
  end

  defmodule FakeSTT do
    use GenServer
    @behaviour Synaptic.Voice.STTAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

    def push_audio(pid, _audio_chunk, _opts) do
      GenServer.cast(pid, :push_audio)
      :ok
    end

    def end_turn(pid, _opts) do
      GenServer.cast(pid, {:end_turn, "from_audio"})
      :ok
    end

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner), do: {:ok, %{owner: owner}}

    def handle_cast(:push_audio, state) do
      send(state.owner, {:synaptic_voice, :stt_partial, "partial", %{provider: :fake}})
      {:noreply, state}
    end

    def handle_cast({:end_turn, text}, state) do
      send(state.owner, {:synaptic_voice, :stt_final, text, %{provider: :fake}})
      {:noreply, state}
    end
  end

  defmodule EmptyFinalSTT do
    use GenServer
    @behaviour Synaptic.Voice.STTAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

    def push_audio(pid, _audio_chunk, _opts),
      do:
        (
          GenServer.cast(pid, :noop)
          :ok
        )

    def end_turn(pid, _opts),
      do:
        (
          GenServer.cast(pid, :end_turn)
          :ok
        )

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner), do: {:ok, %{owner: owner}}
    def handle_cast(:noop, state), do: {:noreply, state}

    def handle_cast(:end_turn, state) do
      send(state.owner, {:synaptic_voice, :stt_final, "   ", %{provider: :fake}})
      {:noreply, state}
    end
  end

  defmodule FakeTTS do
    use GenServer
    @behaviour Synaptic.Voice.TTSAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

    def synthesize_segment(pid, text_segment, _opts) do
      GenServer.cast(pid, {:synthesize, text_segment})
      :ok
    end

    def flush(pid, _opts) do
      GenServer.cast(pid, :flush)
      :ok
    end

    def cancel_output(pid) do
      GenServer.cast(pid, :cancel)
      :ok
    end

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner), do: {:ok, %{owner: owner}}

    def handle_cast({:synthesize, text}, state) do
      send(
        state.owner,
        {:synaptic_voice, :tts_chunk, "audio:" <> text,
         %{provider: :fake, content_type: "audio/mpeg", audio_format: "mp3"}}
      )

      {:noreply, state}
    end

    def handle_cast(:flush, state) do
      send(state.owner, {:synaptic_voice, :tts_done, %{provider: :fake}})
      {:noreply, state}
    end

    def handle_cast(:cancel, state) do
      send(state.owner, {:synaptic_voice, :tts_done, %{provider: :fake, canceled: true}})
      {:noreply, state}
    end
  end

  defmodule ErroringTTS do
    use GenServer
    @behaviour Synaptic.Voice.TTSAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

    def synthesize_segment(pid, text_segment, _opts) do
      GenServer.cast(pid, {:synthesize, text_segment})
      :ok
    end

    def flush(pid, _opts) do
      GenServer.cast(pid, :flush)
      :ok
    end

    def cancel_output(pid) do
      GenServer.cast(pid, :cancel)
      :ok
    end

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner), do: {:ok, %{owner: owner}}

    def handle_cast({:synthesize, _text}, state) do
      send(state.owner, {:synaptic_voice, :tts_error, {:upstream_error, 500, "boom"}})
      {:noreply, state}
    end

    def handle_cast(:flush, state), do: {:noreply, state}

    def handle_cast(:cancel, state) do
      send(state.owner, {:synaptic_voice, :tts_done, %{provider: :fake, canceled: true}})
      {:noreply, state}
    end
  end

  test "session resumes workflow using transcript from push_text/end_turn" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "hello from voice")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    snapshot = wait_for(run_id, :completed)

    assert snapshot.context.heard == "hello from voice"
    assert snapshot.context.done

    assert_receive {:synaptic_voice_event,
                    %{event: :input_final_text, data: %{text: "hello from voice"}}},
                   1_000
  end

  test "end_turn consumes prior final transcript and ignores repeats while thinking" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "hello from voice")

    assert_receive {:synaptic_voice_event,
                    %{event: :input_final_text, data: %{text: "hello from voice"}}},
                   1_000

    assert :ok = Synaptic.Voice.end_turn(session_id)
    _snapshot = wait_for(run_id, :completed)

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.engine_state.latest_final == nil

    assert :ok = Synaptic.Voice.end_turn(session_id)

    refute_receive {:synaptic_voice_event,
                    %{event: :input_final_text, data: %{text: "from_audio"}}},
                   150

    assert Synaptic.Voice.inspect_session(session_id).engine_state.end_turn_requested == false
  end

  test "duplex mode emits interruption when user speaks during assistant audio" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :duplex
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Assistant speaking."}}
    )

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :assistant_audio_chunk,
                      data: %{content_type: "audio/mpeg", audio_format: "mp3", audio_bytes: bytes}
                    }},
                   1_000

    assert is_integer(bytes) and bytes > 0

    assert :ok = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)

    assert_receive {:synaptic_voice_event, %{event: :duplex_interruption}}, 1_000

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.status == :listening
  end

  test "duplex mode delays listening until client confirms playback drain" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :duplex
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Assistant speaking."}}
    )

    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_chunk}}, 1_000

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.status == :speaking

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :waiting_for_human}}
    )

    refute_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   150

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_done}}
    )

    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_done}}, 1_000

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :awaiting_playback_drain}}},
                   1_000

    refute_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   150

    assert :ok = Synaptic.Voice.playback_drained(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   1_000

    assert_receive {:synaptic_voice_event, %{event: :turn_started}}, 1_000
  end

  test "empty stt final does not resume workflow and emits session_error" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: EmptyFinalSTT,
        tts_adapter: FakeTTS,
        keep_alive: true
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)
    assert :ok = Synaptic.Voice.end_turn(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{reason: :empty_transcript}}},
                   1_000

    refute_receive {:synaptic_voice_event, %{event: :input_final_text}}, 100

    snapshot = Synaptic.inspect(run_id)
    assert snapshot.status == :waiting_for_human
  end

  test "turn_based resumes workflow on stt_final even without pending end_turn flag" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :turn_based
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert {:ok, pid, _metadata} = Synaptic.Voice.Router.lookup(session_id)

    send(pid, {:synaptic_voice, :stt_final, "late final transcript", %{provider: :fake}})

    assert_receive {:synaptic_voice_event,
                    %{event: :input_final_text, data: %{text: "late final transcript"}}},
                   1_000

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.heard == "late final transcript"
  end

  test "duplex tts_error clears pending output state and recovers to listening after playback drain" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: ErroringTTS,
        keep_alive: true,
        mode: :duplex
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Assistant speaking."}}
    )

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :waiting_for_human}}
    )

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :session_error,
                      data: %{source: :tts, reason: %{type: :upstream_error}}
                    }},
                   1_000

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :awaiting_playback_drain}}},
                   1_000

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.engine_state.output_in_progress == false
    assert session_snapshot.engine_state.playback_drain_pending == true

    assert :ok = Synaptic.Voice.playback_drained(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   1_000

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.engine_state.output_in_progress == false
    assert session_snapshot.engine_state.waiting_for_human_pending == false
    assert session_snapshot.engine_state.playback_drain_pending == false
  end

  test "resume error clears turn flags and recovers to listening" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        resume_mapper: fn _text, _state -> %{wrong_key: "bad"} end
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "hello from voice")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    assert_receive {:synaptic_voice_event, %{event: :session_error, data: %{source: :resume}}},
                   1_000

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   1_000

    session_snapshot = Synaptic.Voice.inspect_session(session_id)
    assert session_snapshot.engine_state.end_turn_requested == false
    assert session_snapshot.engine_state.waiting_for_human_pending == false
    assert session_snapshot.engine_state.output_in_progress == false
    assert session_snapshot.engine_state.playback_drain_pending == false

    snapshot = Synaptic.inspect(run_id)
    assert snapshot.status == :waiting_for_human
  end

  test "multi-turn duplex session resumes cleanly across consecutive turns" do
    {:ok, run_id} = Synaptic.start(MultiTurnWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "first")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    wait_for(run_id, :waiting_for_human)

    assert :ok = Synaptic.Voice.push_text(session_id, "second")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.first_heard == "first"
    assert snapshot.context.second_heard == "second"
    assert snapshot.context.done
  end

  test "turn admission receives preserved end_turn options without blocking the session" do
    parent = self()

    policy = fn input, opts ->
      send(parent, {:turn_admission_input, input, opts})
      Process.sleep(50)
      {:commit, %{source: :test}}
    end

    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        turn_admission: policy,
        turn_admission_opts: [policy: :test]
      )

    assert :ok = Synaptic.Voice.end_turn(session_id, manual_done: true)

    assert_receive {:turn_admission_input, input, [policy: :test]}, 1_000
    assert input.latest_transcript == "from_audio"
    assert input.accumulated_transcript == "from_audio"
    assert input.end_turn_opts == [manual_done: true]
    assert input.prompt == "Say something"

    assert Synaptic.Voice.inspect_session(session_id).status == :evaluating_turn

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.heard == "from_audio"
  end

  test "keep_listening accumulates segment finals before a later commit" do
    policy = fn input ->
      if input.transcript_count == 1 do
        {:keep_listening, %{reason: :incomplete}}
      else
        {:commit, %{reason: :complete}}
      end
    end

    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        turn_admission: policy
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "first")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :turn_admission_decided, data: %{action: :keep_listening}}},
                   1_000

    first_state = Synaptic.Voice.inspect_session(session_id)
    assert first_state.status == :listening
    assert first_state.engine_state.turn_segments == ["first"]

    assert :ok = Synaptic.Voice.push_text(session_id, "second")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.heard == "first second"
  end

  test "cumulative STT finals replace earlier hypotheses instead of duplicating them" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        stt_final_mode: :cumulative
      )

    assert {:ok, pid, _metadata} = Synaptic.Voice.Router.lookup(session_id)
    send(pid, {:synaptic_voice, :stt_final, "hello", %{provider: :fake}})
    send(pid, {:synaptic_voice, :stt_final, "hello world", %{provider: :fake}})

    assert :ok = Synaptic.Voice.end_turn(session_id)

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.heard == "hello world"
  end

  test "a repeated committed final is ignored" do
    parent = self()

    policy = fn input ->
      send(parent, {:admission_called, input.accumulated_transcript})
      :commit
    end

    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :turn_based,
        turn_admission: policy
      )

    assert {:ok, pid, _metadata} = Synaptic.Voice.Router.lookup(session_id)
    send(pid, {:synaptic_voice, :stt_final, "hello", %{provider: :fake}})

    assert_receive {:admission_called, "hello"}, 1_000
    wait_for(run_id, :completed)

    send(pid, {:synaptic_voice, :stt_final, "  hello  ", %{provider: :fake}})
    refute_receive {:admission_called, _text}, 150

    state = Synaptic.Voice.inspect_session(session_id)
    assert state.engine_state.committed_turn_text == "hello"
    assert state.engine_state.latest_final == nil
  end

  test "turn admission failures emit an error and safely fall back to commit" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        turn_admission: fn _input -> Process.exit(self(), :kill) end
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_text(session_id, "preserve this answer")
    assert :ok = Synaptic.Voice.end_turn(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :session_error, data: %{source: :turn_admission, fallback: :commit}}},
                   1_000

    snapshot = wait_for(run_id, :completed)
    assert snapshot.context.heard == "preserve this answer"
  end

  defp wait_for(run_id, target_status, attempts \\ 100)

  defp wait_for(_run_id, _target_status, 0), do: flunk("workflow did not reach expected status")

  defp wait_for(run_id, target_status, attempts) do
    snapshot = Synaptic.inspect(run_id)

    if snapshot.status == target_status do
      snapshot
    else
      Process.sleep(20)
      wait_for(run_id, target_status, attempts - 1)
    end
  end
end
