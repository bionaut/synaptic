# Realtime Frontend Setup Guide

This guide is frontend-only and covers both realtime provider patterns.

Realtime has two distinct frontend setups:
- OpenAI realtime (client-direct WebRTC + sideband)
- Gemini realtime (client -> your backend relay)

---

## 1. Choose the correct frontend topology

OpenAI realtime frontend:
- browser establishes WebRTC session with OpenAI
- Realtime 2.1 owns normal turns when the backend selects
  `experience: :realtime_2_1`
- legacy backend sessions retain workflow-owned conversation turns
- backend handles sideband workflow calls and emits tool outputs
- frontend forwards `realtime_send` payloads to provider data channel

Gemini realtime frontend:
- browser does not connect directly to provider
- browser sends turns/chunks to your backend
- backend talks to Gemini Live and returns normalized events

Do not try to force one transport pattern onto the other provider.

---

## 2. Common frontend session state

Track for both providers:
- `connected`, `sessionId`, `runId`
- mode/provider
- status (`connecting`, `listening`, `thinking`, `speaking`, etc.)
- transcript state
- playback state
- connection error state

---

## 3. OpenAI realtime frontend flow

1. call backend `voice_connect` with `provider=openai`, `mode=realtime`, and the
   desired experience; new applications should request `realtime_2_1`
2. receive transport bootstrap (ephemeral secret/session metadata)
3. create `RTCPeerConnection`
4. get mic stream and attach track
5. create data channel for provider events
6. POST the SDP to `https://api.openai.com/v1/realtime/calls`, authenticated
   with `transport.client_secret.value`, and apply the returned SDP answer
7. notify backend with `realtime_client_connected`
8. for provider events received client-side, send to backend via `realtime_provider_event`;
   include `response.output_item.done` so function calls reach Synaptic
9. on server `realtime_send`, forward event to provider data channel
10. on disconnect/failure, notify backend `realtime_client_disconnected`

Required frontend events:
- `realtime_connected`
- `realtime_connect_error`
- `realtime_client_connected`
- `realtime_client_disconnected`
- `realtime_provider_event`
- `realtime_disconnect`

---

## 4. Gemini realtime frontend flow

1. call backend `voice_connect` with `provider=gemini`, `mode=realtime`
2. use your existing frontend transport to backend (no provider WebRTC)
3. send audio/text turns through backend events
4. render normalized assistant events from backend

Depending on your UX you can:
- run text turns only for quick validation
- or implement streamed audio chunk relay similarly to duplex/turn-based

---

## 5. Provider outbound contract (OpenAI sideband)

Frontend must handle server push:
- `realtime_send` with payload shape `{event: provider_event}`

Frontend action:
- serialize and send `provider_event` to provider data channel exactly once, preserving order

If data channel is unavailable:
- queue briefly or fail fast and surface reconnect prompt

---

## 6. UI controls by provider

OpenAI realtime:
- button label: `Connect Voice (WebRTC)`
- show explicit `connecting` state
- include reconnect path on WebRTC failure

Gemini realtime:
- button label can remain `Start Session`
- if not streaming mic relay, provide text turn input as primary control

---

## 7. Error handling and fallback UX

OpenAI realtime:
- mic permission denied -> immediate actionable error
- SDP/WebRTC failure -> `realtime_connect_error`, keep UI recoverable
- data channel drop -> force local disconnect and show reconnect CTA

Gemini realtime:
- relay event failure -> show retry and keep session consistent
- backend session error -> show classified message and allow next turn

Common:
- never leave stale peer/media/data channel objects after failure

---

## 8. Cleanup requirements

On disconnect/unmount:
- close data channel
- close peer connection
- stop local media tracks
- clear remote audio source object
- reset local identifiers and status

Backend should also receive disconnect signal to stop/cleanup session state.

---

## 9. Frontend validation checklist

OpenAI realtime:
1. connect via WebRTC and receive assistant output
2. provider outbound messages are forwarded through data channel
3. disconnect and reconnect repeatedly without stale resources
4. mic denial and network failure paths are recoverable

Gemini realtime:
1. connect session and complete multiple turns
2. assistant responses render consistently
3. relay failures do not leave UI in broken connecting state

---

## 10. Reference paths

- realtime frontend hook implementation:
  - `tmp/voice_lab/assets/js/app.js`
- realtime server bridge:
  - `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
- realtime engines:
  - `lib/synaptic/voice/sessions/realtime/open_ai.ex`
  - `lib/synaptic/voice/sessions/realtime/gemini.ex`
