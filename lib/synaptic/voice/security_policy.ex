defmodule Synaptic.Voice.SecurityPolicy do
  @moduledoc """
  Framework security floors plus application-level policy tightening.
  """

  alias Synaptic.Voice.Capability

  defstruct force_confirmation: MapSet.new(),
            denied_capabilities: MapSet.new(),
            allowed_scopes: :all,
            metadata: %{}

  @type t :: %__MODULE__{}

  def new!(%__MODULE__{} = policy), do: policy
  def new!(nil), do: %__MODULE__{}
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(attrs) when is_map(attrs) do
    %__MODULE__{
      force_confirmation: attrs |> value(:force_confirmation, []) |> MapSet.new(),
      denied_capabilities: attrs |> value(:denied_capabilities, []) |> MapSet.new(),
      allowed_scopes: value(attrs, :allowed_scopes, :all),
      metadata: value(attrs, :metadata, %{})
    }
  end

  def denied?(%__MODULE__{} = policy, %Capability{name: name}),
    do: MapSet.member?(policy.denied_capabilities, name)

  def confirmation_required?(%__MODULE__{} = policy, %Capability{} = capability) do
    framework_required? = capability.risk in [:external_action, :sensitive, :destructive]

    framework_required? or capability.confirmation == :always or
      MapSet.member?(policy.force_confirmation, capability.name)
  end

  def scopes_allowed?(%__MODULE__{allowed_scopes: :all}, _required), do: true

  def scopes_allowed?(%__MODULE__{allowed_scopes: allowed}, required) do
    allowed = MapSet.new(allowed)
    Enum.all?(required, &MapSet.member?(allowed, &1))
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
