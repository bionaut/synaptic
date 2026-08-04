defmodule Synaptic.Voice.Profile do
  @moduledoc """
  Code-defined assistant profile: persona, capabilities, context schema, and policy.
  """

  alias Synaptic.Voice.{Capability, CapabilityPack, Persona, SecurityPolicy}

  @enforce_keys [:id, :persona]
  defstruct id: nil,
            persona: nil,
            capability_packs: [],
            capabilities: [],
            disabled_capabilities: [],
            context_schema: %{},
            security_policy: %SecurityPolicy{},
            metadata: %{}

  @type t :: %__MODULE__{}

  def new!(%__MODULE__{} = profile), do: normalize!(profile)
  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()
  def new!(attrs) when is_map(attrs), do: __MODULE__ |> struct!(attrs) |> normalize!()

  def default do
    new!(%{
      id: :default_realtime,
      persona: %{
        role: "general realtime assistant",
        purpose: "help the user conversationally and delegate application work when necessary"
      },
      capabilities: [
        %{
          name: "synaptic_workflow",
          description:
            "Delegate a request that requires application-specific data or actions to the configured Synaptic workflow.",
          parameters: %{
            type: "object",
            properties: %{
              query: %{type: "string", description: "Complete request to delegate."}
            },
            required: ["query"],
            additionalProperties: false
          },
          executor: :workflow,
          risk: :read_only
        }
      ]
    })
  end

  def capability_map(%__MODULE__{capabilities: capabilities}),
    do: Map.new(capabilities, &{&1.name, &1})

  defp normalize!(%__MODULE__{} = profile) do
    unless is_atom(profile.id) or is_binary(profile.id) do
      raise ArgumentError, "profile :id must be an atom or string"
    end

    persona = Persona.new!(profile.persona)

    capabilities =
      Enum.flat_map(profile.capability_packs, &CapabilityPack.resolve/1) ++
        Enum.map(profile.capabilities, &Capability.new!/1)

    disabled = MapSet.new(profile.disabled_capabilities)

    capabilities =
      capabilities
      |> Enum.reject(&MapSet.member?(disabled, &1.name))
      |> ensure_unique_capabilities!()

    %{
      profile
      | persona: persona,
        capability_packs: [],
        capabilities: capabilities,
        security_policy: SecurityPolicy.new!(profile.security_policy)
    }
  end

  defp ensure_unique_capabilities!(capabilities) do
    duplicates =
      capabilities
      |> Enum.group_by(& &1.name)
      |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "duplicate capabilities: #{Enum.join(duplicates, ", ")}"
    end

    capabilities
  end
end
