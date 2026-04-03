import Config

# Synaptic workflow defaults
config :synaptic, Synaptic.Tools, llm_adapter: Synaptic.Tools.OpenAI

config :synaptic, Synaptic.Tools.OpenAI,
  finch: Synaptic.Finch,
  model: "gpt-4o-mini"

config :synaptic, Synaptic.Voice,
  default_voice_mode: :duplex,
  stt_adapter: Synaptic.Voice.OpenAI.STTAdapter,
  tts_adapter: Synaptic.Voice.OpenAI.TTSAdapter,
  audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 16_000, channels: 1}

config :synaptic, Synaptic.Voice.Realtime,
  model: "gpt-4o-realtime-preview",
  voice: "alloy",
  cancel_on_interrupt: true,
  workflow_timeout_ms: 30_000,
  backchannel_phrases: [
    "Got it. Let me check that now.",
    "Sure, I can look that up.",
    "Okay, give me a moment while I verify that."
  ],
  sideband_adapter: Synaptic.Voice.OpenAI.RealtimeSideband

config :synaptic, Synaptic.Voice.OpenAI,
  finch: Synaptic.Finch,
  stt_model: "gpt-4o-mini-transcribe",
  tts_model: "gpt-4o-mini-tts",
  realtime_model: "gpt-4o-realtime-preview",
  voice: "alloy",
  audio_format: "mp3"

config :synaptic, Synaptic.Monitor,
  enabled: config_env() == :dev,
  history_limit: 500,
  retention_ms: 300_000

config :synaptic, Synaptic.Monitor.Web,
  enabled: false,
  port: 4050

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
