# Live, opt-in smoke check for the OpenAI Realtime 2.1 client-secret bootstrap.
# It creates no Synaptic workflow and never prints the short-lived credential.

alias Synaptic.Voice.Providers.OpenAI.Realtime.SessionBootstrap

api_key =
  System.get_env("OPENAI_API_KEY") ||
    raise "Set OPENAI_API_KEY before running this smoke check"

model = System.get_env("OPENAI_REALTIME_2_1_MODEL", "gpt-realtime-2.1")
reasoning_effort = System.get_env("OPENAI_REALTIME_REASONING_EFFORT")

opts =
  [api_key: api_key, experience: :realtime_2_1, model: model]
  |> then(fn opts ->
    if reasoning_effort in ["minimal", "low", "medium", "high", "xhigh"] do
      Keyword.put(opts, :reasoning_effort, reasoning_effort)
    else
      opts
    end
  end)

case SessionBootstrap.create_browser_bootstrap(opts) do
  {:ok, bootstrap} ->
    IO.puts("OpenAI Realtime bootstrap succeeded")
    IO.puts("  model: #{bootstrap.model}")
    IO.puts("  voice: #{bootstrap.voice}")
    IO.puts("  session: #{bootstrap.session_id}")
    IO.puts("  expires_at: #{bootstrap.expires_at}")
    secret_present? = is_binary(bootstrap.client_secret["value"])
    IO.puts("  client secret present: #{secret_present?}")

  {:error, reason} ->
    raise "OpenAI Realtime bootstrap failed: #{inspect(reason)}"
end
