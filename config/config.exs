import Config

# Synaptic workflow defaults
config :synaptic, Synaptic.Tools, llm_adapter: Synaptic.Tools.OpenAI

config :synaptic, Synaptic.Tools.OpenAI,
  finch: Synaptic.Finch,
  model: "gpt-4o-mini"

config :synaptic, Synaptic.Voice,
  default_mode: :duplex,
  default_provider: :openai,
  audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}

config :synaptic, Synaptic.Voice.Providers.OpenAI,
  finch: Synaptic.Finch,
  stt_model: "gpt-4o-mini-transcribe",
  tts_model: "gpt-4o-mini-tts",
  tts_audio_format: "pcm16",
  realtime_model: "gpt-4o-realtime-preview",
  voice: "alloy",
  cancel_on_interrupt: true,
  workflow_timeout_ms: 30_000,
  backchannel_phrases: [
    "Got it. Let me check that now.",
    "Sure, I can look that up.",
    "Okay, give me a moment while I verify that."
  ],
  sideband_adapter: Synaptic.Voice.Providers.OpenAI.Realtime.Sideband

config :synaptic, Synaptic.Voice.Providers.Gemini,
  finch: Synaptic.Finch,
  tts_model: "gemini-2.5-flash-preview-tts",
  stt_model: "gemini-2.5-flash",
  live_model: "gemini-2.5-flash-native-audio-preview",
  voice: "Kore",
  live_voice: "Kore"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
