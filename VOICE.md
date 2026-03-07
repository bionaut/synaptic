# Synaptic Voice Guide

This guide documents Synaptic's voice subsystem and **principles for building real-time voice applications**: how to enable voice, configure it, and use the framework to get the desired behavior. Synaptic does not ship a UI or client; your application owns the transport and UX. The following sections outline how to structure your app so that workflows stay in Synaptic while voice I/O behaves the way you want.

---

## Mode-specific setup playbooks

For implementation-grade, step-by-step setup instructions by mode:

- Duplex: [`docs/voice_modes/duplex_setup.md`](docs/voice_modes/duplex_setup.md)
- Turn-based: [`docs/voice_modes/turn_based_setup.md`](docs/voice_modes/turn_based_setup.md)
- Realtime: [`docs/voice_modes/realtime_setup.md`](docs/voice_modes/realtime_setup.md)

---

## Frontend setup playbooks

For frontend-only integration details (event wiring, UI states, recorder/playback controls):

- Duplex frontend: [`docs/voice_frontend/duplex_frontend_setup.md`](docs/voice_frontend/duplex_frontend_setup.md)
- Turn-based frontend: [`docs/voice_frontend/turn_based_frontend_setup.md`](docs/voice_frontend/turn_based_frontend_setup.md)
- Realtime frontend: [`docs/voice_frontend/realtime_frontend_setup.md`](docs/voice_frontend/realtime_frontend_setup.md)

---

## What the framework provides

`Synaptic.Voice` is the only public voice API.

- **Headless voice**: `mode: :turn_based` or `mode: :duplex`. Synaptic owns the session process; you push audio or text, call `end_turn`, and consume normalized events.
- **Realtime voice**: `mode: :realtime` with provider-specific transport semantics:
  - OpenAI: client-direct WebRTC + server sideband orchestration
  - Gemini: server-relay WebSocket (client talks to your app, app talks to Gemini Live)

Provider selection is per session with `provider: :openai | :gemini | :eleven_labs`
for headless voice and `provider: :openai | :gemini` for realtime. Public mixed
stacks are rejected.

Choose `:realtime` when you want low-latency conversational transport. Choose `:turn_based` or `:duplex` when you want explicit turn control and direct STT/TTS orchestration.

---

## Enabling and configuring voice

### Dependencies and application

Add `synaptic` to your project. Synaptic’s application starts its own PubSub, Finch, and voice/realtime supervisors; you do not need to start these yourself.

### Configuration

**Compile-time** (e.g. `config/config.exs`):

```elixir
# Tools (for workflow LLM calls)
config :synaptic, Synaptic.Tools.OpenAI, model: "gpt-4o-mini"

config :synaptic, Synaptic.Voice,
  default_mode: :duplex,
  default_provider: :openai,
  audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}

config :synaptic, Synaptic.Voice.Providers.OpenAI,
  stt_model: "gpt-4o-mini-transcribe",
  tts_model: "gpt-4o-mini-tts",
  tts_audio_format: "pcm16",
  realtime_model: "gpt-4o-realtime-preview",
  voice: "alloy"

config :synaptic, Synaptic.Voice.Providers.Gemini,
  stt_model: "gemini-2.5-flash",
  tts_model: "gemini-2.5-flash-preview-tts",
  live_model: "gemini-2.5-flash-native-audio-preview",
  voice: "Kore",
  live_voice: "Kore"

config :synaptic, Synaptic.Voice.Providers.ElevenLabs,
  tts_model_id: "eleven_multilingual_v2",
  stt_model_id: "scribe_v2",
  tts_output_format: "pcm_24000"
```

**Runtime / secrets** (e.g. `config/runtime.exs`):

```elixir
if api_key = System.get_env("OPENAI_API_KEY") do
  config :synaptic, Synaptic.Tools.OpenAI, api_key: api_key
  config :synaptic, Synaptic.Voice.Providers.OpenAI, api_key: api_key
end

if gemini_api_key = System.get_env("GEMINI_API_KEY") do
  config :synaptic, Synaptic.Voice.Providers.Gemini, api_key: gemini_api_key
end

if elevenlabs_api_key = System.get_env("ELEVENLABS_API_KEY") do
  config :synaptic, Synaptic.Voice.Providers.ElevenLabs, api_key: elevenlabs_api_key
end
```

---

## Principles for realtime voice

Realtime has two provider patterns:

