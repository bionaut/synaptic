# Pure-Provider Voice Refactor: Complete Implementation Plan

## Objective

Ship a provider-switchable voice architecture with exactly two pure bundles:

- **Pure OpenAI** — headless (STT + TTS) and realtime (WebRTC + sideband)
- **Pure Gemini** — headless (STT + TTS) and realtime (Live API, server-relay WebSocket)

Selection is per-session via `provider: :openai | :gemini`. Mixed stacks are rejected.

## Current State

### Active architecture (new, partially complete)

```
lib/synaptic/voice.ex                          # Public API (delegates to Router)
lib/synaptic/voice/router.ex                   # Stack-first routing
lib/synaptic/voice/provider_registry.ex        # OpenAI: stt+tts+realtime, Gemini: tts only
lib/synaptic/voice/session_registry.ex         # Unified Registry with metadata
lib/synaptic/voice/sessions/headless.ex        # Headless engine (turn_based + duplex)
lib/synaptic/voice/sessions/realtime/open_ai.ex # OpenAI realtime engine
lib/synaptic/voice/providers/open_ai/          # OpenAI STT, TTS, Realtime adapters
lib/synaptic/voice/providers/gemini/           # Gemini TTS adapter only
lib/synaptic/voice/event.ex                    # Event envelope builder
lib/synaptic/voice/text_segmenter.ex           # TTS text chunking
lib/synaptic/voice/stt_adapter.ex              # STT behaviour
lib/synaptic/voice/tts_adapter.ex              # TTS behaviour
lib/synaptic/voice/headless_session_supervisor.ex
lib/synaptic/voice/realtime_session_supervisor.ex
```

### Stale files (old architecture, must be deleted)

```
lib/synaptic/voice/session.ex                  # Old headless session
lib/synaptic/voice/realtime.ex                 # Old realtime public API
lib/synaptic/voice/realtime/session.ex         # Old realtime session
lib/synaptic/voice/registry.ex                 # Old headless registry
lib/synaptic/voice/realtime/registry.ex        # Old realtime registry
lib/synaptic/voice/realtime/session_supervisor.ex
lib/synaptic/voice/session_supervisor.ex
lib/synaptic/voice/openai.ex                   # Old config helper
lib/synaptic/voice/openai/stt_adapter.ex       # Old STT (superseded)
lib/synaptic/voice/openai/tts_adapter.ex       # Old TTS (superseded)
lib/synaptic/voice/openai/realtime_mapper.ex   # Old event mapper (superseded)
lib/synaptic/voice/openai/realtime_sideband.ex # Old sideband (superseded)
lib/synaptic/voice/openai/webrtc_helper.ex     # Old WebRTC helper (superseded)
lib/synaptic/voice/openai/ws_helper.ex         # Old WS helper
```

### Dependencies (mix.exs)

Current: `phoenix_pubsub`, `finch`, `jason`, `yaml_elixir`, `ex_doc`, `bypass`.
No WebSocket client library present.

## Architecture Overview

### Two fundamentally different realtime patterns

```
OpenAI Realtime (client-direct + server sideband):
  Browser ←—— WebRTC media ——→ OpenAI Realtime API
  Server  ←—— WebSocket sideband ——→ OpenAI Realtime API (same session)

Gemini Realtime (server-relay):
  Browser ←—— app WebSocket ——→ Server ←—— WebSocket ——→ Gemini Live API
```

The OpenAI pattern gives the client a direct media connection to the provider.
The server controls the session through a separate sideband WebSocket.

The Gemini pattern puts the server in the media path. The server holds the
single WebSocket to Gemini Live and relays audio to/from the client through
the application's own transport. There is no Gemini sideband equivalent.

This means:
- OpenAI realtime: `client_connected`, `client_disconnected`, `ingest_provider_event` are valid
- Gemini realtime: `push_audio`, `push_text` are valid (server relays to Gemini)
- Each provider's realtime engine exposes different valid operations

### Provider bundle matrix

| Provider | Mode | STT | TTS | Realtime | Engine |
|----------|------|-----|-----|----------|--------|
| `:openai` | `:turn_based` | OpenAI transcription API | OpenAI TTS API | — | `Sessions.Headless` |
| `:openai` | `:duplex` | OpenAI transcription API | OpenAI TTS API | — | `Sessions.Headless` |
| `:openai` | `:realtime` | — | — | OpenAI Realtime API | `Sessions.Realtime.OpenAI` |
| `:gemini` | `:turn_based` | Gemini generateContent | Gemini TTS | — | `Sessions.Headless` |
| `:gemini` | `:duplex` | Gemini generateContent | Gemini TTS | — | `Sessions.Headless` |
| `:gemini` | `:realtime` | — | — | Gemini Live API | `Sessions.Realtime.Gemini` |

### Module layout after refactor

