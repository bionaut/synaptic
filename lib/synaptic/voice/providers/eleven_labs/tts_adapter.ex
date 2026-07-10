defmodule Synaptic.Voice.Providers.ElevenLabs.TTSAdapter do
  @moduledoc """
  ElevenLabs-oriented TTS adapter that emits raw PCM16 audio messages to the owning session.
  """

  use GenServer

  @behaviour Synaptic.Voice.TTSAdapter

  alias Synaptic.Voice.Providers.ElevenLabs
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
    {:noreply, TTSAdapterSupport.cancel(state, :eleven_labs)}
  end

  def handle_cast({:synthesize, text_segment, opts}, state) do
    generation = state.generation
    result = synthesize(text_segment, Keyword.merge(state.opts, opts))
    {:noreply, TTSAdapterSupport.handle_synthesis_result(state, generation, result)}
  end

  def handle_cast({:flush, _opts}, state) do
    {:noreply, TTSAdapterSupport.flush(state, :eleven_labs)}
  end

  defp synthesize(text_segment, opts) do
    body =
      %{
        text: text_segment,
        model_id: ElevenLabs.tts_model_id(opts)
      }
      |> maybe_put_voice_settings(opts)
      |> Jason.encode!()

    headers = [
      {"content-type", "application/json"},
      {"xi-api-key", ElevenLabs.api_key(opts)}
    ]

    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, ElevenLabs.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} when is_binary(response_body) ->
        {:ok, response_body, tts_meta()}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in RuntimeError ->
      {:error, {:configuration_error, Exception.message(error)}}
  end

  defp maybe_put_voice_settings(body, opts) do
    case normalize_voice_settings(Keyword.get(opts, :voice_settings)) do
      nil -> body
      voice_settings -> Map.put(body, :voice_settings, voice_settings)
    end
  end

  defp normalize_voice_settings(nil), do: nil
  defp normalize_voice_settings(%{} = voice_settings) when map_size(voice_settings) == 0, do: nil
  defp normalize_voice_settings(%{} = voice_settings), do: voice_settings

  defp normalize_voice_settings(voice_settings) when is_list(voice_settings),
    do: Enum.into(voice_settings, %{})

  defp normalize_voice_settings(_other), do: nil

  defp endpoint(opts) do
    base = ElevenLabs.tts_endpoint(opts) |> String.trim_trailing("/")
    voice_id = ElevenLabs.voice_id(opts) |> URI.encode_www_form()
    output_format = ElevenLabs.tts_output_format(opts)
    base <> "/" <> voice_id <> "?" <> URI.encode_query(%{"output_format" => output_format})
  end

  defp tts_meta do
    %{
      provider: :eleven_labs,
      audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
      content_type: "audio/L16"
    }
  end
end
