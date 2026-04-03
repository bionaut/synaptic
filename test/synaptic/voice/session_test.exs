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

  test "session resumes workflow using transcript from push_text/end_turn" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, session_id} =
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

  test "duplex mode emits interruption when user speaks during assistant audio" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, session_id} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        voice_mode: :duplex
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

  test "empty stt final does not resume workflow and emits session_error" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, session_id} =
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

  test "start_session honors mode alias for classic sessions" do
    {:ok, session_id} =
      Synaptic.Voice.start_session(VoiceWorkflow, %{},
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :turn_based
      )

    session_snapshot = Synaptic.Voice.inspect_session(session_id)

    assert session_snapshot.mode == :turn_based
    assert is_binary(session_snapshot.run_id)

    assert :ok = Synaptic.Voice.stop_session(session_id, :test_cleanup)
    _ = Synaptic.stop(session_snapshot.run_id, :test_cleanup)
  end

  test "playback_drained moves duplex sessions back to listening" do
    {:ok, run_id} = Synaptic.start(VoiceWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, session_id} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        voice_mode: :duplex
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Assistant speaking."}}
    )

    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_chunk}}, 1_000
    assert Synaptic.Voice.inspect_session(session_id).status == :speaking

    assert :ok = Synaptic.Voice.playback_drained(session_id)

    assert Synaptic.Voice.inspect_session(session_id).status == :listening

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :duplex_state_changed,
                      data: %{source: :playback_drained, status: :listening}
                    }},
                   1_000
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
