defmodule Synaptic.Voice.ProviderRegistry do
  @moduledoc false

  alias Synaptic.Voice.Providers.{ElevenLabs, Gemini, OpenAI}

  @providers %{
    openai: %{
      stt: OpenAI.STTAdapter,
      tts: OpenAI.TTSAdapter,
      realtime: OpenAI.Realtime.SessionBootstrap
    },
    gemini: %{
      stt: Gemini.STTAdapter,
      tts: Gemini.TTSAdapter,
      realtime: Gemini.Live.SessionBootstrap
    },
    eleven_labs: %{
      stt: ElevenLabs.STTAdapter,
      tts: ElevenLabs.TTSAdapter
    }
  }

  def supports?(provider, role) when is_atom(provider) and is_atom(role) do
    @providers
    |> Map.get(provider)
    |> case do
      nil -> false
      roles -> Map.has_key?(roles, role)
    end
  end

  def resolve(role, provider) when is_atom(role) and is_atom(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, {:unknown_provider, provider}}
      roles -> Map.fetch(roles, role) |> normalize_resolve(provider, role)
    end
  end

  defp normalize_resolve({:ok, module}, _provider, _role), do: {:ok, module}

  defp normalize_resolve(:error, provider, role),
    do: {:error, {:unsupported_provider_role, provider, role}}
end
