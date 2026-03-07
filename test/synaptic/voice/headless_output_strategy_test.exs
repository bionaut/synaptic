defmodule Synaptic.Voice.HeadlessOutputStrategyTest do
  use ExUnit.Case

  alias Phoenix.PubSub

  defmodule WaitingWorkflow do
    use Synaptic.Workflow

    step :ask, suspend: true, resume_schema: %{answer: :string} do
      case get_in(context, [:human_input, :answer]) do
        nil -> suspend_for_human("Say something")
        answer -> {:ok, %{heard: answer}}
      end
    end

    commit()
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

    def init(owner), do: {:ok, owner}

    def handle_cast({:synthesize, text}, owner) do
      send(
        owner,
        {:synaptic_voice, :tts_chunk, "audio:" <> text,
         %{provider: :fake, content_type: "audio/mpeg", audio_format: "mp3"}}
      )

      {:noreply, owner}
    end

    def handle_cast(:flush, owner) do
      send(owner, {:synaptic_voice, :tts_done, %{provider: :fake}})
      {:noreply, owner}
    end

    def handle_cast(:cancel, owner) do
      send(owner, {:synaptic_voice, :tts_done, %{provider: :fake, canceled: true}})
      {:noreply, owner}
    end
  end

  defmodule FakeSTT do
    use GenServer
    @behaviour Synaptic.Voice.STTAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)
    def push_audio(pid, _audio_chunk, _opts), do: GenServer.cast(pid, :noop) && :ok
    def end_turn(pid, _opts), do: GenServer.cast(pid, :noop) && :ok

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner), do: {:ok, owner}
    def handle_cast(:noop, owner), do: {:noreply, owner}
  end

  test "provider-backed headless sessions synthesize once at stream_done by default" do
    assert_single_shot_provider(:openai, openai_tts_expectation())
    assert_single_shot_provider(:gemini, gemini_tts_expectation())
    assert_single_shot_provider(:eleven_labs, elevenlabs_tts_expectation())
  end

  test "custom adapter overrides stay on segmented fallback output" do
    {:ok, run_id} = Synaptic.start(WaitingWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    {:ok, %{session_id: session_id}} =
      Synaptic.Voice.attach_run(run_id,
        stt_adapter: FakeSTT,
        tts_adapter: FakeTTS,
        keep_alive: true,
        mode: :duplex
      )

    :ok = Synaptic.Voice.subscribe_session(session_id)

    on_exit(fn ->
      Synaptic.Voice.unsubscribe_session(session_id)
      :ok = Synaptic.Voice.stop_session(session_id, :normal)
      _ = Synaptic.stop(run_id, :test_cleanup)
    end)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "First sentence."}}
    )

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :assistant_audio_chunk,
                      data: %{audio_chunk: "audio:First sentence."}
                    }},
                   1_000

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_done}}
    )

    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_done}}, 1_000
  end

  defp assert_single_shot_provider(provider, expectation_fun) do
    bypass = Bypass.open()
    {:ok, run_id} = Synaptic.start(WaitingWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    assert {:ok, %{session_id: session_id}} =
             Synaptic.Voice.attach_run(run_id,
               provider: provider,
               mode: :duplex,
               keep_alive: true,
               provider_opts: provider_opts(provider, bypass.port)
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)

    on_exit(fn ->
      Synaptic.Voice.unsubscribe_session(session_id)
      :ok = Synaptic.Voice.stop_session(session_id, :normal)
      _ = Synaptic.stop(run_id, :test_cleanup)
    end)

    expectation_fun.(bypass)

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Hello "}}
    )

    assert_receive {:synaptic_voice_event,
                    %{event: :assistant_text_chunk, data: %{text: "Hello "}}},
                   1_000

    refute_receive {:synaptic_voice_event, %{event: :assistant_audio_chunk}}, 150

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "world."}}
    )

    assert_receive {:synaptic_voice_event,
                    %{event: :assistant_text_chunk, data: %{text: "world."}}},
                   1_000

    refute_receive {:synaptic_voice_event, %{event: :assistant_audio_chunk}}, 150

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_done}}
    )

    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_chunk}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :assistant_audio_done}}, 1_000

    session = Synaptic.Voice.inspect_session(session_id)
    assert session.engine_state.tts_strategy == :single_shot
    assert session.provider_capabilities.tts_mode == :single_shot
  end

  defp provider_opts(:openai, port) do
    [tts: [endpoint: "http://localhost:#{port}/tts", api_key: "test-key", finch: Synaptic.Finch]]
  end

  defp provider_opts(:gemini, port) do
    [tts: [endpoint: "http://localhost:#{port}/tts", api_key: "test-key", finch: Synaptic.Finch]]
  end

  defp provider_opts(:eleven_labs, port) do
    [
      tts: [
        endpoint: "http://localhost:#{port}/tts",
        api_key: "test-key",
        voice_id: "voice_123",
        finch: Synaptic.Finch
      ]
    ]
  end

  defp openai_tts_expectation do
    fn bypass ->
      Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "Hello world."
        Plug.Conn.resp(conn, 200, "audio-bytes")
      end)
    end
  end

  defp gemini_tts_expectation do
    fn bypass ->
      encoded = Base.encode64("audio-bytes")

      Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body =~ "Hello world."

        Plug.Conn.resp(
          conn,
          200,
          ~s({"candidates":[{"content":{"parts":[{"inlineData":{"data":"#{encoded}","mimeType":"audio/L16"}}]}}]})
        )
      end)
    end
  end

  defp elevenlabs_tts_expectation do
    fn bypass ->
      Bypass.expect_once(bypass, "POST", "/tts/voice_123", fn conn ->
        assert conn.query_string == "output_format=pcm_24000"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["text"] == "Hello world."
        Plug.Conn.resp(conn, 200, "audio-bytes")
      end)
    end
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
