defmodule Synaptic.Voice.OpenAITest do
  use ExUnit.Case

  alias Synaptic.Voice.OpenAI.{STTAdapter, TTSAdapter, WSHelper, WebRTCHelper}

  test "WSHelper normalizes known payloads" do
    assert {:ok, %{event: :input_partial_text, data: %{text: "hi"}}} =
             WSHelper.normalize_event(%{"type" => "input_audio.transcript.partial", "text" => "hi"})

    assert {:error, _} = WSHelper.normalize_event(%{"type" => "unknown"})
  end

  test "WebRTCHelper delegates normalization" do
    assert {:ok, %{event: :assistant_text_done}} =
             WebRTCHelper.normalize_event(%{"type" => "response.text.done"})
  end

  test "STTAdapter posts transcription request and emits final text" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      assert Plug.Conn.get_req_header(conn, "content-type") |> List.first() =~ "multipart/form-data"
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
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
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
    assert meta.audio_format == "mp3"
    assert meta.content_type == "audio/mpeg"

    :ok = TTSAdapter.flush(pid)
    assert_receive {:synaptic_voice, :tts_done, _}, 1_000
  end

  test "WebRTCHelper creates ephemeral session" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/session", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"id":"sess_123","client_secret":"secret"}))
    end)

    assert {:ok, %{"id" => "sess_123"}} =
             WebRTCHelper.create_ephemeral_session(
               endpoint: "http://localhost:#{bypass.port}/session",
               api_key: "test-key",
               finch: Synaptic.Finch
             )
  end
end
