defmodule Synaptic.Voice.Router do
  @moduledoc false

  alias Synaptic.Voice.ProviderRegistry
  alias Synaptic.Voice.SessionRegistry
  alias Synaptic.Voice.Sessions.{Headless, Realtime}

  @type mode :: :turn_based | :duplex | :realtime
  @type provider :: :openai | :gemini | :eleven_labs

  def start_session(workflow_module, input, opts) when is_map(input) do
    with {:ok, resolved} <- resolve_session_opts(opts),
         {:ok, run_id} <-
           Synaptic.start(workflow_module, input, Keyword.get(opts, :workflow_opts, [])),
         {:ok, session} <- attach_run(run_id, resolved, opts) do
      {:ok, session}
    end
  end

  def attach_run(run_id, opts) when is_binary(run_id) and is_list(opts) do
    with {:ok, resolved} <- resolve_session_opts(opts) do
      attach_run(run_id, resolved, opts)
    end
  end

  def attach_run(run_id, resolved, opts) when is_binary(run_id) and is_map(resolved) do
    session_id = Keyword.get(opts, :session_id, generate_session_id())

    child_opts =
      opts
      |> Keyword.drop([:workflow_opts, :session_id])
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:session_id, session_id)
      |> Keyword.put(:mode, resolved.mode)
      |> Keyword.put(:stack, resolved.stack)
      |> Keyword.put(:stack_opts, resolved.stack_opts)
      |> Keyword.put(:provider_modules, resolved.provider_modules)
      |> Keyword.put(:provider_capabilities, resolved.provider_capabilities)
      |> Keyword.put(:registry_metadata, registry_metadata(run_id, resolved))

    case DynamicSupervisor.start_child(resolved.supervisor, {resolved.engine, child_opts}) do
      {:ok, _pid} ->
        {:ok,
         %{
           session_id: session_id,
           run_id: run_id,
           mode: resolved.mode,
           stack: resolved.stack,
           transport: inspect_transport(session_id)
         }}

      {:error, {:already_started, _pid}} ->
        {:error, :already_running}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def inspect_session(session_id), do: dispatch(session_id, :inspect_session, [])
  def stop_session(session_id, reason), do: dispatch(session_id, :stop_session, [reason])
  def push_audio(session_id, chunk, opts), do: dispatch(session_id, :push_audio, [chunk, opts])
  def push_text(session_id, text, opts), do: dispatch(session_id, :push_text, [text, opts])
  def end_turn(session_id, opts), do: dispatch(session_id, :end_turn, [opts])
  def playback_drained(session_id), do: dispatch(session_id, :playback_drained, [])
  def cancel_output(session_id), do: dispatch(session_id, :cancel_output, [])
  def client_connected(session_id, meta), do: dispatch(session_id, :client_connected, [meta])

  def client_disconnected(session_id, meta),
    do: dispatch(session_id, :client_disconnected, [meta])

  def ingest_provider_event(session_id, payload),
    do: dispatch(session_id, :ingest_provider_event, [payload])

  def lookup(session_id) when is_binary(session_id) do
    case Registry.lookup(SessionRegistry, session_id) do
      [{pid, metadata}] -> {:ok, pid, metadata}
      [] -> {:error, :not_found}
    end
  end

  defp dispatch(session_id, fun, args) do
    with {:ok, pid, %{engine: engine}} <- lookup(session_id) do
      apply(engine, fun, [pid | args])
    end
  end

  defp inspect_transport(session_id) do
    case inspect_session(session_id) do
      %{transport: transport} -> transport
      _ -> nil
    end
  end

  defp resolve_session_opts(opts) do
    config = Application.get_env(:synaptic, Synaptic.Voice, [])
    mode = Keyword.get(opts, :mode, config[:default_mode] || :duplex)
    provider = Keyword.get(opts, :provider, config[:default_provider] || :openai)

    with {:ok, stack_opts} <- resolve_stack(mode, provider, opts),
         {:ok, provider_modules, stack_ids, provider_capabilities} <-
           resolve_provider_modules(mode, stack_opts, opts) do
      engine = engine_for(mode, provider)

      :telemetry.execute(
        [:synaptic, :voice, :router, :ok],
        %{},
        telemetry_metadata(mode, provider, stack_ids)
      )

      {:ok,
       %{
         mode: mode,
         provider: provider,
         stack: stack_ids,
         stack_opts: stack_opts,
         provider_modules: provider_modules,
         provider_capabilities: provider_capabilities,
         engine: engine,
         supervisor: supervisor_for(mode)
       }}
    else
      {:error, reason} = error ->
        :telemetry.execute(
          [:synaptic, :voice, :router, :error],
          %{},
          %{mode: mode, provider: provider, reason: reason}
        )

        error
    end
  end

  defp resolve_stack(mode, provider, opts)
       when mode in [:turn_based, :duplex, :realtime] and is_atom(provider) do
    stack = opts[:stack]
    allow_custom_stack = Keyword.get(opts, :_allow_custom_stack, false)

    cond do
      stack && not allow_custom_stack ->
        {:error, {:unsupported_mode_stack, mode, stack}}

      stack && allow_custom_stack ->
        resolve_custom_stack(mode, stack)

      true ->
        {:ok, derive_stack(provider, mode, opts)}
    end
  end

  defp resolve_stack(mode, _provider, _opts), do: {:error, {:unsupported_mode_stack, mode, []}}

  defp resolve_custom_stack(mode, stack) do
    case mode do
      :realtime ->
        realtime_stack(mode, stack)

      _ ->
        headless_stack(mode, stack)
    end
  end

  defp derive_stack(provider, mode, opts) when mode in [:turn_based, :duplex] do
    provider_opts = Keyword.get(opts, :provider_opts, [])

    %{
      stt: {provider, Keyword.get(provider_opts, :stt, [])},
      tts: {provider, Keyword.get(provider_opts, :tts, [])}
    }
  end

  defp derive_stack(provider, :realtime, opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])
    %{realtime: {provider, Keyword.get(provider_opts, :realtime, [])}}
  end

  defp realtime_stack(mode, stack) do
    realtime = Keyword.get(stack, :realtime)
    stt = Keyword.get(stack, :stt)
    tts = Keyword.get(stack, :tts)

    cond do
      is_nil(realtime) -> {:error, {:missing_role, :realtime}}
      stt || tts -> {:error, {:unsupported_mode_stack, mode, stack}}
      true -> {:ok, %{realtime: normalize_provider_opt(realtime)}}
    end
  end

  defp headless_stack(mode, stack) do
    stt = Keyword.get(stack, :stt)
    tts = Keyword.get(stack, :tts)
    realtime = Keyword.get(stack, :realtime)

    cond do
      is_nil(stt) -> {:error, {:missing_role, :stt}}
      is_nil(tts) -> {:error, {:missing_role, :tts}}
      realtime -> {:error, {:unsupported_mode_stack, mode, stack}}
      true -> {:ok, %{stt: normalize_provider_opt(stt), tts: normalize_provider_opt(tts)}}
    end
  end

  defp normalize_provider_opt({provider, provider_opts})
       when is_atom(provider) and is_list(provider_opts),
       do: {provider, provider_opts}

  defp normalize_provider_opt(provider) when is_atom(provider), do: {provider, []}

  defp resolve_provider_modules(
         :realtime,
         %{realtime: {provider, _provider_opts}} = stack_opts,
         _call_opts
       ) do
    with {:ok, realtime} <- ProviderRegistry.resolve(:realtime, provider) do
      {:ok, %{stt: nil, tts: nil, realtime: realtime}, stack_to_ids(:realtime, stack_opts),
       realtime_capabilities(provider)}
    end
  end

  defp resolve_provider_modules(_mode, %{stt: {stt_provider, _}, tts: {tts_provider, _}}, opts) do
    with {:ok, stt} <- resolve_headless_module(:stt, stt_provider, opts[:stt_adapter]),
         {:ok, tts} <- resolve_headless_module(:tts, tts_provider, opts[:tts_adapter]) do
      stack_ids = %{
        stt: if(opts[:stt_adapter], do: :custom, else: stt_provider),
        tts: if(opts[:tts_adapter], do: :custom, else: tts_provider),
        realtime: nil
      }

      {:ok, %{stt: stt, tts: tts, realtime: nil}, stack_ids,
       headless_capabilities(stt_provider, tts_provider, opts[:stt_adapter], opts[:tts_adapter])}
    end
  end

  defp resolve_headless_module(_role, _provider, override)
       when is_atom(override) and not is_nil(override),
       do: {:ok, override}

  defp resolve_headless_module(role, provider, nil), do: ProviderRegistry.resolve(role, provider)

  defp stack_to_ids(:realtime, %{realtime: {provider, _opts}}),
    do: %{stt: nil, tts: nil, realtime: provider}

  defp stack_to_ids(_mode, %{stt: {stt_provider, _}, tts: {tts_provider, _}}),
    do: %{stt: stt_provider, tts: tts_provider, realtime: nil}

  defp registry_metadata(run_id, resolved) do
    %{
      engine: resolved.engine,
      mode: resolved.mode,
      run_id: run_id,
      stack: resolved.stack,
      provider_modules: Map.take(resolved.provider_modules, [:stt, :tts, :realtime]),
      provider_capabilities: resolved.provider_capabilities
    }
  end

  defp headless_capabilities(_stt_provider, _tts_provider, stt_override, tts_override)
       when not is_nil(stt_override) or not is_nil(tts_override),
       do: Synaptic.Voice.Headless.ProviderCapabilities.default()

  defp headless_capabilities(stt_provider, tts_provider, _stt_override, _tts_override) do
    stt_mode =
      case ProviderRegistry.capabilities(stt_provider) do
        {:ok, capabilities} -> capabilities.stt_mode
        _ -> :batch
      end

    case ProviderRegistry.capabilities(tts_provider) do
      {:ok, capabilities} ->
        %Synaptic.Voice.Headless.ProviderCapabilities{capabilities | stt_mode: stt_mode}

      _ ->
        %Synaptic.Voice.Headless.ProviderCapabilities{
          stt_mode: stt_mode,
          tts_mode: :segmented_batch,
          supports_barge_in_cancel: false,
          supports_turn_tts_consistency: false
        }
    end
  end

  defp realtime_capabilities(provider) do
    case ProviderRegistry.capabilities(provider) do
      {:ok, capabilities} -> capabilities
      _ -> Synaptic.Voice.Headless.ProviderCapabilities.default()
    end
  end

  defp telemetry_metadata(:realtime, provider, %{realtime: realtime_provider}) do
    %{
      mode: :realtime,
      provider: provider,
      stt_provider: nil,
      tts_provider: nil,
      realtime_provider: realtime_provider
    }
  end

  defp telemetry_metadata(mode, provider, %{stt: stt_provider, tts: tts_provider}) do
    %{
      mode: mode,
      provider: provider,
      stt_provider: stt_provider,
      tts_provider: tts_provider,
      realtime_provider: nil
    }
  end

  defp engine_for(:realtime, :openai), do: Realtime.OpenAI
  defp engine_for(:realtime, :gemini), do: Realtime.Gemini
  defp engine_for(_mode, _provider), do: Headless

  defp supervisor_for(:realtime), do: Synaptic.Voice.RealtimeSessionSupervisor
  defp supervisor_for(_mode), do: Synaptic.Voice.HeadlessSessionSupervisor

  defp generate_session_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
