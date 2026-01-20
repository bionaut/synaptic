import Config

config :synaptic, Synaptic.Tools.OpenAI,
  finch: Synaptic.Finch,
  model: "gpt-4o-mini"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: []

import_config "#{config_env()}.exs"
