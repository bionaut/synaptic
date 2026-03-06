defmodule Synaptic.Voice.TTSAdapter do
  @moduledoc """
  Behaviour for text-to-speech adapters used by voice sessions.
  """

  @callback start_link(owner :: pid(), opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  @callback synthesize_segment(adapter :: pid(), text_segment :: String.t(), opts :: keyword()) ::
              :ok
  @callback flush(adapter :: pid(), opts :: keyword()) :: :ok
  @callback cancel_output(adapter :: pid()) :: :ok
  @callback stop(adapter :: pid(), reason :: term()) :: :ok
end
