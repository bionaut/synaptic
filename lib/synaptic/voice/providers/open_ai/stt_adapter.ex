defmodule Synaptic.Voice.Providers.OpenAI.STTAdapter do
  @moduledoc """
  OpenAI-oriented STT adapter with an OpenAI-compatible JSON transcription request.
  """

  use GenServer

  @behaviour Synaptic.Voice.STTAdapter

  alias Synaptic.Voice.Providers.OpenAI

  @default_endpoint "https://api.openai.com/v1/audio/transcriptions"

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
    {:ok,
     %{
       owner: owner,
       opts: opts,
       chunks: [],
       format: %{encoding: :pcm16le, sample_rate_hz: 24_000, channels: 1}
     }}
  end

  @impl true
  def handle_cast({:push_audio, audio_chunk, opts}, state) do
    partial_text = Keyword.get(opts, :partial_text)

    if is_binary(partial_text) and partial_text != "" do
      send(state.owner, {:synaptic_voice, :stt_partial, partial_text, %{provider: :openai}})
    end

    format = Keyword.get(opts, :format, state.format)
    {:noreply, %{state | chunks: [audio_chunk | state.chunks], format: format}}
  end

  def handle_cast({:end_turn, opts}, state) do
    bytes = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    merged_opts = Keyword.merge(state.opts, opts)
    meta = final_meta(state.format, bytes)

    if bytes == "" do
      send(state.owner, {:synaptic_voice, :stt_error, {:empty_transcript, meta}})
    else
      case request_transcription(bytes, state.format, merged_opts) do
        {:ok, transcript} ->
          text = String.trim(transcript)

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

  defp request_transcription(bytes, format, opts) do
    model =
      Keyword.get(opts, :stt_model, OpenAI.config(opts)[:stt_model] || "gpt-4o-mini-transcribe")

    filename = "audio" <> file_extension(format)
    content_type = content_type(format)
    boundary = "synaptic_voice_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    headers = [
      {"content-type", "multipart/form-data; boundary=#{boundary}"},
      {"authorization", "Bearer " <> OpenAI.api_key(opts)}
    ]

    body = multipart_body(boundary, model, filename, content_type, bytes)
    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, OpenAI.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
          _ -> {:error, :invalid_response}
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp final_meta(format, bytes) do
    %{
      provider: :openai,
      bytes: byte_size(bytes),
      format: format,
      content_type: content_type(format)
    }
  end

  defp file_extension(%{mime: mime}) when is_binary(mime) do
    case normalize_mime(mime) do
      "audio/webm" -> ".webm"
      "audio/ogg" -> ".ogg"
      "audio/opus" -> ".opus"
      "audio/mp4" -> ".m4a"
      "audio/x-m4a" -> ".m4a"
      "audio/mpeg" -> ".mp3"
      "audio/wav" -> ".wav"
      "audio/x-wav" -> ".wav"
      _ -> ".wav"
    end
  end

  defp file_extension(_), do: ".wav"

  defp content_type(%{mime: mime}) when is_binary(mime), do: normalize_mime(mime)
  defp content_type(_), do: "audio/wav"

  defp normalize_mime(mime) when is_binary(mime) do
    mime
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
  end

  defp multipart_body(boundary, model, filename, content_type, bytes) do
    [
      "--",
      boundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"model\"\r\n\r\n",
      model,
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

  defp endpoint(opts),
    do: opts[:endpoint] || OpenAI.config(opts)[:stt_endpoint] || @default_endpoint
end
