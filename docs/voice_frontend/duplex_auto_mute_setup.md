# Duplex with Automatic Muting (Interview-Style)

This guide describes how to use **duplex mode** with **automatic mic muting during playback**. Use it when you want:

- No push-to-talk button (hands-free like duplex)
- No accidental interrupts from ambient noise (coughs, other people talking) while the assistant is speaking
- Mic automatically on when the assistant finishes, off while they are speaking

Same backend as standard duplex; only the frontend capture and barge-in behavior change.

---

## 1. When to use

- **Interview agents**: interviewer agent asks a question, then the user answers without touching the keyboard.
- **Presentations / guided flows**: assistant speaks, then user responds; you do not want background noise to cut off the assistant.

Standard duplex is better when you want true barge-in (user can interrupt the assistant at any time).

---

## 2. Core idea

- **Backend**: unchanged. Use the same duplex session, events, and `duplex_state_changed` status.
- **Frontend**:
  - While status is `speaking` or `awaiting_playback_drain`: **mute** — do not send any `duplex_audio_chunk` and do not send `duplex_interrupt`. Optionally keep the recorder running but discard chunks, or pause capture entirely.
  - When status becomes `listening`: **unmute** — resume sending chunks and normal silence-based end-turn.

So: duplex with automatic muting = duplex + “mic off during playback, mic on when listening.”

---

## 3. Status-driven muting

Drive muting from the server status you already receive via `duplex_state_changed`:

| Status                     | Mic behavior |
|----------------------------|--------------|
| `listening`                | **Unmuted** — capture, VAD, send chunks, end-turn on silence. |
| `thinking`                 | Muted (optional; no assistant audio yet). |
| `speaking`                 | **Muted** — do not send chunks; do not interrupt. |
| `awaiting_playback_drain`  | **Muted** — same as above until you send `duplex_playback_drained`. |

When status transitions from `speaking` or `awaiting_playback_drain` to `listening`, unmute and start sending chunks again.

---

## 4. Implementation checklist

1. **Reuse duplex setup**  
   Same connection, `duplex_audio_chunk`, `duplex_end_turn`, `duplex_playback_drained`, and playback pipeline as in [duplex_frontend_setup.md](./duplex_frontend_setup.md).

2. **Gate capture on status**  
   - If status is `speaking` or `awaiting_playback_drain`: do not send any `duplex_audio_chunk` (and do not call `duplex_interrupt`).  
   - You can either stop the recorder while muted or keep it running and drop chunks; stopping avoids unnecessary CPU.

3. **Do not implement barge-in**  
   - Ignore user speech for interrupt purposes while status is not `listening`.  
   - Do not call `duplex_interrupt` in this mode.

4. **Playback unchanged**  
   - Decode and play assistant audio as in duplex.  
   - When playback is done (and when you force-stop on disconnect), send `duplex_playback_drained` so the backend can move to `listening`.

5. **Unmute only on `listening`**  
   - When `duplex_state_changed` reports `listening`, (re)start capture and allow chunks and end-turn again.

---

## 5. Optional: thinking

You can also mute during `thinking` so no stray audio is sent before the assistant speaks. If you do, unmute only when status is `listening`.

---

## 6. Reference

- Duplex frontend contract and events: [duplex_frontend_setup.md](./duplex_frontend_setup.md)
- Backend duplex lifecycle: [../voice_modes/duplex_setup.md](../voice_modes/duplex_setup.md)
