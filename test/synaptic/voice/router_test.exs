defmodule Synaptic.Voice.RouterTest do
  use ExUnit.Case, async: false

  alias Phoenix.PubSub

  defmodule SimpleWorkflow do
    use Synaptic.Workflow

    step :ask, suspend: true, resume_schema: %{human_input_text: :string} do
      case get_in(context, [:human_input, :human_input_text]) do
        text when is_binary(text) and text != "" ->
          {:ok, %{heard: text}}

        _ ->
          suspend_for_human("Say something")
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

    def push_audio(pid, _audio_chunk, _opts),
      do:
        (
          GenServer.cast(pid, :push_audio)
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

    def init(owner), do: {:ok, owner}

    def handle_cast(:push_audio, owner) do
      send(owner, {:synaptic_voice, :stt_partial, "partial", %{provider: :fake}})
      {:noreply, owner}
    end

    def handle_cast(:end_turn, owner) do
      send(owner, {:synaptic_voice, :stt_final, "hello from audio", %{provider: :fake}})
      {:noreply, owner}
    end
  end

  defmodule FakeTTS do
    use GenServer
    @behaviour Synaptic.Voice.TTSAdapter

    def start_link(owner, _opts), do: GenServer.start_link(__MODULE__, owner)

    def synthesize_segment(pid, text_segment, _opts),
      do:
        (
          GenServer.cast(pid, {:synthesize, text_segment})
          :ok
        )

    def flush(pid, _opts),
      do:
        (
          GenServer.cast(pid, :flush)
          :ok
        )

    def cancel_output(pid),
      do:
        (
          GenServer.cast(pid, :cancel)
          :ok
        )

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

  defmodule FakeGeminiLiveConnection do
    use GenServer

    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)
      GenServer.start_link(__MODULE__, owner)
    end

    def send_json(pid, payload) when is_map(payload) do
      GenServer.cast(pid, {:send_json, payload})
      :ok
    end

    def send_audio(pid, chunk, mime_type) do
      GenServer.cast(pid, {:send_audio, chunk, mime_type})
      :ok
    end

    def end_turn(pid) do
      GenServer.cast(pid, :end_turn)
      :ok
    end

    def cancel_output(pid) do
      GenServer.cast(pid, :cancel_output)
      :ok
    end

    def stop(pid, reason) do
      GenServer.stop(pid, reason)
      :ok
    catch
      :exit, _ -> :ok
    end

    def init(owner) do
      send(owner, {:gemini_live, :setup_complete})
      {:ok, owner}
    end

    def handle_cast(_msg, owner), do: {:noreply, owner}
  end

  test "start_session returns unified headless payload and normalized inspect state" do
    session_id = "session-started-headless"
    :ok = PubSub.subscribe(Synaptic.PubSub, "synaptic:voice:session:" <> session_id)

    on_exit(fn ->
      PubSub.unsubscribe(Synaptic.PubSub, "synaptic:voice:session:" <> session_id)
    end)

    assert {:ok,
            %{
              session_id: ^session_id,
              run_id: run_id,
              mode: :duplex,
              transport: nil,
              stack: stack
            }} =
             Synaptic.Voice.start_session(SimpleWorkflow, %{},
               mode: :duplex,
               session_id: session_id,
               stt_adapter: FakeSTT,
               tts_adapter: FakeTTS,
               keep_alive: true
             )

    assert stack == %{stt: :custom, tts: :custom, realtime: nil}

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :session_started,
                      data: %{mode: :duplex, transport: nil, stack: ^stack}
                    }},
                   1_000

    session = Synaptic.Voice.inspect_session(session_id)
    assert session.mode == :duplex
    assert session.stack == stack
    assert session.transport == nil
    assert session.engine_state.latest_partial == nil
    assert session.engine_state.tts_buffer == ""

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "headless sessions reject realtime-only operations" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(SimpleWorkflow, %{},
               mode: :duplex,
               stt_adapter: FakeSTT,
               tts_adapter: FakeTTS,
               keep_alive: true
             )

    assert {:error, :unsupported_for_mode} = Synaptic.Voice.client_connected(session_id)
    assert {:error, :unsupported_for_mode} = Synaptic.Voice.client_disconnected(session_id)

    assert {:error, :unsupported_for_mode} =
             Synaptic.Voice.ingest_provider_event(session_id, %{"type" => "x"})

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "realtime sessions reject headless-only operations" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(SimpleWorkflow, %{},
               mode: :realtime,
               webrtc_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: "gpt-4o-realtime-preview",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    assert {:error, :unsupported_for_mode} = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)
    assert {:error, :unsupported_for_mode} = Synaptic.Voice.push_text(session_id, "hello")
    assert {:error, :unsupported_for_mode} = Synaptic.Voice.end_turn(session_id)
    assert {:error, :unsupported_for_mode} = Synaptic.Voice.cancel_output(session_id)

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "router rejects public stack without escape hatch" do
    assert {:error, {:unsupported_mode_stack, :duplex, [tts: {:gemini, []}]}} =
             Synaptic.Voice.attach_run("run:test", mode: :duplex, stack: [tts: {:gemini, []}])
  end

  test "router validates custom stack shape with escape hatch" do
    assert {:error, {:missing_role, :stt}} =
             Synaptic.Voice.attach_run("run:test",
               mode: :duplex,
               _allow_custom_stack: true,
               stack: [tts: {:gemini, []}]
             )

    assert {:error, {:unknown_provider, :unknown}} =
             Synaptic.Voice.attach_run("run:test",
               mode: :duplex,
               _allow_custom_stack: true,
               stack: [stt: {:unknown, []}, tts: {:gemini, []}]
             )

    assert {:error, {:unsupported_mode_stack, :realtime, _stack}} =
             Synaptic.Voice.attach_run("run:test",
               mode: :realtime,
               _allow_custom_stack: true,
               stack: [realtime: {:openai, []}, tts: {:gemini, []}]
             )
  end

  test "unknown provider fails before child start" do
    assert {:error, {:unknown_provider, :unknown}} =
             Synaptic.Voice.attach_run("run:test", mode: :duplex, provider: :unknown)
  end

  test "router resolves pure gemini headless bundle by provider" do
    {:ok, run_id} = Synaptic.start(SimpleWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    assert {:ok, %{session_id: session_id, stack: %{stt: :gemini, tts: :gemini, realtime: nil}}} =
             Synaptic.Voice.attach_run(run_id,
               provider: :gemini,
               mode: :duplex,
               keep_alive: true
             )

    session = Synaptic.Voice.inspect_session(session_id)
    assert session.provider_modules.stt == Synaptic.Voice.Providers.Gemini.STTAdapter
    assert session.provider_modules.tts == Synaptic.Voice.Providers.Gemini.TTSAdapter

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "router resolves pure gemini realtime bundle by provider" do
    assert {:ok,
            %{
              session_id: session_id,
              run_id: run_id,
              stack: %{realtime: :gemini},
              transport: transport
            }} =
             Synaptic.Voice.start_session(SimpleWorkflow, %{},
               provider: :gemini,
               mode: :realtime,
               gemini_session_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    api_key: "test-key",
                    ws_endpoint: "wss://example.invalid/live",
                    setup_message: %{"setup" => %{}},
                    transport: %{
                      provider: :gemini,
                      model: "gemini-2.5-flash-native-audio-preview",
                      voice: "Kore",
                      audio_config: %{
                        input: %{mime_type: "audio/pcm;rate=16000"},
                        output: %{mime_type: "audio/pcm;rate=24000"}
                      }
                    }
                  }}
               end,
               gemini_live_connection: FakeGeminiLiveConnection
             )

    assert transport.provider == :gemini
    assert {:error, :unsupported_for_mode} = Synaptic.Voice.client_connected(session_id)
    assert :ok = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "custom stack works only with explicit escape hatch" do
    stt_bypass = Bypass.open()
    tts_bypass = Bypass.open()
    pcm_bytes = <<0, 1, 2, 3>>
    encoded_pcm = Base.encode64(pcm_bytes)

    Bypass.expect_once(stt_bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"text":"mixed provider transcript"}))
    end)

    Bypass.expect_once(tts_bypass, "POST", "/tts", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "responseModalities"

      Plug.Conn.resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"inlineData":{"data":"#{encoded_pcm}","mimeType":"audio/L16"}}]}}]})
      )
    end)

    {:ok, run_id} = Synaptic.start(SimpleWorkflow, %{})
    wait_for(run_id, :waiting_for_human)

    assert {:ok, %{session_id: session_id, stack: %{stt: :openai, tts: :gemini, realtime: nil}}} =
             Synaptic.Voice.attach_run(run_id,
               mode: :duplex,
               _allow_custom_stack: true,
               stack: [
                 stt:
                   {:openai,
                    [
                      endpoint: "http://localhost:#{stt_bypass.port}/stt",
                      api_key: "test-key",
                      finch: Synaptic.Finch
                    ]},
                 tts:
                   {:gemini,
                    [
                      endpoint: "http://localhost:#{tts_bypass.port}/tts",
                      api_key: "test-key",
                      finch: Synaptic.Finch
                    ]}
               ],
               keep_alive: true
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert :ok = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)
    assert :ok = Synaptic.Voice.end_turn(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :input_final_text, data: %{text: "mixed provider transcript"}}},
                   1_000

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_chunk, chunk: "Assistant response."}}
    )

    PubSub.broadcast(
      Synaptic.PubSub,
      "synaptic:run:" <> run_id,
      {:synaptic_event, %{event: :stream_done}}
    )

    assert_receive {:synaptic_voice_event,
                    %{
                      event: :assistant_audio_chunk,
                      data: %{
                        audio_chunk: ^pcm_bytes,
                        content_type: "audio/L16",
                        audio_format: %{sample_rate_hz: 24_000}
                      }
                    }},
                   1_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
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
