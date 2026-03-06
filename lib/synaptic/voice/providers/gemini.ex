defmodule Synaptic.Voice.Providers.Gemini do
  @moduledoc false

  def config(opts) do
    Keyword.get(opts, :config, [])
    |> Keyword.merge(Application.get_env(:synaptic, __MODULE__, []))
  end

  def api_key(opts) do
    opts[:api_key] ||
      config(opts)[:api_key] ||
      System.get_env("GEMINI_API_KEY") ||
      raise "Synaptic voice Gemini adapter requires an API key"
  end

  def finch(opts) do
    opts[:finch] || config(opts)[:finch] || Synaptic.Finch
  end

  def tts_model(opts) do
    opts[:tts_model] || config(opts)[:tts_model] || "gemini-2.5-flash-preview-tts"
  end

  def stt_model(opts) do
    opts[:stt_model] || config(opts)[:stt_model] || "gemini-2.5-flash"
  end

  def live_model(opts) do
    opts[:live_model] || config(opts)[:live_model] || "gemini-2.5-flash-native-audio-preview"
  end

  def live_voice(opts) do
    opts[:live_voice] || opts[:voice] || config(opts)[:live_voice] || config(opts)[:voice] ||
      "Kore"
  end

  def stt_endpoint(opts) do
    opts[:stt_endpoint] || opts[:endpoint] || config(opts)[:stt_endpoint] ||
      "https://generativelanguage.googleapis.com/v1beta/models/#{stt_model(opts)}:generateContent"
  end

  def tts_endpoint(opts) do
    opts[:tts_endpoint] || opts[:endpoint] || config(opts)[:tts_endpoint] ||
      "https://generativelanguage.googleapis.com/v1beta/models/#{tts_model(opts)}:generateContent"
  end

  def live_ws_endpoint(opts) do
    opts[:live_ws_endpoint] || config(opts)[:live_ws_endpoint] ||
      "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
  end
end
