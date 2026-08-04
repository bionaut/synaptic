defmodule Synaptic.Voice.Providers.OpenAI.Realtime.SessionBootstrap do
  @moduledoc false

  alias Synaptic.Voice.Providers.OpenAI

  @legacy_endpoint "https://api.openai.com/v1/realtime/sessions"
  @client_secret_endpoint "https://api.openai.com/v1/realtime/client_secrets"

  @legacy_instructions "Wait for server-side orchestration. Do not autonomously answer user queries."

  @native_instructions """
  You are Synaptic, a warm, attentive realtime voice assistant.
  Speak naturally and directly, with conversational rhythm, brief acknowledgements, and appropriate emotion.
  Keep ordinary replies concise. Let the user finish speaking and stop immediately when interrupted.
  You may laugh or react naturally when the moment genuinely calls for it, but never force mannerisms.
  Never claim to be human or claim an external action succeeded without a tool result.
  Use the synaptic_workflow tool only when the request needs current external data, repository lookup, or an application action.
  After a tool result, preserve its facts but phrase the answer naturally in your own voice instead of reading the result verbatim.
  Mirror the user's language; default to English.
  """

  @orchestrated_instructions """
  Wait for server-side orchestration. Do not autonomously answer user queries.
  Stay silent unless a server response.create event instructs you to speak.
  """

  @spec create_client_secret(keyword()) :: {:ok, map()} | {:error, term()}
  def create_client_secret(opts \\ []) do
    config = OpenAI.config(opts)
    experience = normalize_experience(Keyword.get(opts, :experience, :realtime_2_1))

    response_mode =
      normalize_response_mode(
        Keyword.get(opts, :response_mode, default_response_mode(experience, config))
      )

    instructions = Keyword.get(opts, :instructions, default_instructions(response_mode))

    transcription_language = Keyword.get(opts, :transcription_language)

    input_audio_transcription =
      %{
        model: transcription_model(opts, config, experience, response_mode)
      }
      |> maybe_put(:language, transcription_language)

    input_audio =
      %{
        transcription: input_audio_transcription,
        turn_detection: turn_detection(opts, config, experience, response_mode)
      }
      |> maybe_put(:noise_reduction, noise_reduction(opts, config, experience, response_mode))

    session =
      %{
        type: "realtime",
        model:
          Keyword.get(
            opts,
            :model,
            default_model(experience, config)
          ),
        output_modalities: ["audio"],
        instructions: instructions,
        audio: %{
          input: input_audio,
          output: %{
            voice: Keyword.get(opts, :voice, default_voice(experience, config))
          }
        }
      }
      |> maybe_put_reasoning(opts, experience)
      |> maybe_put_native_tools(opts, response_mode)

    body = Jason.encode!(%{session: session})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> OpenAI.api_key(opts)}
    ]

    request_json(client_secret_endpoint(opts), headers, body, opts)
  end

  @spec create_ephemeral_session(keyword()) :: {:ok, map()} | {:error, term()}
  def create_ephemeral_session(opts \\ []) do
    config = OpenAI.config(opts)

    instructions = Keyword.get(opts, :instructions, @legacy_instructions)
    transcription_language = Keyword.get(opts, :transcription_language)

    input_audio_transcription =
      %{
        model:
          Keyword.get(opts, :transcription_model, config[:stt_model] || "gpt-4o-mini-transcribe")
      }
      |> maybe_put(:language, transcription_language)

    body =
      Jason.encode!(%{
        model:
          Keyword.get(
            opts,
            :model,
            config[:realtime_model] || "gpt-4o-realtime-preview"
          ),
        voice: Keyword.get(opts, :voice, config[:voice] || "alloy"),
        modalities: ["audio", "text"],
        instructions: instructions,
        turn_detection: %{
          type: "server_vad",
          create_response: false,
          interrupt_response: true
        },
        input_audio_transcription: input_audio_transcription
      })

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> OpenAI.api_key(opts)}
    ]

    request_json(legacy_endpoint(opts), headers, body, opts)
  end

  @spec create_browser_bootstrap(keyword()) :: {:ok, map()} | {:error, term()}
  def create_browser_bootstrap(opts \\ []) do
    experience = normalize_experience(Keyword.get(opts, :experience, :legacy))

    create_session =
      case experience do
        :legacy -> &create_ephemeral_session/1
        :realtime_2_1 -> &create_client_secret/1
      end

    with {:ok, response} <- create_session.(Keyword.put(opts, :experience, experience)) do
      session = Map.get(response, "session", response)

      {:ok,
       %{
         provider: :openai,
         experience: experience,
         client_secret: normalize_client_secret(response),
         model: Map.get(session, "model", Keyword.get(opts, :model)),
         voice:
           get_in(session, ["audio", "output", "voice"]) ||
             Map.get(session, "voice", Keyword.get(opts, :voice)),
         session_id: Map.get(session, "id"),
         expires_at: Map.get(response, "expires_at", Map.get(session, "expires_at")),
         session: session
       }}
    end
  end

  defp legacy_endpoint(opts),
    do: opts[:endpoint] || OpenAI.config(opts)[:webrtc_endpoint] || @legacy_endpoint

  defp client_secret_endpoint(opts),
    do:
      opts[:endpoint] || OpenAI.config(opts)[:client_secret_endpoint] ||
        @client_secret_endpoint

  defp maybe_put_reasoning(session, opts, experience) do
    config = OpenAI.config(opts)

    configured_effort =
      case experience do
        :legacy -> config[:realtime_reasoning_effort]
        :realtime_2_1 -> config[:realtime_2_1_reasoning_effort]
      end

    case Keyword.get(opts, :reasoning_effort, configured_effort) do
      effort when effort in ["minimal", "low", "medium", "high", "xhigh"] ->
        Map.put(session, :reasoning, %{effort: effort})

      _ ->
        session
    end
  end

  defp maybe_put_native_tools(session, opts, :native) do
    tools =
      Keyword.get(opts, :tools, [
        %{
          type: "function",
          name: "synaptic_workflow",
          description:
            "Delegate requests that require current external data, repository lookup, or an application action to the Synaptic workflow.",
          parameters: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "A complete, self-contained description of the work to perform."
              }
            },
            required: ["query"],
            additionalProperties: false
          }
        }
      ])

    session
    |> maybe_put(:tools, tools)
    |> maybe_put(:tool_choice, if(tools == [], do: nil, else: "auto"))
    |> maybe_put(:parallel_tool_calls, if(tools == [], do: nil, else: false))
  end

  defp maybe_put_native_tools(session, _opts, :orchestrated), do: session

  defp transcription_model(opts, config, :realtime_2_1, :native) do
    Keyword.get(
      opts,
      :transcription_model,
      config[:realtime_2_1_transcription_model] || "gpt-realtime-whisper"
    )
  end

  defp transcription_model(opts, config, _experience, _response_mode) do
    Keyword.get(opts, :transcription_model, config[:stt_model] || "gpt-4o-mini-transcribe")
  end

  defp turn_detection(opts, config, :realtime_2_1, :native) do
    case Keyword.get(
           opts,
           :turn_detection,
           config[:realtime_2_1_turn_detection] || "semantic_vad"
         ) do
      "server_vad" ->
        %{
          type: "server_vad",
          create_response: true,
          interrupt_response: true
        }

      _ ->
        %{
          type: "semantic_vad",
          eagerness:
            Keyword.get(opts, :turn_eagerness, config[:realtime_2_1_turn_eagerness] || "low"),
          create_response: true,
          interrupt_response: true
        }
    end
  end

  defp turn_detection(_opts, _config, _experience, response_mode) do
    %{
      type: "server_vad",
      create_response: response_mode == :native,
      interrupt_response: true
    }
  end

  defp noise_reduction(opts, config, :realtime_2_1, :native) do
    case Keyword.get(
           opts,
           :noise_reduction,
           config[:realtime_2_1_noise_reduction] || "near_field"
         ) do
      type when type in ["near_field", "far_field"] -> %{type: type}
      _ -> nil
    end
  end

  defp noise_reduction(_opts, _config, _experience, _response_mode), do: nil

  defp default_model(:legacy, config),
    do: config[:realtime_model] || "gpt-4o-realtime-preview"

  defp default_model(:realtime_2_1, config),
    do: config[:realtime_2_1_model] || "gpt-realtime-2.1"

  defp default_voice(:legacy, config), do: config[:voice] || "alloy"
  defp default_voice(:realtime_2_1, config), do: config[:realtime_2_1_voice] || "marin"

  defp default_response_mode(:legacy, config),
    do: config[:realtime_response_mode] || :orchestrated

  defp default_response_mode(:realtime_2_1, config),
    do: config[:realtime_2_1_response_mode] || :native

  defp default_instructions(:native), do: @native_instructions
  defp default_instructions(:orchestrated), do: @orchestrated_instructions

  defp normalize_response_mode(:orchestrated), do: :orchestrated
  defp normalize_response_mode("orchestrated"), do: :orchestrated
  defp normalize_response_mode(_), do: :native

  defp normalize_experience(:legacy), do: :legacy
  defp normalize_experience("legacy"), do: :legacy
  defp normalize_experience(:realtime_2_1), do: :realtime_2_1
  defp normalize_experience("realtime_2_1"), do: :realtime_2_1

  defp normalize_experience(value) do
    raise ArgumentError, "unsupported OpenAI realtime experience: #{inspect(value)}"
  end

  defp normalize_client_secret(%{"value" => value}) when is_binary(value),
    do: %{"value" => value}

  defp normalize_client_secret(response), do: Map.get(response, "client_secret", %{})

  defp request_json(endpoint, headers, body, opts) do
    request = Finch.build(:post, endpoint, headers, body)

    case Finch.request(request, OpenAI.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
