defmodule Synaptic.Voice.TransportHelper do
  @moduledoc """
  Behaviour for provider-specific transport event normalization helpers.
  """

  @callback normalize_event(payload :: map()) :: {:ok, map()} | {:error, term()}
end
