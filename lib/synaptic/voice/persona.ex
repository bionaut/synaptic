defmodule Synaptic.Voice.Persona do
  @moduledoc """
  Code-defined identity and conversational behavior for a voice assistant.
  """

  @enforce_keys [:role, :purpose]
  defstruct name: "Synaptic",
            role: nil,
            purpose: nil,
            tone: "warm, concise, and attentive",
            languages: ["en"],
            instructions: [],
            limitations: []

  @type t :: %__MODULE__{
          name: String.t(),
          role: String.t(),
          purpose: String.t(),
          tone: String.t(),
          languages: [String.t()],
          instructions: [String.t()],
          limitations: [String.t()]
        }

  def new!(%__MODULE__{} = persona), do: validate!(persona)

  def new!(attrs) when is_list(attrs), do: attrs |> Map.new() |> new!()

  def new!(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
    |> validate!()
  end

  defp validate!(%__MODULE__{role: role, purpose: purpose} = persona)
       when is_binary(role) and role != "" and is_binary(purpose) and purpose != "" do
    persona
  end

  defp validate!(_persona) do
    raise ArgumentError, "persona requires non-empty :role and :purpose"
  end
end
