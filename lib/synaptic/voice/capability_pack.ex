defmodule Synaptic.Voice.CapabilityPack do
  @moduledoc """
  Behaviour and resolver for reusable groups of voice capabilities.
  """

  alias Synaptic.Voice.Capability

  @callback capabilities() :: [Capability.t() | map() | keyword()]

  def resolve(pack) when is_atom(pack) do
    unless Code.ensure_loaded?(pack) and function_exported?(pack, :capabilities, 0) do
      raise ArgumentError, "capability pack #{inspect(pack)} must implement capabilities/0"
    end

    pack.capabilities()
    |> Enum.map(&Capability.new!/1)
  end

  def resolve(capabilities) when is_list(capabilities),
    do: Enum.map(capabilities, &Capability.new!/1)
end
