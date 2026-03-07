defmodule Synaptic.Voice.ProviderRegistry do
  @moduledoc false

  alias Synaptic.Voice.Headless.ProviderCapabilities
  alias Synaptic.Voice.Providers.{ElevenLabs, Gemini, OpenAI}

  @providers %{
    openai: %{
      modules: %{
        stt: OpenAI.STTAdapter,
        tts: OpenAI.TTSAdapter,
        realtime: OpenAI.Realtime.SessionBootstrap
      },
      capabilities: %ProviderCapabilities{
        stt_mode: :batch,
        tts_mode: :single_shot,
        supports_barge_in_cancel: true,
        supports_turn_tts_consistency: true
      }
    },
    gemini: %{
      modules: %{
        stt: Gemini.STTAdapter,
        tts: Gemini.TTSAdapter,
        realtime: Gemini.Live.SessionBootstrap
      },
      capabilities: %ProviderCapabilities{
        stt_mode: :batch,
        tts_mode: :single_shot,
        supports_barge_in_cancel: true,
        supports_turn_tts_consistency: true
      }
    },
    eleven_labs: %{
      modules: %{
        stt: ElevenLabs.STTAdapter,
        tts: ElevenLabs.TTSAdapter
      },
      capabilities: %ProviderCapabilities{
        stt_mode: :batch,
        tts_mode: :single_shot,
        supports_barge_in_cancel: true,
        supports_turn_tts_consistency: true
      }
    }
  }

  def supports?(provider, role) when is_atom(provider) and is_atom(role) do
    @providers
    |> Map.get(provider)
    |> case do
      nil -> false
      provider_meta -> Map.has_key?(provider_meta.modules, role)
    end
  end

  def resolve(role, provider) when is_atom(role) and is_atom(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, {:unknown_provider, provider}}
      provider_meta -> Map.fetch(provider_meta.modules, role) |> normalize_resolve(provider, role)
    end
  end

  def capabilities(provider) when is_atom(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, {:unknown_provider, provider}}
      provider_meta -> {:ok, provider_meta.capabilities}
    end
  end

  def metadata(provider) when is_atom(provider) do
    case Map.get(@providers, provider) do
      nil -> {:error, {:unknown_provider, provider}}
      provider_meta -> {:ok, provider_meta}
    end
  end

  defp normalize_resolve({:ok, module}, _provider, _role), do: {:ok, module}

  defp normalize_resolve(:error, provider, role),
    do: {:error, {:unsupported_provider_role, provider, role}}
end
