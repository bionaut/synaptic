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
  default_experience: :legacy,
  stt_model: "gpt-4o-mini-transcribe",
  tts_model: "gpt-4o-mini-tts",
  tts_audio_format: "pcm16",
  realtime_model: "gpt-4o-realtime-preview",
  realtime_response_mode: :orchestrated,
  voice: "alloy",
  realtime_2_1_model: "gpt-realtime-2.1",
  realtime_2_1_transcription_model: "gpt-realtime-whisper",
  realtime_2_1_reasoning_effort: "low",
  realtime_2_1_response_mode: :native,
  realtime_2_1_turn_detection: "semantic_vad",
  realtime_2_1_turn_eagerness: "low",
  realtime_2_1_noise_reduction: "near_field",
  realtime_2_1_voice: "marin",
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

config :synaptic, Synaptic.Voice.Providers.ElevenLabs,
  finch: Synaptic.Finch,
  tts_model_id: "eleven_multilingual_v2",
  stt_model_id: "scribe_v2",
  tts_output_format: "pcm_24000"

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
