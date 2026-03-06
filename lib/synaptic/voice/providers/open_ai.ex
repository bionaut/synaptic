defmodule Synaptic.Voice.Providers.OpenAI do
  @moduledoc false

  def config(opts) do
    Keyword.get(opts, :config, [])
    |> Keyword.merge(Application.get_env(:synaptic, __MODULE__, []))
  end

  def api_key(opts) do
    opts[:api_key] ||
      config(opts)[:api_key] ||
      System.get_env("OPENAI_API_KEY") ||
      raise "Synaptic voice OpenAI adapter requires an API key"
  end

  def finch(opts) do
    opts[:finch] || config(opts)[:finch] || Synaptic.Finch
  end
end
