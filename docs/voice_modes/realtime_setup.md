# Realtime Mode Setup Guide

This guide explains how to implement realtime voice sessions with Synaptic for both providers.

Realtime mode is best when you want:
- low-latency conversational transport
- streaming interaction
- provider-native realtime capabilities

---

## 1. Provider architecture differences

OpenAI realtime:
- client-direct WebRTC to provider
- server sideband orchestration through Synaptic
- transport payload includes provider bootstrap fields (`client_secret`, etc.)

Gemini realtime:
- server holds provider Live WebSocket
- client talks to your server only
- your app relays audio/text events to Synaptic session

Do not assume transport semantics are interchangeable between providers.

---

## 2. Prerequisites

Server:
- `OPENAI_API_KEY` and/or `GEMINI_API_KEY`
- voice provider config with realtime model/voice

Client:
- for OpenAI: WebRTC support
- for Gemini: your own socket/event transport to your backend

---

## 3. Session bootstrap

Server creates session:

```elixir
{:ok, %{session_id: session_id, run_id: run_id, transport: transport}} =
  Synaptic.Voice.start_session(MyWorkflow, %{},
    provider: :openai,  # or :gemini
    mode: :realtime,
    keep_alive: true
  )
```

Then:
- subscribe to `session_id` events
- subscribe to `run_id` events
- return `transport` and IDs to client

---

## 4. OpenAI realtime integration flow

1. client receives transport bootstrap
2. client opens WebRTC session directly with OpenAI
3. when provider sends client-side events that need orchestration, your backend calls:
   - `Synaptic.Voice.client_connected(session_id)`
   - `Synaptic.Voice.ingest_provider_event(session_id, payload)`
   - `Synaptic.Voice.client_disconnected(session_id)`
4. backend emits `:provider_outbound` events; client forwards those to provider data channel

You should not proxy raw audio through your backend in this mode unless you intentionally design a relay path.

---

## 5. Gemini realtime integration flow

1. backend owns Live connection lifecycle
2. client streams/turns to backend
3. backend forwards to Synaptic session:
   - `push_audio(session_id, chunk, opts)`
   - `push_text(session_id, text, opts)`
   - `end_turn(session_id, opts)`
4. backend forwards normalized assistant events back to client

This is effectively realtime relay with Synaptic normalizing provider behavior.

---

## 6. Workflow requirements for realtime

Design workflow for repeated speech turns:
- suspend steps expecting user input should declare explicit `resume_schema`
- workflow should map resumed transcript into a stable context key
- workflow should produce assistant answer text for provider speech output
- for multi-turn conversations, re-enter a suspend point after response

Recommended pattern:
- router step -> tool/LLM steps -> assistant answer step -> wait-for-human step -> loop

---

## 7. Required event handling

Consume and route these events consistently:
- `:session_started`, `:session_stopped`, `:session_error`
- `:input_partial_text`, `:input_final_text`
- `:assistant_text_chunk`, `:assistant_response_done`
- `:assistant_audio_chunk`, `:assistant_audio_done` (where applicable)
- `:provider_outbound` (critical for OpenAI sideband)

Treat event sequence ordering as authoritative over local UI heuristics.

---

## 8. Failure handling

OpenAI realtime:
- if WebRTC setup fails, surface connect error and allow reconnect
- handle provider-side disconnects by stopping/cleaning session state

Gemini realtime:
- handle Live socket failure with automatic reconnect policy on backend
- if relay fails, keep workflow run recoverable where possible

General:
- classify `session_error` by `source` (`:workflow`, `:stt`, `:tts`, `:resume`)
- avoid hard session teardown on recoverable errors

---

## 9. Security and boundaries

- never expose server API keys to client
- OpenAI realtime bootstrap artifacts should be short-lived and session-scoped
- sanitize all client log/event payloads before appending or atomizing
- enforce per-session auth/ownership at your app boundary

---

## 10. Verification checklist

OpenAI realtime:
1. connect voice session via WebRTC
2. send/receive sideband events
3. verify `provider_outbound` forwarding
4. disconnect and reconnect cleanly

Gemini realtime:
1. send text and audio turns through relay
2. verify assistant text/audio events
3. verify multi-turn continuity
4. verify relay reconnect behavior

Both providers:
1. workflow suspend/resume loops correctly across turns
2. session errors are user-visible and recoverable
3. session cleanup stops background resources

---

## 11. Reference implementation

Internal sample app:
- `tmp/voice_lab`

Relevant code:
- realtime sessions:
  - `lib/synaptic/voice/sessions/realtime/open_ai.ex`
  - `lib/synaptic/voice/sessions/realtime/gemini.ex`
- provider realtime helpers:
  - `lib/synaptic/voice/providers/open_ai/realtime/*`
  - `lib/synaptic/voice/providers/gemini/live/*`
- UI bridge:
  - `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
  - `tmp/voice_lab/assets/js/app.js`

Frontend-focused companion guide:
- [`docs/voice_frontend/realtime_frontend_setup.md`](../voice_frontend/realtime_frontend_setup.md)
