import Config

if config_env() == :prod do
  config :synaptic, Synaptic.Tools.OpenAI,
    api_key: System.fetch_env!("OPENAI_API_KEY"),
    model: System.get_env("OPENAI_MODEL", "gpt-4o-mini")

  config :synaptic, Synaptic.Voice.Providers.OpenAI, api_key: System.fetch_env!("OPENAI_API_KEY")

  if gemini_api_key = System.get_env("GEMINI_API_KEY") do
    config :synaptic, Synaptic.Voice.Providers.Gemini, api_key: gemini_api_key
  end

  if elevenlabs_api_key = System.get_env("ELEVENLABS_API_KEY") do
    config :synaptic, Synaptic.Voice.Providers.ElevenLabs, api_key: elevenlabs_api_key
  end
end
