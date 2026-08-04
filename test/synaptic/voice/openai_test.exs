defmodule Synaptic.Voice.OpenAITest do
  use ExUnit.Case

  alias Synaptic.Voice.Providers.OpenAI.{STTAdapter, TTSAdapter}
  alias Synaptic.Voice.Providers.OpenAI.Realtime.{EventMapper, SessionBootstrap}

  test "EventMapper normalizes known payloads" do
    assert {:ok, %{event: :input_partial_text, data: %{text: "hi"}}} =
             EventMapper.normalize_event(%{
               "type" => "conversation.item.input_audio_transcription.delta",
               "delta" => "hi"
             })

    assert {:ignore, _} = EventMapper.normalize_event(%{"type" => "unknown"})
  end

  test "EventMapper normalizes GA realtime output events" do
    assert {:ok, %{event: :assistant_text_chunk, data: %{text: "hello"}}} =
             EventMapper.normalize_event(%{
               "type" => "response.output_audio_transcript.delta",
               "delta" => "hello"
             })

    assert {:ok, %{event: :assistant_text_chunk, data: %{text: "done"}}} =
             EventMapper.normalize_event(%{
               "type" => "response.output_audio_transcript.done",
               "transcript" => "done"
             })

    assert {:ok, %{event: :assistant_text_chunk, data: %{text: "text"}}} =
             EventMapper.normalize_event(%{
               "type" => "response.output_text.delta",
               "delta" => "text"
             })
  end

  test "STTAdapter posts transcription request and emits final text" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      assert Plug.Conn.get_req_header(conn, "content-type") |> List.first() =~
               "multipart/form-data"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "name=\"model\""
      assert body =~ "name=\"file\""
      Plug.Conn.resp(conn, 200, ~s({"text":"transcribed text"}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok =
      STTAdapter.push_audio(pid, "audio-bytes",
        partial_text: "part",
        format: %{mime: "audio/webm"}
      )

    assert_receive {:synaptic_voice, :stt_partial, "part", _}, 1_000

    :ok = STTAdapter.end_turn(pid)
    assert_receive {:synaptic_voice, :stt_final, "transcribed text", meta}, 1_000
    assert meta.content_type == "audio/webm"
    assert meta.bytes > 0
  end

  test "STTAdapter emits stt_error on upstream failure" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, "audio-bytes", format: %{mime: "audio/webm"})
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_error, {:transcription_failed, _reason, meta}}, 1_000
    assert meta.content_type == "audio/webm"
    refute_receive {:synaptic_voice, :stt_final, _, _}, 100
  end

  test "STTAdapter emits stt_error on empty transcript" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"text":"   "}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, "audio-bytes", format: %{mime: "audio/webm"})
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_error, {:empty_transcript, _meta}}, 1_000
    refute_receive {:synaptic_voice, :stt_final, _, _}, 100
  end

  test "TTSAdapter posts speech request and emits chunk" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ ~s("format":"pcm16")
      Plug.Conn.resp(conn, 200, "audio-bytes")
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.synthesize_segment(pid, "hello")
    assert_receive {:synaptic_voice, :tts_chunk, "audio-bytes", meta}, 1_000
    assert meta.audio_format == %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}
    assert meta.content_type == "audio/L16"

    :ok = TTSAdapter.flush(pid)
    assert_receive {:synaptic_voice, :tts_done, _}, 1_000
  end

  test "TTSAdapter cancel does not poison subsequent synthesis" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      Plug.Conn.resp(conn, 200, "next-audio")
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.cancel_output(pid)
    assert_receive {:synaptic_voice, :tts_done, %{provider: :openai, canceled: true}}, 1_000

    :ok = TTSAdapter.synthesize_segment(pid, "hello again")
    assert_receive {:synaptic_voice, :tts_chunk, "next-audio", meta}, 1_000
    assert meta.provider == :openai
  end

  test "TTSAdapter emits tts_error on upstream failure" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.synthesize_segment(pid, "hello")
    assert_receive {:synaptic_voice, :tts_error, {:upstream_error, 500, _}}, 1_000
  end

  test "SessionBootstrap preserves the legacy ephemeral-session contract" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/session", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      assert payload["model"] == "gpt-4o-realtime-preview"
      assert payload["voice"] == "alloy"
      assert payload["modalities"] == ["audio", "text"]
      assert payload["turn_detection"]["create_response"] == false
      refute Map.has_key?(payload, "session")

      Plug.Conn.resp(
        conn,
        200,
        ~s({"id":"sess_legacy","model":"gpt-4o-realtime-preview","voice":"alloy","client_secret":{"value":"legacy-secret"}})
      )
    end)

    assert {:ok, session} =
             SessionBootstrap.create_ephemeral_session(
               endpoint: "http://localhost:#{bypass.port}/session",
               api_key: "test-key",
               finch: Synaptic.Finch
             )

    assert session["id"] == "sess_legacy"
    assert session["client_secret"] == %{"value" => "legacy-secret"}
  end

  test "SessionBootstrap creates a GA realtime client secret" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/session", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)

      session = payload["session"]
      assert session["type"] == "realtime"
      assert session["model"] == "gpt-realtime-2.1"
      assert session["output_modalities"] == ["audio"]
      assert session["audio"]["input"]["transcription"]["model"] == "gpt-realtime-whisper"

      assert session["audio"]["input"]["turn_detection"] == %{
               "type" => "semantic_vad",
               "eagerness" => "low",
               "create_response" => true,
               "interrupt_response" => true
             }

      assert session["audio"]["input"]["noise_reduction"] == %{"type" => "near_field"}
      assert session["audio"]["output"]["voice"] == "marin"
      assert session["reasoning"] == %{"effort" => "low"}
      assert [%{"name" => "synaptic_workflow"}] = session["tools"]

      Plug.Conn.resp(
        conn,
        200,
        ~s({"value":"ek_test","expires_at":1756310470,"session":{"id":"sess_123","model":"gpt-realtime-2.1","audio":{"output":{"voice":"marin"}}}})
      )
    end)

    assert {:ok, bootstrap} =
             SessionBootstrap.create_browser_bootstrap(
               experience: :realtime_2_1,
               endpoint: "http://localhost:#{bypass.port}/session",
               api_key: "test-key",
               finch: Synaptic.Finch
             )

    assert bootstrap.client_secret == %{"value" => "ek_test"}
    assert bootstrap.experience == :realtime_2_1
    assert bootstrap.expires_at == 1_756_310_470
    assert bootstrap.session_id == "sess_123"
    assert bootstrap.model == "gpt-realtime-2.1"
    assert bootstrap.voice == "marin"
  end

  test "SessionBootstrap supports per-session reasoning experiments" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/session", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert get_in(Jason.decode!(body), ["session", "reasoning"]) == %{"effort" => "medium"}

      Plug.Conn.resp(
        conn,
        200,
        ~s({"value":"ek_test","session":{"id":"sess_123","model":"gpt-realtime-2.1"}})
      )
    end)

    assert {:ok, %{"value" => "ek_test"}} =
             SessionBootstrap.create_client_secret(
               endpoint: "http://localhost:#{bypass.port}/session",
               api_key: "test-key",
               finch: Synaptic.Finch,
               reasoning_effort: "medium"
             )
  end
end
