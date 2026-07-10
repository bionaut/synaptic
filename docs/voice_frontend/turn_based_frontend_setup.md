# Turn-based Frontend Setup Guide

This guide is frontend-only and focuses on push-to-talk (walkie-talkie) UX.

Use when you want:
- explicit user press-to-talk/stop controls
- deterministic turn boundaries
- simpler UX than duplex

---

## 1. Core UX model (walkie-talkie)

Recommended control pattern:
- button idle: `Start Talking`
- button active: `Stop & Send`
- button disabled while flush/finalization in progress

State machine:
- `idle`
- `capturing`
- `stopping`
- `finalizing`
- `ready`

Do not allow rapid toggle spam while in `stopping` or `finalizing`.

---

## 2. Required frontend events

Frontend -> server:
- `voice_connect` / `voice_disconnect`
- `turn_based_audio_chunk`
- `turn_based_end_turn`

Server -> frontend:
- `duplex_state_changed` (reuse status channel for consistency)
- `assistant_audio_chunk` + `assistant_audio_done` push path
- `session_error` via status/error assign updates

Even though the event name says `duplex_state_changed`, use it as the authoritative mode-agnostic status signal.

Timing note:
- built-in providers now default to full-turn TTS for tone consistency
- the UI may receive `assistant_text_chunk` updates before any `assistant_audio_chunk`
- do not assume audio begins at the first text chunk

---

## 3. Recorder flow

On Start Talking:
1. acquire mic stream (or reuse existing stream)
2. create recorder with stable mime type
3. set `capturing=true`
4. send chunks as they arrive

On Stop & Send:
1. stop recorder
2. wait for final `dataavailable` completion
3. if at least one chunk was sent, trigger `turn_based_end_turn`
4. if zero chunks, skip end-turn and return to idle

Always gate turn finalization on pending chunk flush completion.

---

## 4. Playback behavior

Turn-based mode still needs assistant playback handling:
- decode assistant chunks
- schedule playback
- reset speech state when done

Because audio may start later than transcript streaming, keep the UI in a processing/thinking state until playback actually begins or completes.

If user starts a new turn while assistant is speaking:
- optionally send cancel-output path before ending user turn (server bridge can enforce this)

---

## 5. UI and feedback requirements

Must show:
- connection status
- recording status
- processing/thinking status
- current error (if any)

Should show:
- mic permission failures with actionable message
- transcript history (user and assistant)

---

## 6. Error handling defaults

Client-side:
- recorder/mic errors should stop capture cleanly and reset button state
- chunk encode failures should be logged and should not leave capture stuck

Server-side surfaced errors:
- STT failures: allow immediate retry
- TTS failures: keep transcript visible, session alive
- resume/workflow failures: keep session alive and return to ready state

---

## 7. Cleanup on unmount/disconnect

Required teardown:
- stop active recorder
- stop media tracks
- clear UI timers
- reset turn-based capture flags
- clear session identifiers

This prevents stuck “recording” UI after route changes.

---

## 8. Frontend validation checklist

1. Start Talking -> Stop & Send produces one complete turn
2. Repeat for multiple turns without reconnect
3. Stop with zero chunks does not call end-turn
4. Button state always returns to idle after success/error
5. Disconnect during capture performs clean teardown
6. Text can stream before audio without breaking loading/playback UI

---

## 9. Reference paths

- turn-based capture logic:
  - `tmp/voice_lab/assets/js/app.js`
- server event bridge:
  - `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
