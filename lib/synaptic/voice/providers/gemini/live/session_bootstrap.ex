defmodule Synaptic.Voice.Providers.Gemini.Live.SessionBootstrap do
  @moduledoc false

  alias Synaptic.Voice.Providers.Gemini

  @default_instructions """
  SERVER ORCHESTRATION MODE.
  Wait for server-side orchestration.
  Do not autonomously answer user queries.
  When given an answer to read, read it faithfully without adding or omitting information.
  """

  @spec create_session_config(keyword()) :: {:ok, map()} | {:error, term()}
  def create_session_config(opts \\ []) do
    model = Keyword.get(opts, :model, Gemini.live_model(opts))
    voice = Keyword.get(opts, :voice, Gemini.live_voice(opts))

    instructions =
      Keyword.get(opts, :instructions, @default_instructions)
      |> String.trim()

    setup_message = %{
      "setup" => %{
        "model" => "models/#{model}",
        "systemInstruction" => %{
          "parts" => [%{"text" => instructions}]
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

    transport = %{
      provider: :gemini,
      model: model,
      voice: voice,
      audio_config: %{
        input: %{mime_type: "audio/pcm;rate=16000"},
        output: %{mime_type: "audio/pcm;rate=24000"}
      }
    }

    {:ok,
     %{
       setup_message: setup_message,
       transport: transport,
       api_key: Gemini.api_key(opts),
       ws_endpoint: Gemini.live_ws_endpoint(opts)
     }}
  end
end
