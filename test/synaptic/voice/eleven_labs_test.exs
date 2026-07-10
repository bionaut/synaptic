defmodule Synaptic.Voice.ElevenLabsTest do
  use ExUnit.Case

  alias Synaptic.Voice.Providers.ElevenLabs
  alias Synaptic.Voice.Providers.ElevenLabs.{STTAdapter, TTSAdapter}

  test "ElevenLabs provider module exposes defaults" do
    assert ElevenLabs.tts_model_id([]) == "eleven_multilingual_v2"
    assert ElevenLabs.stt_model_id([]) == "scribe_v2"
    assert ElevenLabs.tts_output_format([]) == "pcm_24000"
    assert ElevenLabs.tts_endpoint([]) == "https://api.elevenlabs.io/v1/text-to-speech"
    assert ElevenLabs.stt_endpoint([]) == "https://api.elevenlabs.io/v1/speech-to-text"
  end

  test "ElevenLabs STT posts wav payload and emits final transcript" do
    bypass = Bypass.open()
    audio = <<1, 2, 3, 4, 5, 6, 7, 8>>

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      assert Plug.Conn.get_req_header(conn, "xi-api-key") == ["test-key"]

      assert Plug.Conn.get_req_header(conn, "content-type") |> List.first() =~
               "multipart/form-data"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "name=\"model_id\""
      assert body =~ "name=\"file\"; filename=\"audio.wav\""
      assert body =~ "audio/wav"
      assert body =~ "RIFF"

      Plug.Conn.resp(conn, 200, ~s({"text":"eleven transcript"}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        stt_endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, audio)
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_final, "eleven transcript", meta}, 1_000
    assert meta.provider == :eleven_labs
    assert meta.content_type == "audio/wav"
    assert meta.bytes == byte_size(audio)
  end

  test "ElevenLabs STT passes through non-PCM mime payloads" do
    bypass = Bypass.open()
    webm_bytes = <<26, 69, 223, 163, 0, 1, 2, 3>>

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "filename=\"audio.webm\""
      assert body =~ "audio/webm"
      refute body =~ "RIFF"

      Plug.Conn.resp(conn, 200, ~s({"text":"webm transcript"}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, webm_bytes, format: %{mime: "audio/webm"})
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_final, "webm transcript", meta}, 1_000
    assert meta.content_type == "audio/webm"
    assert meta.bytes == byte_size(webm_bytes)
  end

  test "ElevenLabs STT emits stt_error for empty transcript and upstream failure" do
    empty_bypass = Bypass.open()
    error_bypass = Bypass.open()

    Bypass.expect_once(empty_bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"text":"   "}))
    end)

    Bypass.expect_once(error_bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    {:ok, empty_pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{empty_bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    {:ok, error_pid} =
      STTAdapter.start_link(self(),
        endpoint: "http://localhost:#{error_bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(empty_pid, <<1, 2, 3>>)
    :ok = STTAdapter.end_turn(empty_pid)

    assert_receive {:synaptic_voice, :stt_error, {:empty_transcript, %{provider: :eleven_labs}}},
                   1_000

    :ok = STTAdapter.push_audio(error_pid, <<1, 2, 3>>)
    :ok = STTAdapter.end_turn(error_pid)

    assert_receive {:synaptic_voice, :stt_error, {:transcription_failed, _reason, meta}}, 1_000
    assert meta.provider == :eleven_labs
  end

  test "ElevenLabs TTS posts speech request with voice settings and emits PCM metadata" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/tts/voice_123", fn conn ->
      assert conn.query_string == "output_format=pcm_24000"
      assert Plug.Conn.get_req_header(conn, "xi-api-key") == ["test-key"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["text"] == "hello"
      assert decoded["model_id"] == "eleven_multilingual_v2"
      assert decoded["voice_settings"] == %{"stability" => 0.6, "speed" => 1.1}

      Plug.Conn.resp(conn, 200, <<0, 1, 2, 3>>)
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        tts_endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        voice_id: "voice_123",
        voice_settings: [stability: 0.6, speed: 1.1],
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.synthesize_segment(pid, "hello")
    assert_receive {:synaptic_voice, :tts_chunk, <<0, 1, 2, 3>>, meta}, 1_000
    assert meta.provider == :eleven_labs
    assert meta.audio_format == %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}
    assert meta.content_type == "audio/L16"

    :ok = TTSAdapter.flush(pid)
    assert_receive {:synaptic_voice, :tts_done, %{provider: :eleven_labs}}, 1_000
  end

  test "ElevenLabs TTS emits tts_error for missing voice_id and upstream failure" do
    error_bypass = Bypass.open()

    Bypass.expect_once(error_bypass, "POST", "/tts/voice_123", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    {:ok, missing_voice_pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{error_bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    {:ok, error_pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{error_bypass.port}/tts",
        api_key: "test-key",
        voice_id: "voice_123",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.synthesize_segment(missing_voice_pid, "hello")
    assert_receive {:synaptic_voice, :tts_error, {:configuration_error, _message}}, 1_000

    :ok = TTSAdapter.synthesize_segment(error_pid, "hello")
    assert_receive {:synaptic_voice, :tts_error, {:upstream_error, 500, _}}, 1_000
  end
end
