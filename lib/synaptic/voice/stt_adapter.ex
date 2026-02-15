defmodule Synaptic.Voice.STTAdapter do
  @moduledoc """
  Behaviour for speech-to-text adapters used by voice sessions.
  """

  @callback start_link(owner :: pid(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback push_audio(adapter :: pid(), audio_chunk :: binary(), opts :: keyword()) :: :ok
  @callback end_turn(adapter :: pid(), opts :: keyword()) :: :ok
  @callback stop(adapter :: pid(), reason :: term()) :: :ok
end