```
lib/synaptic/voice.ex                              # Public API (unchanged)
lib/synaptic/voice/router.ex                       # Provider-first routing
lib/synaptic/voice/provider_registry.ex            # Full matrix for both providers
lib/synaptic/voice/session_registry.ex             # Unchanged
lib/synaptic/voice/event.ex                        # Unchanged
lib/synaptic/voice/text_segmenter.ex               # Unchanged
lib/synaptic/voice/stt_adapter.ex                  # Unchanged
lib/synaptic/voice/tts_adapter.ex                  # Unchanged
lib/synaptic/voice/headless_session_supervisor.ex   # Unchanged
lib/synaptic/voice/realtime_session_supervisor.ex   # Unchanged
lib/synaptic/voice/sessions/headless.ex            # Unchanged (provider-agnostic)
lib/synaptic/voice/sessions/realtime/open_ai.ex    # Unchanged
lib/synaptic/voice/sessions/realtime/gemini.ex     # NEW: Gemini Live engine
lib/synaptic/voice/providers/open_ai.ex            # Unchanged
lib/synaptic/voice/providers/open_ai/stt_adapter.ex
lib/synaptic/voice/providers/open_ai/tts_adapter.ex
lib/synaptic/voice/providers/open_ai/realtime/session_bootstrap.ex
lib/synaptic/voice/providers/open_ai/realtime/event_mapper.ex
lib/synaptic/voice/providers/open_ai/realtime/sideband.ex
lib/synaptic/voice/providers/gemini.ex             # Unchanged
lib/synaptic/voice/providers/gemini/tts_adapter.ex # Unchanged
lib/synaptic/voice/providers/gemini/stt_adapter.ex # NEW: Gemini batch STT
lib/synaptic/voice/providers/gemini/live/session_bootstrap.ex  # NEW
lib/synaptic/voice/providers/gemini/live/event_mapper.ex       # NEW
lib/synaptic/voice/providers/gemini/live/connection.ex         # NEW: WebSocket
```

## Public API Changes

### New `provider` option

Add `provider: :openai | :gemini` to `start_session/3` and `attach_run/2`.

```elixir
# Pure Gemini duplex session
Synaptic.Voice.start_session(MyWorkflow, %{}, provider: :gemini, mode: :duplex)

# Pure OpenAI realtime session
Synaptic.Voice.start_session(MyWorkflow, %{}, provider: :openai, mode: :realtime)

# Provider from config default
Synaptic.Voice.start_session(MyWorkflow, %{})
```

### Stack option behavior change

The `stack` option is no longer public. If provided, it is rejected with
`{:error, {:unsupported_mode_stack, mode, stack}}` unless the caller also
passes `_allow_custom_stack: true` (test-only internal escape hatch).

The router derives the stack internally from `provider + mode`.

### Return value

Unchanged shape:
```elixir
{:ok, %{
  session_id: String.t(),
  run_id: String.t(),
  mode: :turn_based | :duplex | :realtime,
  stack: %{stt: atom() | nil, tts: atom() | nil, realtime: atom() | nil},
  transport: nil | map()
}}
```

`transport` contents vary by provider:

**OpenAI realtime:**
```elixir
%{
  provider: :openai,
  client_secret: map(),
  model: String.t(),
  voice: String.t(),
  session_id: String.t(),
  expires_at: integer()
}
```

**Gemini realtime:**
```elixir
%{
  provider: :gemini,
  model: String.t(),
  voice: String.t(),
  audio_config: %{
    input: %{mime_type: "audio/pcm;rate=16000"},
    output: %{mime_type: "audio/pcm;rate=24000"}
  }
}
```

Gemini `transport` does NOT include a WebSocket URL or token for the client.
The client connects to the application server, not to Gemini directly.
The application's own client transport (LiveView, Phoenix Channel, etc.)
is outside the scope of Synaptic.

**Headless (all providers):** `transport: nil`

### Mode-unsupported operations by provider

The valid operation set differs between realtime providers:

| Operation | Headless | OpenAI Realtime | Gemini Realtime |
|-----------|----------|-----------------|-----------------|
| `push_audio` | ok | unsupported | ok |
| `push_text` | ok | unsupported | ok |
| `end_turn` | ok | unsupported | ok |
| `cancel_output` | ok | unsupported | ok (best-effort) |
| `client_connected` | unsupported | ok | unsupported |
| `client_disconnected` | unsupported | ok | unsupported |
| `ingest_provider_event` | unsupported | ok | unsupported |

Unsupported operations return `{:error, :unsupported_for_mode}`.

Gemini realtime accepts `push_audio` because the server relays audio to
Gemini Live via the WebSocket. OpenAI realtime does not because the client
sends audio directly to OpenAI via WebRTC.

## Router Changes

### Provider-first resolution

Replace the current stack-first resolution in `resolve_session_opts/1`:

```elixir
# Current flow:
# opts[:mode] + opts[:stack] → validate → resolve provider modules

# New flow:
# opts[:provider] → derive stack from provider + mode → validate → resolve
```

Implementation:

