defmodule Synaptic.Voice.Providers.Gemini.TTSAdapter do
  @moduledoc """
  Gemini-oriented TTS adapter that emits raw PCM16 audio messages to the owning session.
  """

  use GenServer

  @behaviour Synaptic.Voice.TTSAdapter

  alias Synaptic.Voice.Providers.Gemini
  alias Synaptic.Voice.Providers.TTSAdapterSupport

  @impl true
  def start_link(owner, opts) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @impl true
  def synthesize_segment(adapter, text_segment, opts \\ []) do
    GenServer.cast(adapter, {:synthesize, text_segment, opts})
    :ok
  end

  @impl true
  def flush(adapter, opts \\ []) do
    GenServer.cast(adapter, {:flush, opts})
    :ok
  end

  @impl true
  def cancel_output(adapter) do
    GenServer.cast(adapter, :cancel)
    :ok
  end

  @impl true
  def stop(adapter, reason) do
    TTSAdapterSupport.stop_process(adapter, reason)
  end

  @impl true
  def init({owner, opts}) do
    {:ok, TTSAdapterSupport.init_state(owner, opts)}
  end

  @impl true
  def handle_cast(:cancel, state) do
    {:noreply, TTSAdapterSupport.cancel(state, :gemini)}
  end

  def handle_cast({:synthesize, text_segment, opts}, state) do
    generation = state.generation
    result = synthesize(text_segment, Keyword.merge(state.opts, opts))
    {:noreply, TTSAdapterSupport.handle_synthesis_result(state, generation, result, opts)}
  end

  def handle_cast({:flush, _opts}, state) do
    {:noreply, TTSAdapterSupport.flush(state, :gemini)}
  end

  defp synthesize(text_segment, opts) do
    body =
      Jason.encode!(%{
        contents: [
          %{
            parts: [%{text: text_segment}]
          }
        ],
        generationConfig: %{
          responseModalities: ["AUDIO"],
          speechConfig: %{
            voiceConfig: %{
              prebuiltVoiceConfig: %{
                voiceName: Keyword.get(opts, :voice, Gemini.live_voice(opts))
              }
            }
          }
        }
      })

    headers = [
      {"content-type", "application/json"},
      {"x-goog-api-key", Gemini.api_key(opts)}
    ]

    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, Gemini.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_response(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(response_body) do
    with {:ok, decoded} <- Jason.decode(response_body),
         {:ok, audio_data} <- extract_audio_data(decoded),
         {:ok, audio_chunk} <- Base.decode64(audio_data) do
      {:ok, audio_chunk, tts_meta()}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp extract_audio_data(%{"candidates" => candidates}) when is_list(candidates) do
    Enum.find_value(candidates, {:error, :invalid_response}, fn
      %{"content" => %{"parts" => parts}} when is_list(parts) ->
        Enum.find_value(parts, fn
          %{"inlineData" => %{"data" => data}} when is_binary(data) -> {:ok, data}
          %{"inline_data" => %{"data" => data}} when is_binary(data) -> {:ok, data}
          _ -> nil
        end)

      _ ->
        nil
    end)
  end

  defp extract_audio_data(_), do: {:error, :invalid_response}

  defp tts_meta do
    %{
      provider: :gemini,
      audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
      content_type: "audio/L16"
    }
  end

  defp endpoint(opts), do: Gemini.tts_endpoint(opts)
end
