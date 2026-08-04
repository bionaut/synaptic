defmodule Synaptic.Voice.Realtime.SessionTest do
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

  defmodule SlowRealtimeWorkflow do
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
      Process.sleep(250)
      {:ok, %{assistant_answer: "Echo: #{context.query}"}}
    end

    step :loop, suspend: true, resume_schema: %{human_input_text: :string} do
      suspend_for_human("Ask another")
    end

    commit()
  end

  test "start_session returns realtime bootstrap payload" do
    owner = self()

    assert {:ok, %{session_id: session_id, run_id: run_id, transport: transport, mode: :realtime}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               webrtc_bootstrap_fun: fn opts ->
                 send(owner, {:legacy_bootstrap_opts, opts})

                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: opts[:model],
                    voice: opts[:voice],
                    session_id: "sess_test"
                  }}
               end
             )

    assert_receive {:legacy_bootstrap_opts, opts}
    assert opts[:experience] == :legacy
    assert opts[:response_mode] == :orchestrated
    assert opts[:model] == "gpt-4o-realtime-preview"
    assert opts[:voice] == "alloy"

    assert is_binary(session_id)
    assert is_binary(run_id)
    assert transport.model == "gpt-4o-realtime-preview"

    assert :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "Realtime 2.1 experience selects new defaults without changing legacy defaults" do
    owner = self()

    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               experience: :realtime_2_1,
               webrtc_bootstrap_fun: fn opts ->
                 send(owner, {:realtime_2_1_bootstrap_opts, opts})

                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: opts[:model],
                    voice: opts[:voice],
                    session_id: "sess_test"
                  }}
               end
             )

    assert_receive {:realtime_2_1_bootstrap_opts, opts}
    assert opts[:experience] == :realtime_2_1
    assert opts[:response_mode] == :native
    assert opts[:model] == "gpt-realtime-2.1"
    assert opts[:voice] == "marin"

    assert :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "start_session forwards per-session model and reasoning experiments" do
    owner = self()

    assert {:ok, %{session_id: session_id, run_id: run_id, transport: transport}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               provider_opts: [
                 realtime: [model: "gpt-realtime-2.1-mini", reasoning_effort: "low"]
               ],
               webrtc_bootstrap_fun: fn opts ->
                 send(owner, {:bootstrap_opts, opts})

                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: opts[:model],
                    voice: opts[:voice],
                    session_id: "sess_test"
                  }}
               end
             )

    assert_receive {:bootstrap_opts, opts}
    assert opts[:model] == "gpt-realtime-2.1-mini"
    assert opts[:reasoning_effort] == "low"
    assert transport.model == "gpt-realtime-2.1-mini"

    assert :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "final transcript triggers backchannel and workflow response" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               response_mode: :orchestrated,
               webrtc_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: "gpt-realtime-2.1",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    :ok = Synaptic.Voice.client_connected(session_id)

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_event, %{event: :input_final_text}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :backchannel_sent}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :workflow_started}}, 1_000
    assert_receive {:synaptic_voice_event, %{event: :assistant_response_started}}, 4_000
    assert_receive {:synaptic_voice_event, %{event: :provider_outbound}}, 4_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "suppresses autonomous provider responses while workflow is running" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(SlowRealtimeWorkflow, %{},
               mode: :realtime,
               response_mode: :orchestrated,
               backchannel_enabled: false,
               webrtc_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: "gpt-realtime-2.1",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    :ok = Synaptic.Voice.client_connected(session_id)

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_event, %{event: :workflow_started}}, 1_000

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "response.created"
      })

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "response.output_audio_transcript.done",
        "transcript" => "I'm sorry, I can't look that up right now."
      })

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "response.done"
      })

    assert_receive {:synaptic_voice_event, %{event: :assistant_response_suppressed}},
                   1_000

    refute_receive {:synaptic_voice_event,
                    %{
                      event: :assistant_text_chunk,
                      data: %{text: "I'm sorry, I can't look that up right now."}
                    }},
                   300

    assert_receive {:synaptic_voice_event, %{event: :provider_outbound}}, 2_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "speech_started interruption does not cancel in-flight workflow" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.start_session(SlowRealtimeWorkflow, %{},
               mode: :realtime,
               response_mode: :orchestrated,
               backchannel_enabled: false,
               webrtc_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: "gpt-realtime-2.1",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    :ok = Synaptic.Voice.subscribe_session(session_id)
    :ok = Synaptic.Voice.client_connected(session_id)

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_event, %{event: :workflow_started}}, 1_000

    :ok =
      Synaptic.Voice.ingest_provider_event(session_id, %{
        "type" => "input_audio_buffer.speech_started"
      })

    refute_receive {:synaptic_voice_event, %{event: :workflow_canceled}}, 500
    assert_receive {:synaptic_voice_event, %{event: :assistant_response_started}}, 2_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "voice facade delegates realtime mode and helper calls" do
    assert {:ok, %{session_id: session_id, run_id: run_id, realtime: realtime}} =
             Synaptic.Voice.start_session(RealtimeWorkflow, %{},
               mode: :realtime,
               webrtc_bootstrap_fun: fn _opts ->
                 {:ok,
                  %{
                    client_secret: %{"value" => "test-secret"},
                    model: "gpt-realtime-2.1",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    assert realtime.model == "gpt-realtime-2.1"

    :ok = Synaptic.Voice.subscribe_session(session_id)
    :ok = Synaptic.Voice.client_connected(session_id)

    assert_receive {:synaptic_voice_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   1_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end
end