```elixir
defp resolve_session_opts(opts) do
  config = Application.get_env(:synaptic, Synaptic.Voice, [])
  mode = Keyword.get(opts, :mode, config[:default_mode] || :duplex)
  provider = Keyword.get(opts, :provider, config[:default_provider] || :openai)

  # Reject explicit stack from public callers
  if opts[:stack] && !opts[:_allow_custom_stack] do
    {:error, {:unsupported_mode_stack, mode, opts[:stack]}}
  else
    stack_opts = derive_stack(provider, mode, opts)
    # ... rest of resolution
  end
end
```

### Stack derivation

```elixir
defp derive_stack(provider, mode, opts) when mode in [:turn_based, :duplex] do
  provider_opts = Keyword.get(opts, :provider_opts, [])
  %{
    stt: {provider, Keyword.get(provider_opts, :stt, [])},
    tts: {provider, Keyword.get(provider_opts, :tts, [])}
  }
end

defp derive_stack(provider, :realtime, opts) do
  provider_opts = Keyword.get(opts, :provider_opts, [])
  %{
    realtime: {provider, Keyword.get(provider_opts, :realtime, [])}
  }
end
```

### Engine selection

Update `engine_for/2` to accept provider:

```elixir
defp engine_for(:realtime, :openai), do: Synaptic.Voice.Sessions.Realtime.OpenAI
defp engine_for(:realtime, :gemini), do: Synaptic.Voice.Sessions.Realtime.Gemini
defp engine_for(_mode, _provider), do: Synaptic.Voice.Sessions.Headless
```

### Provider opts passthrough

Add a `provider_opts` keyword that lets callers pass provider-specific
options without using `stack`:

```elixir
Synaptic.Voice.start_session(MyWorkflow, %{},
  provider: :gemini,
  mode: :duplex,
  provider_opts: [
    tts: [voice: "Aoede"],
    stt: [model: "gemini-2.5-flash"]
  ]
)
```

## Provider Registry Changes

### Updated capability matrix

```elixir
@providers %{
  openai: %{
    stt: OpenAI.STTAdapter,
    tts: OpenAI.TTSAdapter,
    realtime: OpenAI.Realtime.SessionBootstrap
  },
  gemini: %{
    stt: Gemini.STTAdapter,
    tts: Gemini.TTSAdapter,
    realtime: Gemini.Live.SessionBootstrap
  }
}
```

Both providers now support all three roles. No other changes to the module.

## New: Gemini STT Adapter

### File: `lib/synaptic/voice/providers/gemini/stt_adapter.ex`

### Module: `Synaptic.Voice.Providers.Gemini.STTAdapter`

### Behavior

Implements `Synaptic.Voice.STTAdapter` with the same batch-on-end_turn
pattern as the OpenAI STT adapter:

1. `start_link/2` — starts GenServer, stores owner pid and opts
2. `push_audio/3` — accumulates PCM chunks in a list buffer
3. `end_turn/2` — concatenates chunks, adds WAV header, base64-encodes,
   sends to Gemini `generateContent` with inline audio and transcription
   instruction, sends `:stt_final` or `:stt_error` to owner
4. `stop/2` — stops GenServer

### Upstream API call

```elixir
# POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
body = %{
  contents: [%{
    parts: [
      %{
        inline_data: %{
          mime_type: "audio/wav",
          data: base64_wav
        }
      },
      %{
        text: "Transcribe the audio exactly as spoken. Output only the verbatim transcript text. Do not add commentary, timestamps, speaker labels, or formatting."
      }
    ]
  }]
}
```

### Model

Default: `"gemini-2.5-flash"` (fast, cheap, good enough for transcription).
Configurable via `opts[:model]` or `config[:stt_model]`.

### Audio format handling

The adapter receives raw PCM16 LE chunks at 24kHz (the session default).
Before sending to Gemini, it prepends a minimal WAV header to the
concatenated PCM data. This ensures Gemini can decode the audio format
unambiguously without relying on mime type hinting alone.

```elixir
defp wav_header(pcm_bytes, sample_rate, channels, bits_per_sample) do
  data_size = byte_size(pcm_bytes)
  byte_rate = sample_rate * channels * div(bits_per_sample, 8)
  block_align = channels * div(bits_per_sample, 8)
  <<
    "RIFF", (data_size + 36)::little-32, "WAVE",
    "fmt ", 16::little-32, 1::little-16, channels::little-16,
    sample_rate::little-32, byte_rate::little-32, block_align::little-16,
    bits_per_sample::little-16,
    "data", data_size::little-32
  >>
end
```

### Messages sent to owner

- `{:synaptic_voice, :stt_final, text, %{provider: :gemini, bytes: n, format: format, content_type: "audio/wav"}}`
- `{:synaptic_voice, :stt_error, {:empty_transcript, meta}}`
- `{:synaptic_voice, :stt_error, {:transcription_failed, reason, meta}}`

Same message protocol as OpenAI STT adapter. The headless engine handles
these identically regardless of provider.

### Known trade-off

