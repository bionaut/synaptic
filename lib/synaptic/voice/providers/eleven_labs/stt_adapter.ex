defmodule Synaptic.Voice.Providers.ElevenLabs.STTAdapter do
  @moduledoc """
  ElevenLabs-oriented STT adapter that batches audio at end_turn and emits normalized STT messages.
  """

  use GenServer

  @behaviour Synaptic.Voice.STTAdapter

  alias Synaptic.Voice.Providers.ElevenLabs

  @default_format %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}

  @impl true
  def start_link(owner, opts) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @impl true
  def push_audio(adapter, audio_chunk, opts \\ []) do
    GenServer.cast(adapter, {:push_audio, audio_chunk, opts})
    :ok
  end

  @impl true
  def end_turn(adapter, opts \\ []) do
    GenServer.cast(adapter, {:end_turn, opts})
    :ok
  end

  @impl true
  def stop(adapter, reason) do
    GenServer.stop(adapter, reason)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({owner, opts}) do
    {:ok, %{owner: owner, opts: opts, chunks: [], format: @default_format}}
  end

  @impl true
  def handle_cast({:push_audio, audio_chunk, opts}, state) do
    partial_text = Keyword.get(opts, :partial_text)

    if is_binary(partial_text) and partial_text != "" do
      send(state.owner, {:synaptic_voice, :stt_partial, partial_text, %{provider: :eleven_labs}})
    end

    format = Keyword.get(opts, :format, state.format)
    {:noreply, %{state | chunks: [audio_chunk | state.chunks], format: format}}
  end

  def handle_cast({:end_turn, opts}, state) do
    bytes = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    merged_opts = Keyword.merge(state.opts, opts)
    content_type = transcription_content_type(state.format)
    meta = final_meta(state.format, bytes, content_type)

    if bytes == "" do
      send(state.owner, {:synaptic_voice, :stt_error, {:empty_transcript, meta}})
    else
      case request_transcription(bytes, state.format, merged_opts) do
        {:ok, transcript} ->
          text = String.trim(transcript || "")

          if text == "" do
            send(state.owner, {:synaptic_voice, :stt_error, {:empty_transcript, meta}})
          else
            send(state.owner, {:synaptic_voice, :stt_final, text, meta})
          end

        {:error, reason} ->
          send(state.owner, {:synaptic_voice, :stt_error, {:transcription_failed, reason, meta}})
      end
    end

    {:noreply, %{state | chunks: []}}
  end

  defp request_transcription(bytes, format, opts) when is_binary(bytes) do
    {filename, content_type, request_body} = transcription_payload(bytes, format)
    boundary = "synaptic_voice_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    headers = [
      {"content-type", "multipart/form-data; boundary=#{boundary}"},
      {"xi-api-key", ElevenLabs.api_key(opts)}
    ]

    body =
      multipart_body(
        boundary,
        ElevenLabs.stt_model_id(opts),
        filename,
        content_type,
        request_body
      )

    request = Finch.build(:post, ElevenLabs.stt_endpoint(opts), headers, body)

    case Finch.request(request, ElevenLabs.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_transcription_response(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in RuntimeError ->
      {:error, {:configuration_error, Exception.message(error)}}
  end

  defp parse_transcription_response(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, %{"transcript" => text}} when is_binary(text) -> {:ok, text}
      _ -> {:error, :invalid_response}
    end
  end

  defp transcription_payload(bytes, %{mime: mime}) when is_binary(mime) do
    normalized_mime = normalize_mime(mime)

    cond do
      normalized_mime in ["audio/l16", "audio/pcm", "audio/raw"] ->
        {"audio.wav", "audio/wav", wav_binary(bytes, @default_format)}

      true ->
        {"audio" <> file_extension(normalized_mime), normalized_mime, bytes}
    end
  end

  defp transcription_payload(bytes, %{encoding: :pcm16le} = format),
    do: {"audio.wav", "audio/wav", wav_binary(bytes, format)}

  defp transcription_payload(bytes, _),
    do: {"audio.wav", "audio/wav", wav_binary(bytes, @default_format)}

  defp transcription_content_type(%{mime: mime}) when is_binary(mime) do
    normalized_mime = normalize_mime(mime)

    if normalized_mime in ["audio/l16", "audio/pcm", "audio/raw"],
      do: "audio/wav",
      else: normalized_mime
  end

  defp transcription_content_type(%{encoding: :pcm16le}), do: "audio/wav"
  defp transcription_content_type(_), do: "audio/wav"

  defp normalize_mime(mime) when is_binary(mime) do
    mime
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp file_extension("audio/webm"), do: ".webm"
  defp file_extension("audio/ogg"), do: ".ogg"
  defp file_extension("audio/opus"), do: ".opus"
  defp file_extension("audio/mp4"), do: ".m4a"
  defp file_extension("audio/x-m4a"), do: ".m4a"
  defp file_extension("audio/mpeg"), do: ".mp3"
  defp file_extension("audio/wav"), do: ".wav"
  defp file_extension("audio/x-wav"), do: ".wav"
  defp file_extension(_), do: ".bin"

  defp multipart_body(boundary, model_id, filename, content_type, bytes) do
    [
      "--",
      boundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"model_id\"\r\n\r\n",
      model_id,
      "\r\n",
      "--",
      boundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"",
      filename,
      "\"\r\n",
      "Content-Type: ",
      content_type,
      "\r\n\r\n",
      bytes,
      "\r\n",
      "--",
      boundary,
      "--\r\n"
    ]
  end

  defp wav_binary(bytes, %{sample_rate_hz: sample_rate, channels: channels})
       when is_integer(sample_rate) and is_integer(channels) and sample_rate > 0 and channels > 0 do
    bits_per_sample = 16
    data_size = byte_size(bytes)
    byte_rate = sample_rate * channels * div(bits_per_sample, 8)
    block_align = channels * div(bits_per_sample, 8)

    header =
      <<
        "RIFF",
        data_size + 36::little-32,
        "WAVE",
        "fmt ",
        16::little-32,
        1::little-16,
        channels::little-16,
        sample_rate::little-32,
        byte_rate::little-32,
        block_align::little-16,
        bits_per_sample::little-16,
        "data",
        data_size::little-32
      >>

    header <> bytes
  end

  defp wav_binary(bytes, _), do: wav_binary(bytes, @default_format)

  defp final_meta(format, bytes, content_type) do
    %{
      provider: :eleven_labs,
      bytes: byte_size(bytes),
      format: format,
      content_type: content_type
    }
  end
end
