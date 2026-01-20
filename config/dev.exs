import Config

config :synaptic, Synaptic.Tools.OpenAI, api_key: System.get_env("OPENAI_API_KEY")

config :synaptic, Synaptic.Tools,
  llm_adapter: Synaptic.Tools.OpenAI,
  agents: [
    # Root agent: orchestrates the RLM loop
    root: [model: "gpt-5-nano", temperature: 1],
    sub: [model: "gpt-5-nano", temperature: 1]
  ]

config :logger, :console, format: "[$level] $message\n"
