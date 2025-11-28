# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :synapse,
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :synapse, SynapseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SynapseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Synapse.PubSub,
  live_view: [signing_salt: "jIvkKhOq"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :synapse, Synapse.Mailer, adapter: Swoosh.Adapters.Local

# Synapse workflow defaults
config :synapse, Synapse.Tools, llm_adapter: Synapse.Tools.OpenAI

config :synapse, Synapse.Tools.OpenAI,
  finch: Synapse.Finch,
  model: "gpt-4o-mini"

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
