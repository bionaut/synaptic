# Duplex Mode Setup Guide

This guide explains how to implement a production-style duplex voice loop with Synaptic.

Duplex mode is best when you want:
- continuous microphone capture
- automatic end-of-turn by VAD/silence
- barge-in (user interrupt while assistant is speaking)
- backend-orchestrated STT/TTS and workflow control

---

## 1. Architecture and ownership

In duplex mode:
- your client owns: microphone, VAD, playback UX
- Synaptic owns: session lifecycle, STT/TTS adapters, workflow resume, normalized events

Key server module path:
- `Synaptic.Voice.Sessions.Headless` (`mode: :duplex`)

Key lifecycle notes:
- `workflow_waiting_for_human` does not automatically mean "safe to listen"
- listening turn entry is gated by output completion and playback drain
- interruptions should call `cancel_output`, not regular `end_turn`

---

## 2. Prerequisites

Server:
- `OPENAI_API_KEY` for OpenAI duplex
- `GEMINI_API_KEY` for Gemini duplex
- `Synaptic.Voice` config set (provider defaults optional, per-session overrides supported)

Client:
- `getUserMedia` microphone permission
- `MediaRecorder` support (or equivalent capture pipeline)
- `AudioContext` playback capability

---

## 3. Session bootstrap

Start a session from your server boundary (controller/live view/channel):

```elixir
{:ok, %{session_id: session_id, run_id: run_id}} =
  Synaptic.Voice.start_session(MyWorkflow, %{},
    provider: :openai,   # or :gemini
    mode: :duplex,
    keep_alive: true
  )

:ok = Synaptic.Voice.subscribe_session(session_id)
:ok = Synaptic.subscribe(run_id)
```

Session payloads you should track per client:
- `session_id`
- `run_id`
- current `status` from `:duplex_state_changed`

---

## 4. Client capture and end-turn protocol

Recommended capture loop:
1. open microphone stream once
2. start recorder with short timeslices (for example 200-300ms)
3. run local VAD to decide speech/noise/silence
4. push speech chunks with `duplex_audio_chunk`
5. when silence threshold is met, stop recorder and finalize turn

Important protocol detail:
- never send `duplex_end_turn` before final recorder chunks have flushed
- wait for recorder stop + pending chunk flush completion
- include a timeout guard to avoid hanging if flush completion never arrives

Why:
- incomplete WebM/Opus container upload can trigger STT 400 invalid/corrupted audio errors

---

## 5. Barge-in protocol

When user speech is detected during assistant output:
1. stop local playback immediately
2. send interrupt event (`duplex_interrupt`)
3. server calls `Synaptic.Voice.cancel_output(session_id)`
4. continue capturing user speech
5. finalize interrupted user turn with normal end-turn flow

Do not treat barge-in as regular silence-based end-turn only. It must go through cancel-output semantics to keep lifecycle clean.

---

## 6. Required server events to handle

From `{:synaptic_voice_event, envelope}`:
- `:duplex_state_changed` -> drive UI status
- `:input_partial_text` / `:input_final_text` -> transcript
- `:assistant_text_chunk` / `:assistant_text_done` -> assistant transcript stream
- `:assistant_audio_chunk` / `:assistant_audio_done` -> playback
- `:duplex_interruption` -> interruption telemetry/UX
- `:session_error` -> recoverable errors and user messaging
- `:session_stopped` -> teardown

For playback drain gating:
- send a client ack back (`duplex_playback_drained`) after audio is actually drained locally

---

## 7. Error handling and recovery defaults

Recommended user-facing classification:
- `source: :stt` + `empty_transcript` -> "No speech recognized. Please try again."
- `source: :stt` + `transcription_failed` -> "No voice detected. Please try again."
- `source: :tts` -> "Audio output failed. Please try again."
- `source: :resume` -> "Unable to continue the conversation. Please try again."

Recovery behavior:
- keep session alive unless stop/terminal error
- transition to listening when recoverable
- clear turn flags on STT/TTS/resume error paths

---

## 8. Lifecycle checklist

Before shipping duplex:
- confirm assistant playback drain ack is wired and received
- confirm end-turn flush waits for final recorder chunk
- confirm barge-in uses `cancel_output` path
- confirm client suppresses stale audio after interrupt
- confirm next-turn TTS still plays after cancel
- confirm no atom creation from client log/event names
- confirm teardown clears timers, streams, and audio nodes

---

## 9. Verification checklist

Run these scenarios end-to-end:
1. normal turn 1 -> turn 2 -> turn 3 without reconnect
2. long assistant response interrupted early by barge-in
3. interrupted user question returns spoken (not text-only) answer
4. silence does not continuously flood upstream processing
5. transient STT/TTS failure recovers back to usable listening state

---

## 10. Reference implementation

See internal sample app:
- `tmp/voice_lab`

Core files:
- server bridge: `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
- client hook: `tmp/voice_lab/assets/js/app.js`
- core session engine: `lib/synaptic/voice/sessions/headless.ex`

Frontend-focused companion guide:
- [`docs/voice_frontend/duplex_frontend_setup.md`](../voice_frontend/duplex_frontend_setup.md)