- **OpenAI realtime**: client talks directly to provider over WebRTC; server orchestrates through sideband.
- **Gemini realtime**: server holds the Live WebSocket; client audio/text is relayed through your app.

Create sessions with:

```elixir
Synaptic.Voice.start_session(MyWorkflow, %{}, provider: :openai, mode: :realtime)
Synaptic.Voice.start_session(MyWorkflow, %{}, provider: :gemini, mode: :realtime)
```

Use `transport` from the return payload to bootstrap client behavior:

- OpenAI transport includes provider bootstrap fields like `client_secret`, `expires_at`, `model`, `voice`.
- Gemini transport describes relay expectations (`audio_config`) and does not expose provider credentials to clients.

### Realtime operation matrix

- OpenAI realtime supports: `client_connected/2`, `client_disconnected/2`, `ingest_provider_event/2`.
- Gemini realtime supports: `push_audio/3`, `push_text/3`, `end_turn/2`, `cancel_output/1`.
- Unsupported operations return `{:error, :unsupported_for_mode}`.

### Workflow design for realtime

- The realtime sideband resumes the workflow with the **final user transcript**. The default mapping sends `%{human_input_text: transcript}` (or `%{answer: transcript}` if the suspended step’s `resume_schema` has `:answer`).
- Design your workflow so that the first step that needs user speech has `suspend: true` and `resume_schema: %{human_input_text: :string}` (or `answer: :string`). When the step runs after resume, read from `context[:human_input][:human_input_text]` or `context[:human_input][:answer]` (or fallback to `context.human_input_text` / `context.answer`) and put the result into context (e.g. `query`).
- After tools and LLM, produce a step result that includes the spoken reply (e.g. `assistant_answer`). The framework will send the appropriate provider instructions so the provider speaks that content.
- To support multiple turns, add a later step that again suspends with `resume_schema: %{human_input_text: :string}`; on resume, route back to your router or first logic step with the new query so the same pipeline runs again.

---

## Realtime API summary (server)

| Function | Purpose |
|----------|---------|
| `Synaptic.Voice.start_session(workflow_module, input, provider: :openai | :gemini, mode: :realtime, ...)` | Start a run and realtime session; return payload for the client. |
| `Synaptic.Voice.subscribe_session(session_id)` | Subscribe to session events (`{:synaptic_voice_event, envelope}`). |
| `Synaptic.Voice.unsubscribe_session(session_id)` | Unsubscribe. |
| `Synaptic.Voice.client_connected(session_id)` | OpenAI realtime only. |
| `Synaptic.Voice.client_disconnected(session_id)` | OpenAI realtime only. |
| `Synaptic.Voice.ingest_provider_event(session_id, payload)` | OpenAI realtime only. |
| `Synaptic.Voice.push_audio(session_id, chunk)` | Headless and Gemini realtime. |
| `Synaptic.Voice.push_text(session_id, text)` | Headless and Gemini realtime. |
| `Synaptic.Voice.stop_session(session_id, reason)` | Stop the session. |

---

## Realtime session events (PubSub)

Subscribe with `Synaptic.Voice.subscribe_session(session_id)`. All voice modes publish on topic `"synaptic:voice:session:" <> session_id` as:

`{:synaptic_voice_event, envelope}`

Envelope fields include: `:event`, `:data`, `:session_id`, `:run_id`, `:seq`, `:ts_ms`.

Useful events:

- `:session_started`, `:session_stopped`, `:session_error`
- `:input_partial_text`, `:input_final_text`
- `:assistant_response_started`, `:assistant_text_chunk`, `:assistant_response_done`
- `:duplex_state_changed`
- `:provider_outbound` — the payload to send to the provider on the data channel (e.g. `response.create`); push this to your client so it can forward it.

Use these to drive UI (status, transcripts) and to relay `:provider_outbound` to the client.

---

## Principles for headless voice

When you own the transport (e.g. your own WebSocket) and want Synaptic to run STT/TTS and workflows:

- **Start or attach**: `Synaptic.Voice.start_session(workflow_module, input, opts)` starts a run and session; `attach_run(run_id, opts)` attaches a session to an existing run. Both return `{:ok, %{session_id, run_id, mode, stack, transport}}`.
- **Provider bundle**: pass `provider: :openai | :gemini | :eleven_labs`. Router derives pure stacks internally; public `stack` is rejected unless `_allow_custom_stack: true` (internal/tests).
- **Input**: Stream audio with `push_audio(session_id, chunk, opts)` and/or send text with `push_text(session_id, text, opts)`. When the user turn is complete, call `end_turn(session_id, opts)` so STT finalizes (if applicable) and the run resumes with the transcript.
- **Output**: Subscribe with `Synaptic.Voice.subscribe_session(session_id)`; events arrive on topic `"synaptic:voice:session:" <> session_id` as `{:synaptic_voice_event, envelope}`. Use `:assistant_text_chunk`, `:assistant_audio_chunk`, etc., to drive your playback and UI. Built-in headless providers now default to one TTS generation per assistant turn for more consistent tone; segmented TTS remains the fallback for adapters without capability metadata.
- **Interruption**: In duplex mode, call `cancel_output(session_id)` when the user interrupts; the framework emits `:duplex_interruption` and transitions back to listening.
- **Resume mapping**: By default, the transcript is sent as `%{human_input_text: transcript}` or `%{answer: transcript}` depending on the step’s `resume_schema`. Override with `resume_mapper: fn transcript, state -> payload end` in session options.
- **Unsupported operations**: functions that do not make sense for provider+mode return `{:error, :unsupported_for_mode}`.
- **Cleanup**: Call `Synaptic.Voice.stop_session(session_id, reason)` and unsubscribe when the session ends.

---

## Headless: modules and event envelope

- **Modules**: `Synaptic.Voice` (API), `Synaptic.Voice.Router`, `Synaptic.Voice.SessionRegistry`, `Synaptic.Voice.HeadlessSessionSupervisor`, `Synaptic.Voice.RealtimeSessionSupervisor`, `Synaptic.Voice.Event`, `Synaptic.Voice.TextSegmenter`; engines: `Synaptic.Voice.Sessions.Headless`, `Synaptic.Voice.Sessions.Realtime.OpenAI`, `Synaptic.Voice.Sessions.Realtime.Gemini`; providers: `Synaptic.Voice.Providers.OpenAI.*`, `Synaptic.Voice.Providers.Gemini.*`, `Synaptic.Voice.Providers.ElevenLabs.*`.
- **Headless output strategies**: headless sessions select an internal TTS strategy from provider capability metadata. Current strategies are `:segmented_batch`, `:single_shot`, and reserved `:streaming`.
- **Envelope**: guaranteed fields `:v`, `:session_id`, `:run_id`, `:seq`, `:ts_ms`, `:event`, `:data`.
- **Event names**: `:turn_started`, `:input_partial_text`, `:input_final_text`, `:assistant_text_chunk`, `:assistant_text_done`, `:assistant_audio_chunk`, `:assistant_audio_done`, `:duplex_interruption`, `:duplex_state_changed`, `:session_error`, `:session_stopped`.

---

## Configuration reference

Defaults are:

- `default_mode: :duplex`
- `default_provider: :openai`
- `audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}`

---

## Telemetry

- **Headless**: `[:synaptic, :voice, :session, :start|:stop]`, `[:synaptic, :voice, :stt, :partial|:final|:error]`, `[:synaptic, :voice, :tts, :chunk|:done|:error]`, `[:synaptic, :voice, :duplex, :interruption]`, `[:synaptic, :voice, :latency]` (e.g. `stt_first_partial_ms`, `llm_first_chunk_ms`, `tts_first_chunk_ms`, `turn_total_ms`).
- **Realtime**: `[:synaptic, :voice, :realtime, :session, :start]` and related.

---

## Testing

- Voice tests: `test/synaptic/voice/event_test.exs`, `text_segmenter_test.exs`, `session_test.exs`, `openai_test.exs`.
- Synthetic latency: `mix run scripts/voice_latency_harness.exs`.

---

## Limitations

- No built-in UI or client transport; your app provides both.
- Headless OpenAI STT batches audio and transcribes on `end_turn`; partials can be simulated via `push_audio(..., partial_text: ...)`.
- TTS playback is your responsibility. Depending on provider capabilities, headless voice may synthesize per segment or once per assistant turn.
- Realtime behavior is provider-specific: OpenAI uses client-direct WebRTC + sideband; Gemini uses server-relay Live WebSocket.

---

## Extending to another provider

Implement the headless behaviours:

- `Synaptic.Voice.STTAdapter`
- `Synaptic.Voice.TTSAdapter`

Realtime is not provider-neutral: OpenAI and Gemini each use dedicated engines, and
`provider: :eleven_labs` is headless-only.
