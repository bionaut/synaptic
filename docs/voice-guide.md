# Synaptic Voice Guide

This guide documents Synaptic's voice subsystem and **principles for building real-time voice applications**: how to enable voice, configure it, and use the framework to get the desired behavior. Synaptic does not ship a UI or client; your application owns the transport and UX. The following sections outline how to structure your app so that workflows stay in Synaptic while voice I/O behaves the way you want.

---

## What the framework provides

- **Headless voice** (`Synaptic.Voice`): session process bound to a workflow run; you push audio or text, call `end_turn`, and consume events. You own STT/TTS transport (e.g. your own WebSocket).
- **Realtime voice** (`Synaptic.Voice.Realtime`): session process where the **provider** (e.g. OpenAI) handles media over WebRTC; Synaptic orchestrates workflow per turn and injects response instructions. Audio flows client ↔ provider; control and transcripts flow client ↔ your server ↔ Synaptic.

Choose **Realtime** when you want low-latency duplex “voice assistant” UX with provider-managed audio. Choose **Headless** when you want to own the full audio path and transport.

---

## Enabling and configuring voice

### Dependencies and application

Add `synaptic` to your project. Synaptic’s application starts its own PubSub, Finch, and voice/realtime supervisors; you do not need to start these yourself.

### Configuration

**Compile-time** (e.g. `config/config.exs`):

```elixir
# Tools (for workflow LLM calls)
config :synaptic, Synaptic.Tools.OpenAI, model: "gpt-4o-mini"

# Voice: STT/TTS adapters (headless); realtime uses the provider’s Realtime API
config :synaptic, Synaptic.Voice,
  default_voice_mode: :duplex,
  stt_adapter: Synaptic.Voice.OpenAI.STTAdapter,
  tts_adapter: Synaptic.Voice.OpenAI.TTSAdapter

# Voice OpenAI: models and formats
config :synaptic, Synaptic.Voice.OpenAI,
  tts_model: "gpt-4o-mini-tts",
  stt_model: "gpt-4o-mini-transcribe",
  realtime_model: "gpt-4o-realtime-preview",
  voice: "alloy"
```

**Runtime / secrets** (e.g. `config/runtime.exs`):

```elixir
if api_key = System.get_env("OPENAI_API_KEY") do
  config :synaptic, Synaptic.Tools.OpenAI, api_key: api_key
  config :synaptic, Synaptic.Voice.OpenAI, api_key: api_key
end
```

---

## Principles for real-time voice (provider WebRTC)

When the client talks to the provider (e.g. OpenAI) over WebRTC and Synaptic orchestrates per turn, follow these principles.

### 1. Split responsibilities clearly

- **Audio**: client ↔ provider (WebRTC). The framework does not sit in the audio path.
- **Orchestration**: your server creates a Synaptic run and a realtime session, then a **sideband** process subscribes to the run and session, reacts to final transcripts, runs the workflow, and sends response instructions to the provider.
- **Event relay**: the client sends selected provider events (e.g. transcript completed, response done) to your server; the server feeds them into the session via `Realtime.ingest_provider_event/2`. The server receives `:provider_outbound` events from Synaptic and pushes those payloads to the client so the client can send them over the provider’s data channel.

So: **one HTTP call to create a session and get a bootstrap** (session_id, run_id, provider credentials/model); then **WebRTC + data channel** for media and control, with your server relaying provider events into Synaptic and Synaptic pushing outbound instructions back to the client.

### 2. Server: session creation and response shape

- Expose an HTTP endpoint (e.g. `POST /api/realtime/session`) that:
  - Calls `Synaptic.Voice.Realtime.start_session(workflow_module, initial_input, opts)`.
  - Returns JSON the client needs to establish WebRTC with the provider.
- The client must receive at least:
  - `session_id`, `run_id` (to tag events and subscribe).
  - A bootstrap (e.g. `realtime`) with whatever the provider needs for the SDP handshake—typically a **client secret** (Bearer token) and **model** name for the provider’s realtime endpoint (e.g. `https://api.openai.com/v1/realtime?model=...`).
