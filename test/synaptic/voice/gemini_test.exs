defmodule Synaptic.Voice.GeminiTest do
  use ExUnit.Case

  alias Synaptic.Voice.Providers.Gemini.{STTAdapter, TTSAdapter}
  alias Synaptic.Voice.Providers.Gemini.Live.EventMapper

  test "Gemini Live EventMapper accepts multiple transcription shapes" do
    assert {:ok, %{event: :input_final_text, data: %{text: "hello"}}} =
             EventMapper.normalize_event(%{
               "serverContent" => %{
                 "inputTranscription" => %{"text" => "hello", "isFinal" => true}
               }
             })

    assert {:ok, %{event: :input_partial_text, data: %{text: "partial"}}} =
             EventMapper.normalize_event(%{
               "inputTranscription" => %{"transcript" => "partial", "state" => "PARTIAL"}
             })

    assert {:ok, %{event: :input_final_text, data: %{text: "done"}}} =
             EventMapper.normalize_event(%{
               "transcription" => %{"transcript" => "done", "state" => "FINAL"}
             })
  end

  test "Gemini STT posts wav payload and emits final transcript" do
    bypass = Bypass.open()
    audio = <<1, 2, 3, 4, 5, 6, 7, 8>>

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      wav_base64 =
        get_in(decoded, ["contents", Access.at(0), "parts", Access.at(0), "inline_data", "data"])

      assert is_binary(wav_base64)
      assert String.starts_with?(Base.decode64!(wav_base64), "RIFF")

      Plug.Conn.resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"text":"gemini transcript"}]}}]})
      )
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        stt_endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, audio)
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_final, "gemini transcript", meta}, 1_000
    assert meta.provider == :gemini
    assert meta.content_type == "audio/wav"
    assert meta.bytes == byte_size(audio)
  end

  test "Gemini STT emits stt_error for empty transcript" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"candidates":[{"content":{"parts":[{"text":"   "} ]}}]}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        stt_endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, <<1, 2, 3>>)
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_error, {:empty_transcript, _meta}}, 1_000
    refute_receive {:synaptic_voice, :stt_final, _, _}, 100
  end

  test "Gemini STT emits stt_error for upstream failure" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      Plug.Conn.resp(conn, 500, ~s({"error":"boom"}))
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        stt_endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, <<1, 2, 3>>)
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_error, {:transcription_failed, _reason, _meta}}, 1_000
    refute_receive {:synaptic_voice, :stt_final, _, _}, 100
  end

  test "Gemini STT passes through non-PCM mime payloads" do
    bypass = Bypass.open()
    webm_bytes = <<26, 69, 223, 163, 0, 1, 2, 3>>

    Bypass.expect_once(bypass, "POST", "/stt", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      inline =
        get_in(decoded, ["contents", Access.at(0), "parts", Access.at(0), "inline_data"])

      assert inline["mime_type"] == "audio/webm"
      assert Base.decode64!(inline["data"]) == webm_bytes

      Plug.Conn.resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"text":"webm transcript"}]}}]})
      )
    end)

    {:ok, pid} =
      STTAdapter.start_link(self(),
        stt_endpoint: "http://localhost:#{bypass.port}/stt",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = STTAdapter.push_audio(pid, webm_bytes, format: %{mime: "audio/webm"})
    :ok = STTAdapter.end_turn(pid)

    assert_receive {:synaptic_voice, :stt_final, "webm transcript", meta}, 1_000
    assert meta.content_type == "audio/webm"
    assert meta.bytes == byte_size(webm_bytes)
  end

  test "Gemini TTS emits raw PCM16 metadata" do
    bypass = Bypass.open()
    pcm_bytes = <<0, 1, 2, 3>>
    encoded = Base.encode64(pcm_bytes)

    Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "responseModalities"
      assert body =~ "AUDIO"

      Plug.Conn.resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"inlineData":{"data":"#{encoded}","mimeType":"audio/L16"}}]}}]})
      )
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.synthesize_segment(pid, "hello")

    assert_receive {:synaptic_voice, :tts_chunk, ^pcm_bytes, meta}, 1_000
    assert meta.audio_format == %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}
    assert meta.content_type == "audio/L16"

    :ok = TTSAdapter.flush(pid)
    assert_receive {:synaptic_voice, :tts_done, %{provider: :gemini}}, 1_000
  end

  test "Gemini TTS cancel does not poison subsequent synthesis" do
    bypass = Bypass.open()
    pcm_bytes = <<1, 2, 3, 4>>
    encoded = Base.encode64(pcm_bytes)

    Bypass.expect_once(bypass, "POST", "/tts", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        ~s({"candidates":[{"content":{"parts":[{"inlineData":{"data":"#{encoded}","mimeType":"audio/L16"}}]}}]})
      )
    end)

    {:ok, pid} =
      TTSAdapter.start_link(self(),
        endpoint: "http://localhost:#{bypass.port}/tts",
        api_key: "test-key",
        finch: Synaptic.Finch
      )

    :ok = TTSAdapter.cancel_output(pid)
    assert_receive {:synaptic_voice, :tts_done, %{provider: :gemini, canceled: true}}, 1_000

    :ok = TTSAdapter.synthesize_segment(pid, "next turn")
    assert_receive {:synaptic_voice, :tts_chunk, ^pcm_bytes, meta}, 1_000
    assert meta.provider == :gemini
  end

  test "Gemini TTS emits tts_error on upstream failure" do
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
end
