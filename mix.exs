defmodule Synaptic.MixProject do
  use Mix.Project

  def project do
    [
      app: :synaptic,
      version: "0.1.5",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: "https://github.com/bionaut/synaptic",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "TECHNICAL.md"],
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
      {:jason, "~> 1.2"},
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