- Use session options to match your product: e.g. `keep_alive: true`, `preferred_language`, `backchannel_enabled`, `backchannel_phrases`, `suppress_provider_responses_during_workflow: true` so the provider does not answer on its own.

### 3. Server: lifecycle and event relay

- When the client reports that it has a session (e.g. after receiving your JSON), subscribe to the session with `Realtime.subscribe_session(session_id)` and to the run with `Synaptic.subscribe(run_id)` so you can react to workflow and voice events.
- When the client’s WebRTC/data channel is ready, call `Realtime.client_connected(session_id)` so the sideband knows it can send instructions. On disconnect, call `Realtime.client_disconnected(session_id)`.
- For every provider event that matters for orchestration (e.g. final transcript, response created/done, errors), have the client send a compact payload to your server; your server calls `Realtime.ingest_provider_event(session_id, payload)`. Synaptic will then drive workflow and outbound instructions.
- When you receive `{:synaptic_voice_realtime_event, %{event: :provider_outbound, data: %{event: outbound}}}` from PubSub, push that `outbound` payload to the client so it can send it on the provider’s data channel (e.g. `dataChannel.send(JSON.stringify(outbound))`).
- On user disconnect or session end: unsubscribe from session and run, call `Realtime.stop_session(session_id, reason)`, and signal the client to tear down WebRTC so state stays consistent.

### 4. Client: WebRTC and data channel

- **Bootstrap**: POST to your session endpoint (e.g. with language or other preferences); get `session_id`, `run_id`, and the provider bootstrap (client_secret, model).
- **WebRTC**: Create a peer connection, add the microphone track, create the provider’s data channel (e.g. `"oai-events"`). Create an offer, POST the SDP to the provider’s realtime URL with the bootstrap token and model, set the remote description from the answer, and attach the remote stream to an audio element for playback.
- **Control the provider**: As soon as the data channel is open, send a `session.update` (or equivalent) so that:
  - Turn detection is server-driven (e.g. `server_vad`) and the provider does **not** create responses on its own (`create_response: false`), and optionally allows interruption (`interrupt_response: true`).
  - Instructions tell the model to wait for server-side orchestration and never answer autonomously.
- **Event relay**: On `dataChannel.onmessage`, parse JSON and filter to the event types your server needs. Send each to your server (e.g. via your existing transport—WebSocket, LiveView push, etc.) with `session_id` and a compact payload so the server can call `ingest_provider_event`. When your server pushes an outbound event (the payload Synaptic wants sent to the provider), send it with `dataChannel.send(JSON.stringify(event))`.
- **Cleanup**: On disconnect or when the server signals session end, close the data channel and peer connection and stop microphone tracks.

### 5. Workflow design for realtime

- The realtime sideband resumes the workflow with the **final user transcript**. The default mapping sends `%{human_input_text: transcript}` (or `%{answer: transcript}` if the suspended step’s `resume_schema` has `:answer`).
- Design your workflow so that the first step that needs user speech has `suspend: true` and `resume_schema: %{human_input_text: :string}` (or `answer: :string`). When the step runs after resume, read from `context[:human_input][:human_input_text]` or `context[:human_input][:answer]` (or fallback to `context.human_input_text` / `context.answer`) and put the result into context (e.g. `query`).
- After tools and LLM, produce a step result that includes the spoken reply (e.g. `assistant_answer`). The framework will send the appropriate provider instructions so the provider speaks that content.
- To support multiple turns, add a later step that again suspends with `resume_schema: %{human_input_text: :string}`; on resume, route back to your router or first logic step with the new query so the same pipeline runs again.

---

## Realtime API summary (server)

| Function | Purpose |
|----------|---------|
| `Realtime.start_session(workflow_module, input, opts)` | Start a run and realtime session; return payload for the client (session_id, run_id, realtime bootstrap). |
| `Realtime.subscribe_session(session_id)` | Subscribe to session events (`{:synaptic_voice_realtime_event, envelope}`). |
| `Realtime.unsubscribe_session(session_id)` | Unsubscribe. |
| `Realtime.client_connected(session_id)` | Notify that the client’s WebRTC/data channel is up. |
| `Realtime.client_disconnected(session_id)` | Notify that the client disconnected. |
| `Realtime.ingest_provider_event(session_id, payload)` | Feed a provider event from the client into the session. |
| `Realtime.stop_session(session_id, reason)` | Stop the session. |

