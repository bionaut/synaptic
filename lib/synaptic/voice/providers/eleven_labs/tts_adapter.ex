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
    request_opts = Keyword.merge(state.opts, opts)

    if streaming?(request_opts) do
      result =
        stream_synthesize(text_segment, request_opts, fn audio_chunk, meta ->
          TTSAdapterSupport.emit_synthesis_chunk(
            state,
            generation,
            audio_chunk,
            meta,
            opts
          )
        end)

      case result do
        :ok ->
          {:noreply, state}

        {:error, reason} ->
          {:noreply,
           TTSAdapterSupport.handle_synthesis_result(state, generation, {:error, reason}, opts)}
      end
    else
      result = synthesize(text_segment, request_opts)
      {:noreply, TTSAdapterSupport.handle_synthesis_result(state, generation, result, opts)}
    end
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
        decode_response(response_body, opts)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in RuntimeError ->
      {:error, {:configuration_error, Exception.message(error)}}
  end

  defp stream_synthesize(text_segment, opts, on_chunk) do
    body = request_body(text_segment, opts)
    request = Finch.build(:post, endpoint(opts), request_headers(opts), body)

    initial = %{status: nil, body: "", json_buffer: "", error: nil, chunk_count: 0}

    case Finch.stream(request, ElevenLabs.finch(opts), initial, fn
           {:status, status}, acc ->
             %{acc | status: status}

           {:headers, _headers}, acc ->
             acc

           {:data, data}, %{status: 200, error: nil} = acc ->
             consume_stream_data(acc, data, on_chunk)

           {:data, data}, acc ->
             %{acc | body: acc.body <> data}

           _event, acc ->
             acc
         end) do
      {:ok, %{status: 200, error: nil} = acc} ->
        finalize_stream(acc, on_chunk)

      {:ok, %{status: status, body: body}} ->
        {:error, {:upstream_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in RuntimeError ->
      {:error, {:configuration_error, Exception.message(error)}}
  end

  defp consume_stream_data(acc, data, on_chunk) do
    parts = String.split(acc.json_buffer <> data, "\n")
    {complete, [remainder]} = Enum.split(parts, -1)

    Enum.reduce_while(complete, %{acc | json_buffer: remainder}, fn line, current ->
      case emit_stream_line(line, on_chunk) do
        :empty -> {:cont, current}
        :ok -> {:cont, %{current | chunk_count: current.chunk_count + 1}}
        {:error, reason} -> {:halt, %{current | error: reason}}
      end
    end)
  end

  defp finalize_stream(%{error: reason}, _on_chunk) when not is_nil(reason),
    do: {:error, reason}

  defp finalize_stream(acc, on_chunk) do
    case emit_stream_line(acc.json_buffer, on_chunk) do
      :empty when acc.chunk_count > 0 -> :ok
      :ok -> :ok
      :empty -> {:error, {:invalid_timestamp_response, :empty_stream}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_stream_line(line, on_chunk) do
    line =
      line
      |> String.trim()
      |> String.trim_leading("data:")
      |> String.trim()

    if line == "" do
      :empty
    else
      with {:ok, payload} when is_map(payload) <- Jason.decode(line),
           {:ok, audio_chunk} <- decode_audio(payload) do
        on_chunk.(audio_chunk, tts_meta(payload))
        :ok
      else
        {:ok, _payload} -> {:error, {:invalid_timestamp_response, :invalid_stream_chunk}}
        {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_timestamp_response, error}}
        {:error, reason} -> {:error, {:invalid_timestamp_response, reason}}
        :error -> {:error, {:invalid_timestamp_response, :invalid_audio_base64}}
      end
    end
  end

  defp decode_audio(%{"audio_base64" => audio_base64}) when is_binary(audio_base64),
    do: Base.decode64(audio_base64)

  defp decode_audio(_payload), do: {:error, :missing_audio_base64}

  defp maybe_put_voice_settings(body, opts) do
    case normalize_voice_settings(Keyword.get(opts, :voice_settings)) do
      nil -> body
      voice_settings -> Map.put(body, :voice_settings, voice_settings)
    end
  end

  defp request_body(text_segment, opts) do
    %{
      text: text_segment,
      model_id: ElevenLabs.tts_model_id(opts)
    }
    |> maybe_put_voice_settings(opts)
    |> Jason.encode!()
  end

  defp request_headers(opts) do
    [
      {"content-type", "application/json"},
      {"xi-api-key", ElevenLabs.api_key(opts)}
    ]
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

    suffix =
      case {streaming?(opts), ElevenLabs.include_timestamps?(opts)} do
        {true, true} -> "/stream/with-timestamps"
        {true, false} -> "/stream"
        {false, true} -> "/with-timestamps"
        {false, false} -> ""
      end

    base <>
      "/" <> voice_id <> suffix <> "?" <> URI.encode_query(%{"output_format" => output_format})
  end

  defp streaming?(opts), do: Keyword.get(opts, :streaming, false) == true

  defp decode_response(response_body, opts) do
    if ElevenLabs.include_timestamps?(opts) do
      decode_timestamp_response(response_body)
    else
      {:ok, response_body, tts_meta()}
    end
  end

  defp decode_timestamp_response(response_body) do
    with {:ok, %{"audio_base64" => audio_base64} = payload} when is_binary(audio_base64) <-
           Jason.decode(response_body),
         {:ok, audio_chunk} <- Base.decode64(audio_base64) do
      {:ok, audio_chunk, tts_meta(payload)}
    else
      {:ok, _payload} -> {:error, {:invalid_timestamp_response, :missing_audio_base64}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_timestamp_response, error}}
      :error -> {:error, {:invalid_timestamp_response, :invalid_audio_base64}}
    end
  end

  defp tts_meta(payload \\ %{}) do
    %{
      provider: :eleven_labs,
      audio_format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1},
      content_type: "audio/L16"
    }
    |> maybe_put_alignment(:alignment, Map.get(payload, "alignment"))
    |> maybe_put_alignment(:normalized_alignment, Map.get(payload, "normalized_alignment"))
  end

  defp maybe_put_alignment(meta, key, alignment) when is_map(alignment),
    do: Map.put(meta, key, alignment)

  defp maybe_put_alignment(meta, _key, _alignment), do: meta
end