Gemini is an LLM, not a dedicated transcription model. The transcription
instruction mitigates hallucination and commentary but is not as reliable
as OpenAI's `gpt-4o-mini-transcribe`. This is acceptable for phase 1.

## New: Gemini Live Realtime Engine

### File: `lib/synaptic/voice/sessions/realtime/gemini.ex`

### Module: `Synaptic.Voice.Sessions.Realtime.Gemini`

### Architecture

This engine manages a server-side WebSocket connection to the Gemini Live API.
Unlike the OpenAI realtime engine (where the client connects directly to the
provider), this engine is a server-relay: the server receives audio from the
client via `push_audio/3` and forwards it to Gemini through the WebSocket.

```
                    push_audio/3
 Client ──────────────────────────→ Gemini Realtime Engine
                                          │
                                    realtimeInput (WS)
                                          │
                                          ▼
                                    Gemini Live API
                                          │
                                    serverContent (WS)
                                          │
                                          ▼
                                    Gemini Realtime Engine
                                          │
                              assistant_audio_chunk (PubSub)
                                          │
                                          ▼
                                       Client
```

### WebSocket connection

Uses `WebSockex` for the WebSocket client. The connection GenServer is
embedded within the engine (not a separate process) — the engine IS the
WebSockex process.

Alternative: run the WebSocket as a child process (`Gemini.Live.Connection`)
that sends messages to the engine GenServer. This separates concerns but
adds message passing overhead for every audio chunk.

Recommendation: use a child process for cleaner separation. The engine
GenServer owns the session lifecycle; the connection GenServer owns the
WebSocket. The engine starts the connection in `init/1` and monitors it.

### Connection URL and auth

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=#{api_key}
```

Uses `v1alpha` API version (required for Live API).
API key passed as query parameter (server-side, never exposed to client).

### Init sequence

1. Router starts `Sessions.Realtime.Gemini` under `RealtimeSessionSupervisor`
2. Engine `init/1`:
   a. Resolves config from `Synaptic.Voice.Providers.Gemini`
   b. Starts `Gemini.Live.Connection` as a linked child process
   c. Connection opens WebSocket, sends setup message
   d. Connection sends `{:gemini_live, :setup_complete}` to engine
   e. Engine subscribes to run topic
   f. Engine emits `:session_started` and `:duplex_state_changed`

### Setup message (sent by Connection on connect)

```elixir
%{
  "setup" => %{
    "model" => "models/gemini-2.5-flash-native-audio-preview",
    "systemInstruction" => %{
      "parts" => [%{"text" => system_instruction}]
    },
    "generationConfig" => %{
      "responseModalities" => ["AUDIO"],
      "speechConfig" => %{
        "voiceConfig" => %{
          "prebuiltVoiceConfig" => %{"voiceName" => voice}
        }
      }
    },
    "realtimeInputConfig" => %{
      "automaticActivityDetection" => %{
        "disabled" => false
      }
    },
    "inputAudioTranscription" => %{},
    "outputAudioTranscription" => %{}
  }
}
```

Notes:
- `responseModalities: ["AUDIO"]` — Gemini responds with audio
- `inputAudioTranscription` / `outputAudioTranscription` enabled for
  transcript events used by workflow orchestration
- VAD enabled by default for natural turn detection
- System instruction sets up server orchestration mode (same pattern as
  OpenAI: "Wait for server-side orchestration...")

### Public API implementation

```elixir
def push_audio(pid, audio_chunk, opts \\ []), do: GenServer.call(pid, {:push_audio, audio_chunk, opts})
def push_text(pid, text, opts \\ []), do: GenServer.call(pid, {:push_text, text, opts})
def end_turn(pid, opts \\ []), do: GenServer.call(pid, {:end_turn, opts})
def cancel_output(pid), do: GenServer.call(pid, :cancel_output)
def client_connected(_pid, _meta), do: {:error, :unsupported_for_mode}
def client_disconnected(_pid, _meta), do: {:error, :unsupported_for_mode}
def ingest_provider_event(_pid, _payload), do: {:error, :unsupported_for_mode}
```

### Audio relay: push_audio → Gemini

When `push_audio/3` is called, the engine forwards the audio to the
connection process, which sends it to Gemini:

```elixir
# Engine handle_call
def handle_call({:push_audio, audio_chunk, _opts}, _from, state) do
  base64_audio = Base.encode64(audio_chunk)
  send(state.connection_pid, {:send_audio, base64_audio})
  {:reply, :ok, state}
end
```

The connection sends to Gemini:
```elixir
%{
  "realtimeInput" => %{
    "mediaChunks" => [%{
      "mimeType" => "audio/pcm;rate=16000",
      "data" => base64_audio
    }]
  }
}
```

Audio input to Gemini Live is 16kHz PCM. If the session default is 24kHz,
the engine must downsample before sending. However, since the client in a
server-relay pattern controls its own capture format, the engine should
accept whatever the client sends and declare the expected input format in
the `transport` payload.

Design decision: set the expected input format to 16kHz in Gemini
`transport.audio_config.input` and let the client send 16kHz audio.
No resampling in the engine.

### Receiving Gemini responses

The connection receives WebSocket frames and forwards parsed events to
the engine:

```elixir
# Connection process handles incoming frames
def handle_frame({:text, msg}, state) do
  decoded = Jason.decode!(msg)
  send(state.owner, {:gemini_live, :event, decoded})
  {:ok, state}
