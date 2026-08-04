defmodule Synaptic.MixProject do
  use Mix.Project

  def project do
    [
      app: :synaptic,
      version: "0.3.0-alpha.10",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: "https://github.com/bionaut/synaptic",
      package: package(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/monitor-guide.md",
          "docs/technical-overview.md",
          "docs/voice-guide.md",
          "docs/voice-profiles.md",
          "docs/voice_modes/duplex_setup.md",
          "docs/voice_modes/realtime_setup.md",
          "docs/voice_modes/turn_based_setup.md",
          "docs/voice_frontend/duplex_auto_mute_setup.md",
          "docs/voice_frontend/duplex_frontend_setup.md",
          "docs/voice_frontend/realtime_frontend_setup.md",
          "docs/voice_frontend/turn_based_frontend_setup.md",
          "docs/safety-validation-todo.md",
          "docs/four-equal-agents-peer-mesh-tutorial.md",
          "docs/voice-and-agents-x-trends-trading-tutorial.md",
          "docs/synaptic-for-founders-use-cases.md"
        ],
        authors: ["Synaptic contributors"]
      ],
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Synaptic.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:finch, "~> 0.13"},
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.2"},
      {:yaml_elixir, "~> 2.9"},
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_html, "~> 4.1", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:plug_cowboy, "~> 2.7", optional: true},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp description do
    "Workflow engine for orchestrating LLM-backed + human-in-the-loop automations"
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/bionaut/synaptic"}
    ]
  end
end
