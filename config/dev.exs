import Config

config :synaptic, Synaptic.Tools.OpenAI,
  api_key: System.get_env("OPENAI_API_KEY"),
  model: "gpt-4o-mini"

config :synaptic, Synaptic.Voice.Providers.OpenAI, api_key: System.get_env("OPENAI_API_KEY")

config :synaptic, Synaptic.Voice.Providers.Gemini, api_key: System.get_env("GEMINI_API_KEY")

config :logger, :console, format: "[$level] $message\n"
