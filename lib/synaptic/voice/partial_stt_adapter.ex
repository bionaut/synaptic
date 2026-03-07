defmodule Synaptic.Voice.PartialSTTAdapter do
  @moduledoc """
  Optional behaviour for providers that can keep a live STT stream and emit native partials.
  """

  @callback start_stream(owner :: pid(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback push_audio(stream :: pid(), audio_chunk :: binary(), opts :: keyword()) :: :ok
  @callback end_stream(stream :: pid(), opts :: keyword()) :: :ok
  @callback stop(stream :: pid(), reason :: term()) :: :ok
end
