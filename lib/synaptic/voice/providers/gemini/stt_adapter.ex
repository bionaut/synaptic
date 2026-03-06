defmodule Synaptic.Voice.Providers.Gemini.STTAdapter do
  @moduledoc """
  Gemini-oriented STT adapter that batches audio at end_turn and emits normalized STT messages.
  """

  use GenServer

  @behaviour Synaptic.Voice.STTAdapter

  alias Synaptic.Voice.Providers.Gemini

  @default_format %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}

  @transcription_instruction """
  You are a strict speech transcription engine.
  Transcribe the audio exactly as spoken and output only the verbatim transcript text.
  If speech is absent, unclear, or unintelligible, output an empty string.
  Do not summarize, answer questions, infer intent, or add commentary.
  Do not add timestamps, speaker labels, markdown, or formatting.
  """

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
      send(state.owner, {:synaptic_voice, :stt_partial, partial_text, %{provider: :gemini}})
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
    {mime_type, encoded_audio} = transcription_payload(bytes, format)

    body =
      Jason.encode!(%{
        contents: [
          %{
            parts: [
              %{
                inline_data: %{
                  mime_type: mime_type,
                  data: Base.encode64(encoded_audio)
                }
              },
              %{text: @transcription_instruction}
            ]
          }
        ],
        generationConfig: %{
          temperature: 0,
          responseMimeType: "text/plain"
        }
      })

    headers = [
      {"content-type", "application/json"},
      {"x-goog-api-key", Gemini.api_key(opts)}
    ]

    request = Finch.build(:post, Gemini.stt_endpoint(opts), headers, body)

    case Finch.request(request, Gemini.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        parse_transcription_response(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_transcription_response(response_body) do
    with {:ok, decoded} <- Jason.decode(response_body),
         {:ok, transcript} <- extract_transcript(decoded) do
      {:ok, transcript}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp extract_transcript(%{"candidates" => candidates}) when is_list(candidates) do
    transcript =
      Enum.find_value(candidates, fn
        %{"content" => %{"parts" => parts}} when is_list(parts) ->
          Enum.find_value(parts, fn
            %{"text" => text} when is_binary(text) -> text
            _ -> nil
          end)

        _ ->
          nil
      end)

    if is_binary(transcript), do: {:ok, transcript}, else: {:error, :invalid_response}
  end

  defp extract_transcript(_), do: {:error, :invalid_response}

  defp transcription_payload(bytes, %{mime: mime}) when is_binary(mime) do
    normalized_mime = normalize_mime(mime)

    cond do
      normalized_mime in ["audio/l16", "audio/pcm", "audio/raw"] ->
        {"audio/wav", wav_binary(bytes, @default_format)}

      true ->
        {normalized_mime, bytes}
    end
  end

  defp transcription_payload(bytes, %{encoding: :pcm16le} = format),
    do: {"audio/wav", wav_binary(bytes, format)}

  defp transcription_payload(bytes, _), do: {"audio/wav", wav_binary(bytes, @default_format)}

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
      provider: :gemini,
      bytes: byte_size(bytes),
      format: format,
      content_type: content_type
    }
  end
end
