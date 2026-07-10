defmodule Synaptic.Voice.Providers.Gemini.Live.Connection do
  @moduledoc false

  use WebSockex

  @default_input_mime_type "audio/pcm;rate=16000"

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    api_key = Keyword.fetch!(opts, :api_key)
    setup_message = Keyword.fetch!(opts, :setup_message)
    ws_endpoint = Keyword.fetch!(opts, :ws_endpoint)
    input_mime_type = Keyword.get(opts, :input_mime_type, @default_input_mime_type)

    url = "#{ws_endpoint}?key=#{api_key}"
    state = %{owner: owner, setup_message: setup_message, input_mime_type: input_mime_type}

    WebSockex.start_link(url, __MODULE__, state)
  end

  def send_json(connection, payload) when is_map(payload) do
    send(connection, {:gemini_live_send_json, payload})
    :ok
  end

  def send_audio(connection, audio_chunk, mime_type \\ @default_input_mime_type)
      when is_binary(audio_chunk) and is_binary(mime_type) do
    send(connection, {:gemini_live_send_audio, audio_chunk, mime_type})
    :ok
  end

  def end_turn(connection) do
    send(connection, :gemini_live_end_turn)
    :ok
  end

  def cancel_output(_connection), do: :ok

  def stop(connection, reason \\ :normal) do
    WebSockex.cast(connection, {:close, reason})
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_connect(_conn, state) do
    {:reply, {:text, Jason.encode!(state.setup_message)}, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    process_frame(msg, state)
  end

  def handle_frame({:binary, msg}, state) do
    process_frame(msg, state)
  end

  @impl true
  def handle_cast({:close, reason}, state) do
    {:close, %{reason: reason}, state}
  end

  @impl true
  def handle_info({:gemini_live_send_json, payload}, state) do
    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  def handle_info({:gemini_live_send_audio, audio_chunk, mime_type}, state) do
    payload = %{
      "realtimeInput" => %{
        "mediaChunks" => [
          %{
            "mimeType" => mime_type,
            "data" => Base.encode64(audio_chunk)
          }
        ]
      }
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  def handle_info(:gemini_live_end_turn, state) do
    payload = %{
      "realtimeInput" => %{
        "audioStreamEnd" => true
      }
    }

    {:reply, {:text, Jason.encode!(payload)}, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    send(state.owner, {:gemini_live, :disconnected, reason})
    {:ok, state}
  end

  defp process_frame(msg, state) when is_binary(msg) do
    case Jason.decode(msg) do
      {:ok, %{"setupComplete" => _}} ->
        send(state.owner, {:gemini_live, :setup_complete})
        {:ok, state}

      {:ok, decoded} ->
        send(state.owner, {:gemini_live, :event, decoded})
        {:ok, state}

      {:error, _reason} ->
        send(state.owner, {:gemini_live, :decode_error, msg})
        {:ok, state}
    end
  end
end
