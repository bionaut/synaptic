import Config

if realtime_model = System.get_env("OPENAI_REALTIME_MODEL") do
  config :synaptic, Synaptic.Voice.Providers.OpenAI, realtime_model: realtime_model
end

if realtime_2_1_model = System.get_env("OPENAI_REALTIME_2_1_MODEL") do
  config :synaptic, Synaptic.Voice.Providers.OpenAI, realtime_2_1_model: realtime_2_1_model
end

if realtime_experience = System.get_env("OPENAI_REALTIME_EXPERIENCE") do
  case realtime_experience do
    "legacy" ->
      config :synaptic, Synaptic.Voice.Providers.OpenAI, default_experience: :legacy

    "realtime_2_1" ->
      config :synaptic, Synaptic.Voice.Providers.OpenAI, default_experience: :realtime_2_1

    _ ->
      :ok
  end
end

if realtime_response_mode = System.get_env("OPENAI_REALTIME_RESPONSE_MODE") do
  case realtime_response_mode do
    "native" ->
      config :synaptic, Synaptic.Voice.Providers.OpenAI, realtime_response_mode: :native

    "orchestrated" ->
      config :synaptic, Synaptic.Voice.Providers.OpenAI, realtime_response_mode: :orchestrated

    _ ->
      :ok
  end
end

if config_env() == :prod do
  openai_tools_config = [
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini")
  ]

  openai_tools_config =
    case System.get_env("OPENAI_REASONING_EFFORT") do
      nil -> openai_tools_config
      effort -> Keyword.put(openai_tools_config, :reasoning_effort, effort)
    end

  config :synaptic, Synaptic.Tools.OpenAI, openai_tools_config

  config :synaptic, Synaptic.Voice.Providers.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")

  if gemini_api_key = System.get_env("GEMINI_API_KEY") do
    config :synaptic, Synaptic.Voice.Providers.Gemini, api_key: gemini_api_key
  end

  if elevenlabs_api_key = System.get_env("ELEVENLABS_API_KEY") do
    config :synaptic, Synaptic.Voice.Providers.ElevenLabs, api_key: elevenlabs_api_key
  end
end
