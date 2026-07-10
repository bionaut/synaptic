defmodule Synaptic.Voice.Realtime.GeminiSessionTest do
  use ExUnit.Case, async: false

  defmodule RealtimeWorkflow do
    use Synaptic.Workflow

    step :wait_for_query, suspend: true, resume_schema: %{human_input_text: :string} do
      case get_in(context, [:human_input, :human_input_text]) do
        text when is_binary(text) and text != "" ->
          {:ok, %{query: text}}

        _ ->
          suspend_for_human("Ask a question")
      end
    end

    step :compose do
      {:ok, %{assistant_answer: "Echo: #{context.query}"}}
    end

    step :loop, suspend: true, resume_schema: %{human_input_text: :string} do
      suspend_for_human("Ask another")
    end

    commit()
  end

  defmodule StartupWorkflow do
    use Synaptic.Workflow

    step :hold do
      Process.sleep(250)
      {:ok, %{ready: true}}
    end

    commit()
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

    def send_audio(pid, audio_chunk, mime_type)
        when is_binary(audio_chunk) and is_binary(mime_type) do
      GenServer.cast(pid, {:send_audio, audio_chunk, mime_type})
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

    def push_event(pid, payload) when is_map(payload) do
      GenServer.cast(pid, {:push_event, payload})
      :ok
    end

    def sent(pid), do: GenServer.call(pid, :sent)

    def init(owner) do
      send(owner, {:gemini_live, :setup_complete})
      {:ok, %{owner: owner, sent: []}}
    end

    def handle_call(:sent, _from, state) do
      {:reply, Enum.reverse(state.sent), state}
    end

    def handle_cast({:send_json, payload}, state) do
      {:noreply, %{state | sent: [{:json, payload} | state.sent]}}
    end

    def handle_cast({:send_audio, audio_chunk, mime_type}, state) do
      {:noreply, %{state | sent: [{:audio, audio_chunk, mime_type} | state.sent]}}
    end

    def handle_cast(:end_turn, state) do
      {:noreply, %{state | sent: [:end_turn | state.sent]}}
    end

    def handle_cast(:cancel_output, state) do
      {:noreply, %{state | sent: [:cancel_output | state.sent]}}
    end

    def handle_cast({:push_event, payload}, state) do
      send(state.owner, {:gemini_live, :event, payload})
      {:noreply, state}
    end
  end

  test "start_session returns Gemini realtime transport" do
    assert {:ok,
            %{
              session_id: session_id,
              run_id: run_id,
              mode: :realtime,
              transport: transport,
              stack: stack
            }} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               provider: :gemini,
               gemini_session_bootstrap_fun: &fake_bootstrap/1,
               gemini_live_connection: FakeGeminiLiveConnection
             )

    assert stack.realtime == :gemini
    assert transport.provider == :gemini
    assert transport.audio_config.input.mime_type == "audio/pcm;rate=16000"

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "startup emits listening duplex_state_changed only once" do
    session_id = "gemini-startup-once"
    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(StartupWorkflow, %{},
               session_id: session_id,
               mode: :realtime,
               provider: :gemini,
               keep_alive: true,
               gemini_session_bootstrap_fun: &fake_bootstrap/1,
               gemini_live_connection: FakeGeminiLiveConnection
             )

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :connecting, mode: :realtime}}},
                   1_000

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening, mode: :realtime}}},
                   1_000

    refute_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening, mode: :realtime}}},
                   150

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "push_audio relays media to Gemini live connection" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               provider: :gemini,
               gemini_session_bootstrap_fun: &fake_bootstrap/1,
               gemini_live_connection: FakeGeminiLiveConnection
             )

    connection_pid = session_connection_pid(session_id)

    assert :ok = Synaptic.Voice.push_audio(session_id, <<1, 2, 3>>)
    assert :ok = Synaptic.Voice.end_turn(session_id)

    sent = FakeGeminiLiveConnection.sent(connection_pid)
    assert {:audio, <<1, 2, 3>>, "audio/pcm;rate=16000"} in sent
    assert :end_turn in sent

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "input transcription triggers workflow and response injection" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               provider: :gemini,
               gemini_session_bootstrap_fun: &fake_bootstrap/1,
               gemini_live_connection: FakeGeminiLiveConnection,
               backchannel_enabled: false
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    on_exit(fn -> Synaptic.Voice.unsubscribe_session(session_id) end)

    connection_pid = session_connection_pid(session_id)

    :ok =
      FakeGeminiLiveConnection.push_event(connection_pid, %{
        "serverContent" => %{
          "inputTranscription" => %{
            "text" => "summarize phoenixframework/phoenix",
            "isFinal" => true
          }
        }
      })

    assert_receive {:synaptic_voice_event, %{event: :input_final_text}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :workflow_started}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :assistant_response_started}}, 4_000

    sent = FakeGeminiLiveConnection.sent(connection_pid)

    assert Enum.any?(sent, fn
             {:json, %{"clientContent" => %{"turns" => [%{"parts" => [%{"text" => text}]}]}}} ->
               String.contains?(text, "Read the answer below to the user")

             _ ->
               false
           end)

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  defp fake_bootstrap(_opts) do
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
  end

  defp session_connection_pid(session_id) do
    [{session_pid, _metadata}] = Registry.lookup(Synaptic.Voice.SessionRegistry, session_id)
    :sys.get_state(session_pid).connection_pid
  end
end