end
```

The engine processes events using `Gemini.Live.EventMapper`:

```elixir
def handle_info({:gemini_live, :event, payload}, state) do
  {:noreply, process_gemini_event(payload, state)}
end
```

### Event processing

Parse `serverContent` from Gemini and emit unified voice events:

```elixir
defp process_gemini_event(%{"serverContent" => content}, state) do
  state = process_model_turn(content["modelTurn"], state)
  state = process_turn_complete(content["turnComplete"], state)
  state = process_interrupted(content["interrupted"], state)
  state
end
```

**Model turn with audio:**
```elixir
# For each part with inlineData containing audio:
if not suppress_output?(state) do
  audio_chunk = Base.decode64!(inline_data["data"])
  emit(state, :assistant_audio_chunk, %{
    audio_chunk: audio_chunk,
    audio_bytes: byte_size(audio_chunk),
    provider: :gemini,
    audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
    content_type: "audio/L16"
  })
end
```

**Model turn with text:**
```elixir
emit(state, :assistant_text_chunk, %{text: text})
```

**Input transcription:**
```elixir
# When inputAudioTranscription arrives:
emit(state, :input_final_text, %{text: transcript})
```

**Turn complete:**
```elixir
state
|> Map.put(:response_active, false)
|> emit(:assistant_response_done, %{})
|> update_status(:listening)
|> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
```

**Interrupted:**
```elixir
state
|> Map.put(:response_active, false)
|> emit(:duplex_interruption, %{reason: :user_speech})
|> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
```

### Workflow orchestration

Same workflow-per-turn pattern as OpenAI realtime:

1. `input_final_text` arrives (from Gemini's input transcription)
2. Engine starts workflow task: `Task.async(fn -> run_workflow_turn(...) end)`
3. While workflow runs, suppress Gemini audio output relay (withhold, don't emit)
4. Optionally send backchannel acknowledgement via `clientContent`
5. On workflow result, inject answer via `clientContent`:

```elixir
defp deliver_workflow_result(answer, state) do
  msg = %{
    "clientContent" => %{
      "turns" => [%{
        "role" => "user",
        "parts" => [%{"text" => "Read this answer to the user: #{answer}"}]
      }],
      "turnComplete" => true
    }
  }
  send(state.connection_pid, {:send_json, msg})
  state
end
```

Note: unlike OpenAI's `response.create` which forces the model to speak
exact text, this sends a text turn that Gemini will interpret and speak.
The model may paraphrase or add context. The system instruction should
include guidance like "When given an answer to read, read it faithfully
without adding or omitting information."

### Response suppression

Gemini Live has no `response.cancel` equivalent. When suppressing:

1. Set `suppress_output: true` in state
2. Discard incoming audio chunks from Gemini (don't emit to subscribers)
3. Emit `:assistant_response_suppressed` event
4. When workflow result arrives, inject via `clientContent` — this naturally
   interrupts Gemini via VAD/turn detection

The cost: Gemini continues generating audio server-side (wasting tokens).
The server simply doesn't relay it. This is acceptable for phase 1.

### Session limits

Gemini Live audio-only sessions have a 15-minute maximum duration.
The engine should:

1. Store `session_started_at` in state
2. Set a `Process.send_after(self(), :session_timeout_warning, 14 * 60_000)`
3. On timeout warning, emit `:session_error` with `reason: :session_duration_limit`
4. Optionally: implement session resumption using Gemini's
   `SessionResumptionUpdate` token (deferred to post-phase-1)

### Backchannel for Gemini

Send a text turn with a short acknowledgement phrase:

```elixir
defp send_backchannel(state) do
  phrase = choose_backchannel_phrase(state.backchannel_phrases)
  msg = %{
    "clientContent" => %{
      "turns" => [%{
        "role" => "user",
        "parts" => [%{"text" => "Say exactly: #{phrase}"}]
      }],
      "turnComplete" => true
    }
  }
  send(state.connection_pid, {:send_json, msg})
  state |> emit(:backchannel_sent, %{text: phrase})
end
```

### Tool calls (deferred)

Gemini Live supports function calling via `BidiGenerateContentToolCall` and
`BidiGenerateContentToolResponse`. Integration with Synaptic's tool system
is deferred to a follow-up. For phase 1, no tools are declared in the setup
message.

## New: Gemini Live Connection

### File: `lib/synaptic/voice/providers/gemini/live/connection.ex`

### Module: `Synaptic.Voice.Providers.Gemini.Live.Connection`

### Responsibility

Manages the WebSocket lifecycle to Gemini Live. Receives commands from the
engine and forwards Gemini events back.

```elixir
use WebSockex

