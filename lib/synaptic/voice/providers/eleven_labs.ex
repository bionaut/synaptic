defmodule Synaptic.Voice.Providers.ElevenLabs do
  @moduledoc false

  @default_base_url "https://api.elevenlabs.io"
  @default_tts_model_id "eleven_multilingual_v2"
  @default_stt_model_id "scribe_v2"
  @default_tts_output_format "pcm_24000"

  def config(opts) do
    Keyword.get(opts, :config, [])
    |> Keyword.merge(Application.get_env(:synaptic, __MODULE__, []))
  end

  def api_key(opts) do
    opts[:api_key] ||
      config(opts)[:api_key] ||
      System.get_env("ELEVENLABS_API_KEY") ||
      raise "Synaptic voice ElevenLabs adapter requires an API key"
  end

  def finch(opts) do
    opts[:finch] || config(opts)[:finch] || Synaptic.Finch
  end

  def voice_id(opts) do
    opts[:voice_id] ||
      config(opts)[:voice_id] ||
      raise "Synaptic voice ElevenLabs TTS adapter requires a voice_id"
  end

  def tts_model_id(opts) do
    opts[:tts_model_id] || config(opts)[:tts_model_id] || @default_tts_model_id
  end

  def stt_model_id(opts) do
    opts[:stt_model_id] || config(opts)[:stt_model_id] || @default_stt_model_id
  end

  def tts_output_format(opts) do
    opts[:tts_output_format] || config(opts)[:tts_output_format] || @default_tts_output_format
  end

  def tts_endpoint(opts) do
    opts[:tts_endpoint] || opts[:endpoint] || config(opts)[:tts_endpoint] ||
      base_url(opts) <> "/v1/text-to-speech"
  end

  def stt_endpoint(opts) do
    opts[:stt_endpoint] || opts[:endpoint] || config(opts)[:stt_endpoint] ||
      base_url(opts) <> "/v1/speech-to-text"
  end

  defp base_url(opts) do
    opts[:base_url] || config(opts)[:base_url] || @default_base_url
  end
end
