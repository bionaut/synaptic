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
    assert {:ok, %{session_id: session_id, run_id: run_id, realtime: realtime}} =
             Synaptic.Voice.Realtime.start_session(RealtimeWorkflow, %{},
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

    assert is_binary(session_id)
    assert is_binary(run_id)
    assert realtime.model == "gpt-4o-realtime-preview"

    assert :ok = Synaptic.Voice.Realtime.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "final transcript triggers backchannel and workflow response" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.Realtime.start_session(RealtimeWorkflow, %{},
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

    :ok = Synaptic.Voice.Realtime.subscribe_session(session_id)
    :ok = Synaptic.Voice.Realtime.client_connected(session_id)

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_realtime_event, %{event: :input_final_text}}, 1_000
    assert_receive {:synaptic_voice_realtime_event, %{event: :backchannel_sent}}, 1_000
    assert_receive {:synaptic_voice_realtime_event, %{event: :workflow_started}}, 1_000
    assert_receive {:synaptic_voice_realtime_event, %{event: :assistant_response_started}}, 4_000
    assert_receive {:synaptic_voice_realtime_event, %{event: :provider_outbound}}, 4_000

    :ok = Synaptic.Voice.Realtime.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "suppresses autonomous provider responses while workflow is running" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.Realtime.start_session(SlowRealtimeWorkflow, %{},
               backchannel_enabled: false,
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

    :ok = Synaptic.Voice.Realtime.subscribe_session(session_id)
    :ok = Synaptic.Voice.Realtime.client_connected(session_id)

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_realtime_event, %{event: :workflow_started}}, 1_000

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "response.created"
      })

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "response.audio_transcript.done",
        "transcript" => "I'm sorry, I can't look that up right now."
      })

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "response.done"
      })

    assert_receive {:synaptic_voice_realtime_event, %{event: :assistant_response_suppressed}},
                   1_000

    refute_receive {:synaptic_voice_realtime_event,
                    %{
                      event: :assistant_text_chunk,
                      data: %{text: "I'm sorry, I can't look that up right now."}
                    }},
                   300

    assert_receive {:synaptic_voice_realtime_event, %{event: :provider_outbound}}, 2_000

    :ok = Synaptic.Voice.Realtime.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end

  test "speech_started interruption does not cancel in-flight workflow" do
    assert {:ok, %{session_id: session_id, run_id: run_id}} =
             Synaptic.Voice.Realtime.start_session(SlowRealtimeWorkflow, %{},
               backchannel_enabled: false,
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

    :ok = Synaptic.Voice.Realtime.subscribe_session(session_id)
    :ok = Synaptic.Voice.Realtime.client_connected(session_id)

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "conversation.item.input_audio_transcription.completed",
        "transcript" => "summarize phoenixframework/phoenix"
      })

    assert_receive {:synaptic_voice_realtime_event, %{event: :workflow_started}}, 1_000

    :ok =
      Synaptic.Voice.Realtime.ingest_provider_event(session_id, %{
        "type" => "input_audio_buffer.speech_started"
      })

    refute_receive {:synaptic_voice_realtime_event, %{event: :workflow_canceled}}, 500
    assert_receive {:synaptic_voice_realtime_event, %{event: :assistant_response_started}}, 2_000

    :ok = Synaptic.Voice.Realtime.stop_session(session_id, :normal)
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
                    model: "gpt-4o-realtime-preview",
                    voice: "alloy",
                    session_id: "sess_test"
                  }}
               end
             )

    assert realtime.model == "gpt-4o-realtime-preview"

    :ok = Synaptic.Voice.subscribe_session(session_id)
    :ok = Synaptic.Voice.client_connected(session_id)

    assert_receive {:synaptic_voice_realtime_event,
                    %{event: :duplex_state_changed, data: %{status: :listening}}},
                   1_000

    :ok = Synaptic.Voice.stop_session(session_id, :normal)
    _ = Synaptic.stop(run_id, :test_cleanup)
  end
end
