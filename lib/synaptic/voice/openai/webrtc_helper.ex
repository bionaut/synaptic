defmodule Synaptic.Voice.OpenAI.WebRTCHelper do
  @moduledoc """
  WebRTC session helper utilities for creating OpenAI ephemeral sessions and
  normalizing events.
  """

  alias Synaptic.Voice.OpenAI

  @default_endpoint "https://api.openai.com/v1/realtime/sessions"

  @spec create_ephemeral_session(keyword()) :: {:ok, map()} | {:error, term()}
  def create_ephemeral_session(opts \\ []) do
    instructions =
      Keyword.get(
        opts,
        :instructions,
        "Wait for server-side orchestration. Do not autonomously answer user queries."
      )

    transcription_language = Keyword.get(opts, :transcription_language)

    input_audio_transcription =
      %{
        model: OpenAI.config(opts)[:stt_model] || "gpt-4o-mini-transcribe"
      }
      |> maybe_put(:language, transcription_language)

    body =
      Jason.encode!(%{
        model:
          Keyword.get(
            opts,
            :model,
            OpenAI.config(opts)[:realtime_model] || "gpt-4o-realtime-preview"
          ),
        voice: Keyword.get(opts, :voice, OpenAI.config(opts)[:voice] || "alloy"),
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

    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, OpenAI.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a browser bootstrap payload for direct WebRTC media setup.
  """
  @spec create_browser_bootstrap(keyword()) :: {:ok, map()} | {:error, term()}
  def create_browser_bootstrap(opts \\ []) do
    with {:ok, session} <- create_ephemeral_session(opts) do
      {:ok,
       %{
         client_secret: Map.get(session, "client_secret", %{}),
         model: Map.get(session, "model", Keyword.get(opts, :model)),
         voice: Map.get(session, "voice", Keyword.get(opts, :voice)),
         session_id: Map.get(session, "id"),
         expires_at: Map.get(session, "expires_at"),
         session: session
       }}
    end
  end

  @doc """
  Normalizes provider events by delegating to WS helper semantics.
  """
  @spec normalize_event(map()) :: {:ok, map()} | {:error, term()}
  def normalize_event(payload), do: Synaptic.Voice.OpenAI.WSHelper.normalize_event(payload)

  defp endpoint(opts),
    do: opts[:endpoint] || OpenAI.config(opts)[:webrtc_endpoint] || @default_endpoint

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