def start_link(opts) do
  owner = Keyword.fetch!(opts, :owner)
  api_key = Keyword.fetch!(opts, :api_key)
  url = "#{@gemini_ws_url}?key=#{api_key}"
  state = %{owner: owner, setup_config: Keyword.fetch!(opts, :setup_config)}
  WebSockex.start_link(url, __MODULE__, state)
end

@impl true
def handle_connect(_conn, state) do
  send(self(), {:send_json, state.setup_config})
  {:ok, state}
end

@impl true
def handle_frame({type, msg}, state) when type in [:text, :binary] do
  case Jason.decode(msg) do
    {:ok, %{"setupComplete" => _}} ->
      send(state.owner, {:gemini_live, :setup_complete})
      {:ok, state}
    {:ok, decoded} ->
      send(state.owner, {:gemini_live, :event, decoded})
      {:ok, state}
    _ ->
      {:ok, state}
  end
end

@impl true
def handle_info({:send_json, map}, state) do
  {:reply, {:text, Jason.encode!(map)}, state}
end

def handle_info({:send_audio, base64_pcm}, state) do
  msg = %{
    "realtimeInput" => %{
      "mediaChunks" => [%{"mimeType" => "audio/pcm;rate=16000", "data" => base64_pcm}]
    }
  }
  {:reply, {:text, Jason.encode!(msg)}, state}
end

@impl true
def handle_disconnect(%{reason: reason}, state) do
  send(state.owner, {:gemini_live, :disconnected, reason})
  {:ok, state}
end
```

## New: Gemini Live Event Mapper

### File: `lib/synaptic/voice/providers/gemini/live/event_mapper.ex`

### Module: `Synaptic.Voice.Providers.Gemini.Live.EventMapper`

Maps Gemini Live server events to the unified Synaptic voice event format.
Same `normalize_event/1` signature as `OpenAI.Realtime.EventMapper`.

```elixir
def normalize_event(%{"serverContent" => content}) do
  cond do
    model_turn = content["modelTurn"] ->
      normalize_model_turn(model_turn, content)
    content["turnComplete"] == true ->
      {:ok, %{event: :assistant_response_done, data: %{}}}
    content["interrupted"] == true ->
      {:ok, %{event: :duplex_interruption, data: %{reason: :speech_started}}}
    true ->
      {:ignore, :unhandled_server_content}
  end
end

def normalize_event(%{"toolCall" => tool_call}) do
  {:ok, %{event: :provider_outbound, data: %{type: :tool_call, payload: tool_call}}}
end

def normalize_event(%{"toolCallCancellation" => cancellation}) do
  {:ok, %{event: :provider_outbound, data: %{type: :tool_call_cancellation, payload: cancellation}}}
end

def normalize_event(%{"goAway" => go_away}) do
  {:ok, %{event: :session_error, data: %{source: :provider, reason: :go_away, details: go_away}}}
end

def normalize_event(%{"setupComplete" => _}) do
  {:ok, %{event: :session_ready, data: %{}}}
end

def normalize_event(_), do: {:ignore, :unknown}
```

For model turns, extract audio and text parts:

```elixir
defp normalize_model_turn(%{"parts" => parts}, content) when is_list(parts) do
  events = Enum.flat_map(parts, fn
    %{"inlineData" => %{"mimeType" => mime, "data" => data}} when is_binary(data) ->
      if String.starts_with?(mime, "audio/") do
        [{:audio, data}]
      else
        []
      end
    %{"text" => text} when is_binary(text) ->
      [{:text, text}]
    _ ->
      []
  end)

  {:ok, %{event: :model_turn_parts, data: %{parts: events, turn_complete: content["turnComplete"] == true}}}
end
```

The engine processes `:model_turn_parts` by iterating the parts list and
emitting individual `:assistant_audio_chunk` and `:assistant_text_chunk`
events. This avoids the mapper needing to know about suppression state.

## New: Gemini Live Session Bootstrap

### File: `lib/synaptic/voice/providers/gemini/live/session_bootstrap.ex`

### Module: `Synaptic.Voice.Providers.Gemini.Live.SessionBootstrap`

Unlike OpenAI's bootstrap (which creates an ephemeral session via HTTP),
Gemini's bootstrap prepares the setup config and connection options.
The actual connection happens in the engine's `init/1`.

```elixir
def create_session_config(opts \\ []) do
  config = Gemini.config(opts)
  model = Keyword.get(opts, :model, config[:live_model] || "gemini-2.5-flash-native-audio-preview")
  voice = Keyword.get(opts, :voice, config[:voice] || "Kore")
  language = Keyword.get(opts, :preferred_language, config[:preferred_language] || "en")

  instructions = Keyword.get(opts, :instructions,
    "SERVER ORCHESTRATION MODE. Wait for server-side instructions. " <>
    "Do not autonomously answer user queries. " <>
    "When given an answer to read, read it faithfully without adding or omitting information. " <>
    "Speak in #{language_name(language)}."
  )

  setup_msg = %{
    "setup" => %{
      "model" => "models/#{model}",
      "systemInstruction" => %{"parts" => [%{"text" => instructions}]},
      "generationConfig" => %{
        "responseModalities" => ["AUDIO"],
        "speechConfig" => %{
          "voiceConfig" => %{
            "prebuiltVoiceConfig" => %{"voiceName" => voice}
          }
        }
      },
      "realtimeInputConfig" => %{
        "automaticActivityDetection" => %{"disabled" => false}
      },
      "inputAudioTranscription" => %{},
      "outputAudioTranscription" => %{}
    }
  }

  transport = %{
    provider: :gemini,
    model: model,
    voice: voice,
    audio_config: %{
      input: %{mime_type: "audio/pcm;rate=16000"},
      output: %{mime_type: "audio/pcm;rate=24000"}
    }
  }

  {:ok, %{setup_message: setup_msg, transport: transport, api_key: Gemini.api_key(opts)}}
