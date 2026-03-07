# Turn-based Mode Setup Guide

This guide explains how to implement explicit push-to-talk turns with Synaptic.

Turn-based mode is best when you want:
- deterministic user-controlled turn boundaries
- simpler UX than duplex
- less VAD tuning and less interruption complexity

---

## 1. Architecture and ownership

In turn-based mode:
- client owns when recording starts/stops
- server owns STT/TTS orchestration and workflow state
- turn completion is explicit via `end_turn`

Headless output note:
- built-in providers now default to one TTS generation per assistant turn for more consistent tone
- assistant text can stream before audio starts; audio may begin only after the assistant turn is fully generated
- segmented per-sentence TTS remains the fallback path for adapters without capability metadata

Session engine:
- `Synaptic.Voice.Sessions.Headless` (`mode: :turn_based`)

---

## 2. Prerequisites

Server:
- provider API key(s): `OPENAI_API_KEY`, `GEMINI_API_KEY`, and/or `ELEVENLABS_API_KEY`
- Synaptic voice provider config

Client:
- mic capture support (`getUserMedia`)
- recorder support (`MediaRecorder` or equivalent)

---

## 3. Session bootstrap

```elixir
{:ok, %{session_id: session_id, run_id: run_id}} =
  Synaptic.Voice.start_session(MyWorkflow, %{},
    provider: :gemini,   # or :openai / :eleven_labs
    mode: :turn_based,
    keep_alive: true
  )

:ok = Synaptic.Voice.subscribe_session(session_id)
:ok = Synaptic.subscribe(run_id)
```

Track:
- `session_id`
- `run_id`
- current `status` via session events

---

## 4. Push-to-talk protocol

Recommended client flow:
1. user presses/starts talking -> start recorder
2. stream chunks via `push_audio`
3. user releases/stops talking -> stop recorder
4. wait for final chunk flush
5. call `end_turn`

Important:
- same as duplex, wait for final chunk flush before end-turn to avoid corrupted container uploads
- do not call `end_turn` repeatedly for the same turn

---

## 5. Optional text turn path

Turn-based mode supports text-only turns cleanly:

```elixir
:ok = Synaptic.Voice.push_text(session_id, "How many stars does React have?")
:ok = Synaptic.Voice.end_turn(session_id)
```

Use this for:
- fallback when mic permission fails
- quick integration testing
- accessibility modes

---

## 6. Required server events to handle

From voice session PubSub:
- `:input_partial_text`
- `:input_final_text`
- `:assistant_text_chunk`
- `:assistant_audio_chunk`
- `:assistant_audio_done`
- `:duplex_state_changed` (still useful for status rendering consistency)
- `:session_error`
- `:session_stopped`

Even in turn-based mode, build status-driven UI and do not infer state from local assumptions only.

In particular, do not assume the first `:assistant_audio_chunk` arrives immediately after the first `:assistant_text_chunk`.

---

## 7. Error handling defaults

Minimum recommended behavior:
- empty transcript -> show retry hint, keep session alive
- STT upstream failure -> keep session alive, reset recording UI to idle
- TTS failure -> show text response path so user still gets output
- resume/workflow error -> keep session alive, allow next turn

For all recoverable errors, ensure your UI can start a fresh turn without reconnect.

---

## 8. UX and safety recommendations

- show explicit recording state (`idle`, `recording`, `processing`)
- disable start/stop button while final chunks are flushing
- prevent double-submit of `end_turn`
- always stop tracks and recorder on disconnect/navigation

---

## 9. Verification checklist

Run these scenarios:
1. start/stop one voice turn -> spoken answer
2. two consecutive turns without reconnect
3. text turn followed by voice turn in same session
4. stop session and reconnect cleanly
5. simulate STT failure and confirm next turn still works
6. assistant text streams first and audio starts only after turn completion

---

## 10. Reference implementation

Internal sample:
- `tmp/voice_lab` (Turn-based mode)

Relevant files:
- `tmp/voice_lab/lib/voice_lab_web/live/home_live.ex`
- `tmp/voice_lab/assets/js/app.js`
- `lib/synaptic/voice/sessions/headless.ex`

Frontend-focused companion guide:
- [`docs/voice_frontend/turn_based_frontend_setup.md`](../voice_frontend/turn_based_frontend_setup.md)
