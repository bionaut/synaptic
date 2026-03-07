defmodule Synaptic.Voice.StreamingTTSAdapter do
  @moduledoc """
  Optional behaviour for providers that can synthesize a single assistant turn over a persistent TTS stream.
  """

  @callback start_stream(owner :: pid(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback push_text(stream :: pid(), text_chunk :: String.t(), opts :: keyword()) :: :ok
  @callback finish_stream(stream :: pid(), opts :: keyword()) :: :ok
  @callback cancel_stream(stream :: pid()) :: :ok
  @callback stop(stream :: pid(), reason :: term()) :: :ok
end
