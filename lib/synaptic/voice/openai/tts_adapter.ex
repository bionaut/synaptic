defmodule Synaptic.Voice.OpenAI.TTSAdapter do
  @moduledoc """
  OpenAI-oriented TTS adapter that emits chunked audio messages to the owning session.
  """

  use GenServer

  @behaviour Synaptic.Voice.TTSAdapter

  alias Synaptic.Voice.OpenAI

  @default_endpoint "https://api.openai.com/v1/audio/speech"

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
    GenServer.stop(adapter, reason)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({owner, opts}) do
    {:ok, %{owner: owner, opts: opts, canceled: false}}
  end

  @impl true
  def handle_cast(:cancel, state) do
    send(state.owner, {:synaptic_voice, :tts_done, %{provider: :openai, canceled: true}})
    {:noreply, %{state | canceled: true}}
  end

  def handle_cast({:synthesize, _text_segment, _opts}, %{canceled: true} = state), do: {:noreply, state}

  def handle_cast({:synthesize, text_segment, opts}, state) do
    result = synthesize(text_segment, Keyword.merge(state.opts, opts))

    case result do
      {:ok, audio_chunk, meta} ->
        send(state.owner, {:synaptic_voice, :tts_chunk, audio_chunk, meta})

      {:error, reason} ->
        send(state.owner, {:synaptic_voice, :tts_error, reason})
    end

    {:noreply, %{state | canceled: false}}
  end

  def handle_cast({:flush, _opts}, state) do
    send(state.owner, {:synaptic_voice, :tts_done, %{provider: :openai}})
    {:noreply, %{state | canceled: false}}
  end

  defp synthesize(text_segment, opts) do
    audio_format = Keyword.get(opts, :audio_format, OpenAI.config(opts)[:audio_format] || "mp3")

    body =
      Jason.encode!(%{
        model: Keyword.get(opts, :tts_model, OpenAI.config(opts)[:tts_model] || "gpt-4o-mini-tts"),
        input: text_segment,
        voice: Keyword.get(opts, :voice, OpenAI.config(opts)[:voice] || "alloy"),
        format: audio_format
      })

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> OpenAI.api_key(opts)}
    ]

    request = Finch.build(:post, endpoint(opts), headers, body)

    case Finch.request(request, OpenAI.finch(opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} when is_binary(response_body) ->
        {:ok, response_body, tts_meta(audio_format)}

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:upstream_error, status, response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tts_meta(audio_format) do
    %{
      provider: :openai,
      audio_format: audio_format,
      content_type: content_type(audio_format)
    }
  end

  defp content_type("mp3"), do: "audio/mpeg"
  defp content_type("wav"), do: "audio/wav"
  defp content_type("pcm16"), do: "audio/L16"
  defp content_type("opus"), do: "audio/ogg"
  defp content_type(_), do: "application/octet-stream"

  defp endpoint(opts), do: opts[:endpoint] || OpenAI.config(opts)[:tts_endpoint] || @default_endpoint
end