---

## Realtime session events (PubSub)

Subscribe with `Synaptic.Voice.Realtime.subscribe_session(session_id)`. Events are broadcast on topic `"synaptic:voice:realtime:session:" <> session_id` as:

`{:synaptic_voice_realtime_event, envelope}`

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

- **Start or attach**: `Synaptic.Voice.start_session(workflow_module, input, opts)` starts a run and session; `attach_run(run_id, opts)` attaches a session to an existing run.
- **Input**: Stream audio with `push_audio(session_id, chunk, opts)` and/or send text with `push_text(session_id, text, opts)`. When the user turn is complete, call `end_turn(session_id, opts)` so STT finalizes (if applicable) and the run resumes with the transcript.
- **Output**: Subscribe with `Synaptic.Voice.subscribe_session(session_id)`; events arrive on topic `"synaptic:voice:session:" <> session_id` as `{:synaptic_voice_event, envelope}`. Use `:assistant_text_chunk`, `:assistant_audio_chunk`, etc., to drive your TTS or playback and UI.
- **Interruption**: In duplex mode, call `cancel_output(session_id)` when the user interrupts; the framework emits `:duplex_interruption` and transitions back to listening.
- **Resume mapping**: By default, the transcript is sent as `%{human_input_text: transcript}` or `%{answer: transcript}` depending on the step’s `resume_schema`. Override with `resume_mapper: fn transcript, state -> payload end` in session options.
- **Cleanup**: Call `Synaptic.Voice.stop_session(session_id, reason)` and unsubscribe when the session ends.

---

## Headless: modules and event envelope

- **Modules**: `Synaptic.Voice` (API), `Synaptic.Voice.Session`, `Synaptic.Voice.Registry`, `Synaptic.Voice.SessionSupervisor`, `Synaptic.Voice.Event`, `Synaptic.Voice.TextSegmenter`; adapters: `STTAdapter`, `TTSAdapter`; OpenAI: `OpenAI.STTAdapter`, `OpenAI.TTSAdapter`, `OpenAI.WSHelper`, `OpenAI.WebRTCHelper`.
- **Envelope**: guaranteed fields `:v`, `:session_id`, `:run_id`, `:seq`, `:ts_ms`, `:event`, `:data`.
- **Event names**: `:turn_started`, `:input_partial_text`, `:input_final_text`, `:assistant_text_chunk`, `:assistant_text_done`, `:assistant_audio_chunk`, `:assistant_audio_done`, `:duplex_interruption`, `:duplex_state_changed`, `:session_error`, `:session_stopped`.

---

## Configuration reference

```elixir
# config/config.exs
config :synaptic, Synaptic.Voice,
  default_voice_mode: :duplex,
  stt_adapter: Synaptic.Voice.OpenAI.STTAdapter,
  tts_adapter: Synaptic.Voice.OpenAI.TTSAdapter,
  audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 16_000, channels: 1}

config :synaptic, Synaptic.Voice.OpenAI,
  finch: Synaptic.Finch,
  stt_model: "gpt-4o-mini-transcribe",
  tts_model: "gpt-4o-mini-tts",
  realtime_model: "gpt-4o-realtime-preview",
  voice: "alloy"
```

```elixir
# config/runtime.exs
config :synaptic, Synaptic.Voice.OpenAI,
  api_key: System.fetch_env!("OPENAI_API_KEY")
```

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
- TTS emits segments; playback is your responsibility.
- Realtime behavior depends on the provider’s WebRTC and your configured model; provider payloads may evolve—adapters and config are the extension points.

---

## Extending to another provider

Implement the behaviours:

- `Synaptic.Voice.STTAdapter`
- `Synaptic.Voice.TTSAdapter`
- Optionally `Synaptic.Voice.TransportHelper`

Then point config at your adapters. No workflow DSL changes are required.
