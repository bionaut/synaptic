defmodule Synaptic.Voice.ProfileTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.{Capability, Profile}

  defmodule ExamplePack do
    @behaviour Synaptic.Voice.CapabilityPack

    @impl true
    def capabilities do
      [
        Capability.new!(%{
          name: "example_lookup",
          description: "Look up an example.",
          parameters: %{
            type: "object",
            properties: %{},
            additionalProperties: false
          },
          handler: fn _arguments -> {:ok, %{value: "example"}} end
        })
      ]
    end
  end

  test "normalizing an already-built profile does not resolve packs twice" do
    profile =
      Profile.new!(%{
        id: :example,
        persona: %{
          role: "example assistant",
          purpose: "demonstrate profile normalization"
        },
        capability_packs: [ExamplePack]
      })

    assert [%Capability{name: "example_lookup"}] = profile.capabilities
    assert profile.capability_packs == []

    normalized_again = Profile.new!(profile)

    assert [%Capability{name: "example_lookup"}] = normalized_again.capabilities
    assert normalized_again.capability_packs == []
  end
end