end
```

## Dependency Addition

### WebSockex

Add to `mix.exs`:

```elixir
{:websockex, "~> 0.4"}
```

WebSockex is proven with Gemini Live (reference implementation uses it),
provides a GenServer-compatible interface, and handles WebSocket frame
encoding/decoding, reconnection, and lifecycle.

Alternative considered: `Mint.WebSocket` (pure Elixir, pairs with Finch).
Rejected for phase 1 due to more boilerplate for frame handling and
connection management. Can migrate later if desired.

## Configuration Changes

### Updated voice config

```elixir
config :synaptic, Synaptic.Voice,
  default_mode: :duplex,
  default_provider: :openai,
  audio_format_default: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}
```

Remove `default_stack` from public config. The router derives it.

### Gemini config additions

```elixir
config :synaptic, Synaptic.Voice.Providers.Gemini,
  finch: Synaptic.Finch,
  # TTS
  tts_model: "gemini-2.5-flash-preview-tts",
  voice: "Kore",
  # STT (batch)
  stt_model: "gemini-2.5-flash",
  # Live (realtime)
  live_model: "gemini-2.5-flash-native-audio-preview",
  live_voice: "Kore"
```

### OpenAI config

Unchanged.

## Stale File Cleanup

Delete all 14 stale files listed in the "Current State" section.
These are dead code — no active module references them. The old registries
and supervisors are not in the application children list.

After deletion, also delete the empty directories:
- `lib/synaptic/voice/openai/`
- `lib/synaptic/voice/realtime/`

## Event Model

### Unchanged

All modes continue to use:
- Topic: `"synaptic:voice:session:" <> session_id`
- Envelope tag: `{:synaptic_voice_event, payload}`
- `Event.build/5` for envelope construction

### New events from Gemini realtime

The Gemini realtime engine emits the same event names as the OpenAI
realtime engine:

- `:session_started`
- `:session_stopped`
- `:session_error`
- `:duplex_state_changed`
- `:duplex_interruption`
- `:input_partial_text` (if Gemini provides partial input transcripts)
- `:input_final_text`
- `:assistant_audio_chunk` (Gemini audio relayed to client)
- `:assistant_audio_done`
- `:assistant_text_chunk`
- `:assistant_response_started`
- `:assistant_response_done`
- `:assistant_response_suppressed`
- `:backchannel_sent`
- `:workflow_started`
- `:workflow_canceled`
- `:provider_outbound`

Subscribers see the same event stream regardless of provider.

### Gemini-specific event data

`:assistant_audio_chunk` from Gemini includes:
```elixir
%{
  audio_chunk: binary(),
  audio_bytes: integer(),
  provider: :gemini,
  audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
  content_type: "audio/L16"
}
```

Same shape as headless Gemini TTS chunks. Subscribers handle both
identically.

## Telemetry

### New spans

Add Gemini realtime telemetry mirroring OpenAI:

- `[:synaptic, :voice, :realtime, :session, :start]`
- `[:synaptic, :voice, :realtime, :session, :stop]`
- `[:synaptic, :voice, :realtime, :workflow, :start]`
- `[:synaptic, :voice, :realtime, :workflow, :stop]`
- `[:synaptic, :voice, :realtime, :workflow, :cancel]`
- `[:synaptic, :voice, :realtime, :backchannel, :sent]`
- `[:synaptic, :voice, :realtime, :interrupt]`

All include `realtime_provider: :gemini` in metadata.

### Router telemetry update

Add `provider` to router telemetry metadata:

```elixir
%{mode: mode, provider: provider, stt_provider: ..., tts_provider: ..., realtime_provider: ...}
```

## Test Plan

### 1. Router and provider validation

```
test "provider: :openai, mode: :turn_based succeeds"
test "provider: :openai, mode: :duplex succeeds"
test "provider: :openai, mode: :realtime succeeds"
test "provider: :gemini, mode: :turn_based succeeds"
test "provider: :gemini, mode: :duplex succeeds"
test "provider: :gemini, mode: :realtime succeeds"
test "unknown provider fails before child start"
test "explicit stack is rejected without escape hatch"
test "explicit stack with _allow_custom_stack passes"
test "validation occurs before child start"
test "provider: :openai never resolves Gemini modules"
test "provider: :gemini never resolves OpenAI modules"
test "default provider from config is used when omitted"
```

### 2. Mode-unsupported operations

```
test "push_audio on OpenAI realtime returns :unsupported_for_mode"
test "push_text on OpenAI realtime returns :unsupported_for_mode"
test "client_connected on headless returns :unsupported_for_mode"
test "ingest_provider_event on headless returns :unsupported_for_mode"
test "client_connected on Gemini realtime returns :unsupported_for_mode"
test "push_audio on Gemini realtime succeeds"
```

### 3. Gemini STT adapter

```
test "successful transcription returns stt_final"
test "empty transcript returns stt_error"
test "upstream HTTP error returns stt_error"
test "WAV header is prepended to PCM data"
test "metadata includes provider: :gemini"
test "chunks are accumulated and cleared after end_turn"
```

### 4. Gemini TTS adapter (existing, extend)

```
test "cancel_output suppresses in-flight synthesis"
test "flush emits tts_done"
test "upstream error emits tts_error"
```

### 5. Gemini realtime engine

```
test "start_session returns transport with provider: :gemini"
test "push_audio relays to Gemini connection"
test "input transcription triggers workflow"
test "workflow result is injected via clientContent"
test "backchannel sends clientContent acknowledgement"
test "response suppression withholds audio during workflow"
test "turn_complete emits assistant_response_done"
test "interrupted emits duplex_interruption"
test "unified event envelope and topic"
test "session_started includes mode, stack, transport"
test "session cleanup on stop"
```

### 6. Pure-bundle enforcement

```
test "provider: :gemini headless resolves only Gemini STT and TTS"
test "provider: :openai headless resolves only OpenAI STT and TTS"
test "provider: :gemini realtime resolves Gemini Live bootstrap"
test "provider: :openai realtime resolves OpenAI bootstrap"
```

### 7. Regression

```
test "existing OpenAI headless tests pass"
test "existing OpenAI realtime tests pass"
test "existing Gemini TTS tests pass"
test "router validation tests pass"
test "event and text segmenter tests pass"
```

## Implementation Sequence

### Phase 1: Cleanup and provider-first routing

1. Delete all 14 stale files
2. Delete empty `openai/` and `realtime/` directories
3. Update `Router` to accept `provider` option and derive stack
4. Reject explicit `stack` from public callers
5. Add `default_provider` to config
6. Update router telemetry to include provider
7. Run existing tests — all should pass with adapter overrides

### Phase 2: Gemini STT adapter

1. Create `Synaptic.Voice.Providers.Gemini.STTAdapter`
2. Update `ProviderRegistry` to add Gemini STT role
3. Add WAV header helper
4. Add tests with Bypass mock
5. Verify pure Gemini headless session works end-to-end

### Phase 3: Gemini Live realtime engine

1. Add `websockex` dependency to `mix.exs`
2. Create `Gemini.Live.Connection` (WebSockex process)
3. Create `Gemini.Live.EventMapper`
4. Create `Gemini.Live.SessionBootstrap`
5. Create `Sessions.Realtime.Gemini` engine
6. Update `ProviderRegistry` to add Gemini realtime role
7. Update `Router.engine_for/2` to handle `(:realtime, :gemini)`
8. Add tests with mock WebSocket (or Bypass for bootstrap)

### Phase 4: Config and docs

1. Update `config/config.exs` with new Gemini config keys
2. Remove `default_stack` from config
3. Update `VOICE.md` — document pure bundles, provider option, Gemini support
4. Update `TECHNICAL.md` — update voice subsystem section
5. Update `README.md` — update voice examples

### Phase 5: Verification

1. Run full test suite
2. Manual verification with real Gemini API (if keys available)
3. Manual verification with real OpenAI API (if keys available)

## Assumptions and Constraints

- Gemini Live API is accessed via `v1alpha` WebSocket with API key auth
- Server-relay is the correct pattern for Gemini Live (no sideband exists)
- Gemini Live input audio is 16kHz PCM, output is 24kHz PCM
- Gemini Live sessions have a 15-minute audio-only limit
- Gemini batch STT via `generateContent` is acceptable for phase 1 despite
  being LLM-based rather than a dedicated transcription model
- No Gemini function/tool calling integration in phase 1
- No session resumption for Gemini Live in phase 1
- No ephemeral tokens for Gemini in phase 1 (server holds API key)
- Clean break from mixed-stack API is acceptable (alpha library)
- WebSockex is an acceptable dependency for WebSocket client
- Backchannel and workflow result injection via `clientContent` turns
  rely on the model following system instruction faithfully
