# Duplex Frontend Setup Guide

This guide focuses only on frontend implementation for Synaptic duplex voice mode.

Use when your UI must support:
- always-on microphone capture
- silence-based turn finalization
- assistant playback + barge-in
- continuous multi-turn conversations

**Interview-style (no barge-in):** If you want duplex but need to mute the mic during assistant playback (e.g. interview agents, noisy environments), see [Duplex with automatic muting](./duplex_auto_mute_setup.md). Same events; frontend gates capture on `speaking` / `awaiting_playback_drain` and does not send interrupt.

---

## 1. Frontend responsibilities

In duplex mode, frontend responsibilities are:
- open and maintain microphone capture
- run local VAD
- stream chunks when speech is present
- finalize turn after silence and flush completion
- decode and play assistant audio
- stop local playback immediately on interruption
- send playback-drained acknowledgements to backend

Backend responsibilities remain:
- lifecycle authority
- STT/TTS orchestration
- workflow resume and status events

Output timing note:
- built-in providers now default to full-turn TTS for tone consistency
- your UI may receive multiple `assistant_text_chunk` events before the first `assistant_audio_chunk`
- treat text and audio as related but independently timed streams

---

## 2. Required hook/client state

Minimum state model to track:
- connection/session: `connected`, `sessionId`, `runId`
- server status: `idle | listening | thinking | speaking | awaiting_playback_drain`
- recorder state: running/stopping/flush-pending
- VAD state: speech frames, speech start timestamp, silence timestamp
- playback state: active sources, pending decodes, done received
- interruption state: suppression generation to drop stale audio

If you use the sample app as reference:
- `tmp/voice_lab/assets/js/app.js` (`RealtimeVoice` hook)

---

## 3. Event contract (frontend -> server)

Required events for duplex path:
- `voice_connect` / `voice_disconnect`
- `duplex_audio_chunk` (`chunk_b64`, `mime_type`, `session_id`)
- `duplex_end_turn` (`session_id`)
- `duplex_interrupt` (`session_id`)
- `duplex_playback_drained` (`session_id`)
- optional diagnostics: `duplex_client_log`

Do not send `duplex_end_turn` before final chunk flush completes.

---

## 4. Event contract (server -> frontend)

Required pushes to handle:
- `duplex_audio_chunk_out`
- `duplex_audio_done`
- `duplex_output_canceled`
- status updates through `duplex_state_changed` reflected in hook data attributes
- `realtime_force_disconnect` for cleanup

Critical status semantics:
- `speaking`: assistant output in progress
- `awaiting_playback_drain`: backend waiting for client playback drain ack
- `listening`: safe to capture and forward next turn

Important:
- `speaking` can begin before any assistant audio arrives, because the backend may still be accumulating the full assistant turn for single-shot TTS

---

## 5. Capture and VAD flow

Recommended flow:
1. prime microphone once at connect
2. start recorder (`timeslice` around 200-300ms)
3. run VAD at short interval
4. buffer pre-speech chunks locally
5. once speech starts, flush pre-speech buffer and send live chunks
6. maintain short speech tail to avoid clipped endings
7. on silence threshold, stop recorder and finalize turn

Important:
- keep forwarding remaining chunks while turn is ending
- maintain a flush timeout guard so pending flushes cannot deadlock turn finalization

---

## 6. Barge-in flow (frontend only)

When VAD detects user speech during assistant output:
1. stop local playback immediately
2. suppress stale incoming assistant chunks/decodes using generation gate
3. send `duplex_interrupt`
4. keep recorder running for user speech capture
5. finalize turn through normal end-turn sequence

Do not rely only on server cancel to stop audible playback; queued local audio must be stopped client-side immediately.

---

## 7. Playback drain handshake

When assistant audio is done locally:
- send `duplex_playback_drained`

When interrupted and playback is force-stopped:
- also send `duplex_playback_drained`

This handshake is mandatory for lifecycle correctness in duplex.

---

## 8. Walkthrough of UI controls

Recommended controls:
- main toggle: `Start Session` / `Disconnect`
- optional manual `Force End Turn` for debugging
- visual status badge from server state
- transcript panels (user partial/final, assistant stream)
- optional event log during development

Do not infer status from local playback only; always sync from backend status events.
Do not infer TTS failure or stalled playback just because text has started and audio has not yet arrived.

---

## 9. Cleanup requirements

On disconnect/navigation/unmount:
- clear VAD interval
- clear recorder rotation and flush timers
- stop recorder and media tracks
- stop playback sources and release nodes
- close data channels/peer connections if present
- clear session identifiers and local speech state

Missing cleanup is a common source of phantom microphone/playback behavior.

---

## 10. Frontend validation checklist

1. First turn works, second turn works, no reconnect required
2. Silence does not continuously send upstream audio
3. End-turn sends only after final chunk flush
4. Barge-in stops audio immediately on first interrupt attempt
5. Post-barge-in response is spoken (not text-only)
6. Disconnect and reconnect leaves no stale timers/tracks

---

## 11. Reference paths

- Hook implementation:
  - `tmp/voice_lab/assets/js/app.js`
- LiveView event bridge:
  - `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
- Backend lifecycle engine:
  - `lib/synaptic/voice/sessions/headless.ex`
