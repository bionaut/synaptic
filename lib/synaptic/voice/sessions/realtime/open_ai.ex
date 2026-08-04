defmodule Synaptic.Voice.Sessions.Realtime.OpenAI do
  @moduledoc false

  use GenServer
  require Logger

  alias Phoenix.PubSub

  alias Synaptic.Voice.{
    CapabilityGateway,
    Event,
    Profile,
    ProfileCompiler,
    SessionContext,
    SessionRegistry
  }

  alias Synaptic.Voice.Providers.OpenAI.Realtime.{EventMapper, SessionBootstrap, Sideband}

  @default_timeout_ms 30_000

  @default_backchannel_phrases [
    "Got it. Let me check that now.",
    "Sure, I can look that up.",
    "Okay, give me a moment while I verify that."
  ]

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:synaptic_voice_realtime_session, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    metadata = Keyword.get(opts, :registry_metadata, %{})
    GenServer.start_link(__MODULE__, opts, name: SessionRegistry.via(session_id, metadata))
  end

  def stop_session(pid, reason \\ :normal), do: GenServer.call(pid, {:stop_session, reason})
  def inspect_session(pid), do: GenServer.call(pid, :inspect_session)
  def client_connected(pid, meta \\ %{}), do: GenServer.call(pid, {:client_connected, meta})
  def client_disconnected(pid, meta \\ %{}), do: GenServer.call(pid, {:client_disconnected, meta})
  def approve_capability(pid, name), do: GenServer.call(pid, {:approve_capability, name})

  def ingest_provider_event(pid, payload) when is_map(payload),
    do: GenServer.call(pid, {:ingest_provider_event, payload})

  def push_audio(_pid, _chunk, _opts \\ []), do: {:error, :unsupported_for_mode}
  def push_text(_pid, _text, _opts \\ []), do: {:error, :unsupported_for_mode}
  def end_turn(_pid, _opts \\ []), do: {:error, :unsupported_for_mode}
  def cancel_output(_pid), do: {:error, :unsupported_for_mode}

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    session_id = Keyword.fetch!(opts, :session_id)
    provider_modules = Keyword.fetch!(opts, :provider_modules)
    stack = Keyword.fetch!(opts, :stack)
    stack_opts = Keyword.get(opts, :stack_opts, %{})

    config = Application.get_env(:synaptic, Synaptic.Voice.Providers.OpenAI, [])
    realtime_opts = provider_opts(stack_opts, :realtime)
    experience = resolve_experience(opts, config)

    model =
      Keyword.get(realtime_opts, :model, experience_default(experience, :model, config))

    voice = Keyword.get(realtime_opts, :voice, experience_default(experience, :voice, config))

    response_mode =
      normalize_response_mode(
        Keyword.get(opts, :response_mode, experience_default(experience, :response_mode, config))
      )

    profile = opts |> Keyword.get(:profile, Profile.default()) |> resolve_profile()

    session_context =
      SessionContext.new!(
        profile.context_schema,
        Keyword.get(opts, :session_context, %{}),
        authorization: Keyword.get(opts, :session_authorization, %{})
      )

    profile_compilation = ProfileCompiler.compile(profile, session_context)

    preferred_language =
      Keyword.get(opts, :preferred_language, config[:preferred_language] || "en")

    keep_alive = Keyword.get(opts, :keep_alive, false)

    cancel_on_interrupt =
      Keyword.get(opts, :cancel_on_interrupt, config[:cancel_on_interrupt] != false)

    workflow_timeout_ms =
      Keyword.get(opts, :workflow_timeout_ms, config[:workflow_timeout_ms] || @default_timeout_ms)

    backchannel_phrases =
      Keyword.get(
        opts,
        :backchannel_phrases,
        config[:backchannel_phrases] || @default_backchannel_phrases
      )

    backchannel_enabled =
      Keyword.get(
        opts,
        :backchannel_enabled,
        response_mode == :orchestrated and config[:backchannel_enabled] != false
      )

    suppress_provider_responses_during_workflow =
      Keyword.get(
        opts,
        :suppress_provider_responses_during_workflow,
        response_mode == :orchestrated and
          config[:suppress_provider_responses_during_workflow] != false
      )

    sideband_adapter = Keyword.get(opts, :sideband_adapter, config[:sideband_adapter] || Sideband)

    bootstrap_fun =
      Keyword.get(opts, :webrtc_bootstrap_fun, &SessionBootstrap.create_browser_bootstrap/1)

    bootstrap_opts =
      realtime_opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:voice, voice)
      |> Keyword.put(:experience, experience)
      |> Keyword.put(:response_mode, response_mode)
      |> maybe_put_profile_compilation(response_mode, profile_compilation)
      |> Keyword.put_new(:transcription_language, preferred_language)

    with {:ok, realtime} <- bootstrap_fun.(bootstrap_opts),
         {:ok, sideband_pid} <-
           sideband_adapter.start_link(self(), session_id: session_id, run_id: run_id) do
      :ok = PubSub.subscribe(Synaptic.PubSub, run_topic(run_id))

      state = %{
        session_id: session_id,
        run_id: run_id,
        mode: :realtime,
        stack: stack,
        provider_modules: provider_modules,
        status: :connecting,
        seq: 0,
        keep_alive: keep_alive,
        transport: public_transport(realtime),
        realtime: realtime,
        model: model,
        voice: voice,
        experience: experience,
        response_mode: response_mode,
        profile: profile,
        session_context: session_context,
        capabilities: profile_compilation.capabilities,
        pending_confirmations: MapSet.new(),
        approved_capabilities: MapSet.new(),
        preferred_language: preferred_language,
        sideband_adapter: sideband_adapter,
        sideband_pid: sideband_pid,
        cancel_on_interrupt: cancel_on_interrupt,
        workflow_timeout_ms: workflow_timeout_ms,
        backchannel_phrases: backchannel_phrases,
        backchannel_enabled: backchannel_enabled,
        suppress_provider_responses_during_workflow: suppress_provider_responses_during_workflow,
        current_task: nil,
        response_active: false,
        last_final_input: nil,
        telemetry_marks: %{},
        latency: %{}
      }

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :start],
        %{},
        telemetry_metadata(state)
      )

      {:ok,
       state
       |> emit(:session_started, %{
         mode: :realtime,
         stack: stack,
         experience: experience,
         transport: state.transport
       })
       |> emit(:duplex_state_changed, %{status: :connecting, mode: :realtime})}
    end
  end

  @impl true
  def handle_call(:inspect_session, _from, state) do
    {:reply, public_state(state), state}
  end

  def handle_call({:client_connected, meta}, _from, state) do
    {:reply, :ok,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime, meta: meta})}
  end

  def handle_call({:client_disconnected, meta}, _from, state) do
    state =
      emit(state, :duplex_state_changed, %{status: :connecting, mode: :realtime, meta: meta})

    if state.keep_alive do
      {:reply, :ok, %{state | status: :connecting}}
    else
      {:stop, {:client_disconnected, meta}, :ok, state}
    end
  end

  def handle_call({:ingest_provider_event, payload}, _from, state) do
    :ok = state.sideband_adapter.ingest_provider_event(state.sideband_pid, payload)
    {:reply, :ok, state}
  end

  def handle_call({:stop_session, reason}, _from, state) do
    {:stop, reason, :ok, state}
  end

  def handle_call({:approve_capability, name}, _from, state) when is_binary(name) do
    if MapSet.member?(state.pending_confirmations, name) do
      state =
        state
        |> Map.update!(:pending_confirmations, &MapSet.delete(&1, name))
        |> Map.update!(:approved_capabilities, &MapSet.put(&1, name))
        |> emit(:capability_approved, %{name: name, one_shot: true})

      {:reply, :ok, state}
    else
      {:reply, {:error, :no_pending_confirmation}, state}
    end
  end

  def handle_call({:approve_capability, _name}, _from, state),
    do: {:reply, {:error, :invalid_capability_name}, state}

  @impl true
  def handle_info({:synaptic_voice_realtime_sideband, :provider_event, payload}, state) do
    {:noreply, process_provider_event(payload, state)}
  end

  def handle_info({:synaptic_voice_realtime_sideband, :outbound_event, event}, state) do
    {:noreply, emit(state, :provider_outbound, %{event: event})}
  end

  def handle_info({:synaptic_event, %{event: :waiting_for_human}}, state) do
    {:noreply,
     state
     |> update_status(:listening)
     |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})}
  end

  def handle_info({:synaptic_event, %{event: event}}, state)
      when event in [:completed, :failed, :stopped] do
    if state.keep_alive do
      {:noreply, state}
    else
      {:stop, {:run_terminal, event}, state}
    end
  end

  def handle_info({ref, result}, %{current_task: %{task: %Task{ref: ref}} = task_meta} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, handle_task_result(result, %{state | current_task: nil}, task_meta)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_task: %{task: %Task{ref: ref}}} = state
      ) do
    if reason != :normal do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :workflow, :cancel],
        %{},
        Map.put(telemetry_metadata(state), :reason, reason)
      )
    end

    {:noreply, %{state | current_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_inflight(state)
    _ = state.sideband_adapter.stop(state.sideband_pid, :shutdown)

    state
    |> emit(:session_stopped, %{reason: inspect(reason)})
    |> then(fn final_state ->
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :session, :stop],
        %{},
        Map.put(telemetry_metadata(final_state), :reason, reason)
      )
    end)

    :ok
  end

  defp provider_opts(stack_opts, role) do
    case Map.get(stack_opts, role) do
      {_provider, opts} -> opts
      _ -> []
    end
  end

  defp maybe_put_profile_compilation(opts, :native, compilation) do
    instructions =
      [compilation.instructions, Keyword.get(opts, :instructions)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    opts
    |> Keyword.put(:instructions, instructions)
    |> Keyword.put(:tools, compilation.tools)
  end

  defp maybe_put_profile_compilation(opts, :orchestrated, _compilation), do: opts

  defp public_state(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: :realtime,
      status: state.status,
      seq: state.seq,
      stack: state.stack,
      provider_modules: Map.take(state.provider_modules, [:stt, :tts, :realtime]),
      transport: state.transport,
      latency: state.latency,
      engine_state: %{
        response_active: state.response_active,
        current_task_active: not is_nil(state.current_task),
        last_final_input: state.last_final_input,
        preferred_language: state.preferred_language,
        experience: state.experience,
        response_mode: state.response_mode,
        profile: state.profile.id,
        capabilities: state.capabilities |> Map.keys() |> Enum.sort(),
        pending_confirmations: state.pending_confirmations |> MapSet.to_list() |> Enum.sort()
      }
    }
  end

  defp process_provider_event(
         %{
           "type" => "response.output_item.done",
           "item" => %{"type" => "function_call", "name" => name} = item
         },
         %{response_mode: :native} = state
       )
       when is_binary(name) do
    on_capability_call(item, state)
  end

  defp process_provider_event(payload, state) do
    case EventMapper.normalize_event(payload) do
      {:ok, %{event: :input_partial_text, data: %{text: text}}} ->
        state
        |> update_status(:listening)
        |> emit(:input_partial_text, %{text: text})

      {:ok, %{event: :input_final_text, data: data}} ->
        on_final_input(data, state)

      {:ok, %{event: :assistant_text_chunk, data: data}} ->
        if suppress_provider_response?(state) do
          state
        else
          log_assistant_chunk(state, data)

          state
          |> update_status(:speaking)
          |> emit(:assistant_text_chunk, data)
        end

      {:ok, %{event: :assistant_response_started, data: data}} ->
        if suppress_provider_response?(state) do
          _ = send_provider_event(state, %{"type" => "response.cancel"})

          state
          |> Map.put(:response_active, false)
          |> emit(:assistant_response_suppressed, %{reason: :workflow_in_progress})
        else
          state
          |> update_status(:speaking)
          |> Map.put(:response_active, true)
          |> emit(:assistant_response_started, data)
          |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
        end

      {:ok, %{event: :assistant_response_done, data: data}} ->
        if suppress_provider_response?(state) do
          state
        else
          state
          |> update_status(:listening)
          |> Map.put(:response_active, false)
          |> emit(:assistant_response_done, data)
          |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
        end

      {:ok, %{event: :duplex_interruption, data: data}} ->
        state
        |> maybe_interrupt_response_only()
        |> emit(:duplex_interruption, data)
        |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})

      {:ok, %{event: :session_error, data: data}} ->
        log_provider_error(state, data)
        emit(state, :session_error, data)

      {:ignore, _} ->
        state
    end
  end

  defp on_final_input(%{text: text} = data, state) do
    trimmed = String.trim(text || "")
    item_id = Map.get(data, :item_id)

    if trimmed == "" do
      emit(state, :session_error, %{source: :stt, reason: :empty_transcript})
    else
      now_ms = System.monotonic_time(:millisecond)

      if duplicate_final_input?(state.last_final_input, item_id, trimmed, now_ms) do
        Logger.debug(
          "[voice.realtime] input_final_duplicate_ignored session=#{state.session_id} run=#{state.run_id} item_id=#{inspect(item_id)}"
        )

        state
      else
        Logger.debug(
          "[voice.realtime] input_final session=#{state.session_id} run=#{state.run_id} text=#{inspect(trimmed)}"
        )

        started_at = now_ms

        state =
          state
          |> Map.put(:last_final_input, %{item_id: item_id, text: trimmed, at_ms: now_ms})
          |> maybe_interrupt_for_final_input()
          |> update_status(:thinking)
          |> put_telemetry_mark(:user_final_at_ms, started_at)
          |> emit(:input_final_text, %{text: trimmed})
          |> emit(:duplex_state_changed, %{status: :thinking, mode: :realtime})

        if state.response_mode == :native do
          state
        else
          state
          |> maybe_send_backchannel()
          |> start_workflow_task(trimmed)
        end
      end
    end
  end

  defp on_final_input(_other, state), do: state

  defp maybe_interrupt_for_final_input(%{response_mode: :native} = state), do: state
  defp maybe_interrupt_for_final_input(state), do: maybe_interrupt(state)

  defp duplicate_final_input?(nil, _item_id, _text, _now_ms), do: false

  defp duplicate_final_input?(%{item_id: prev_item_id}, item_id, _text, _now_ms)
       when is_binary(prev_item_id) and is_binary(item_id) and prev_item_id == item_id do
    true
  end

  defp duplicate_final_input?(%{text: prev_text, at_ms: prev_ms}, _item_id, text, now_ms) do
    prev_text == text and now_ms - prev_ms <= 2_000
  end

  defp maybe_interrupt(state) do
    if state.cancel_on_interrupt do
      state = cancel_inflight(state)

      if state.response_active do
        _ = send_provider_event(state, %{"type" => "response.cancel"})
      end

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        telemetry_metadata(state)
      )

      emit(state, :duplex_interruption, %{reason: :cancel_and_restart})
    else
      state
    end
  end

  defp maybe_interrupt_response_only(state) do
    if state.cancel_on_interrupt do
      if state.response_active do
        _ = send_provider_event(state, %{"type" => "response.cancel"})
      end

      :telemetry.execute(
        [:synaptic, :voice, :realtime, :interrupt],
        %{},
        Map.put(telemetry_metadata(state), :scope, :response_only)
      )

      state
    else
      state
    end
  end

  defp maybe_send_backchannel(%{backchannel_enabled: false} = state), do: state
  defp maybe_send_backchannel(state), do: send_backchannel(state)

  defp send_backchannel(state) do
    phrase = choose_backchannel_phrase(state.backchannel_phrases)
    now_ms = System.monotonic_time(:millisecond)
    mark = Map.get(state.telemetry_marks, :user_final_at_ms)

    if is_integer(mark) do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :backchannel, :sent],
        %{user_final_to_backchannel_ms: max(now_ms - mark, 0)},
        telemetry_metadata(state)
      )
    end

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "output_modalities" => ["audio"],
          "max_output_tokens" => 64,
          "instructions" =>
            [
              "SERVER ORCHESTRATION MODE.",
              language_instruction(state),
              "This is a backchannel acknowledgement only.",
              "Do not answer the user's question.",
              "Say exactly this sentence and nothing else:",
              phrase
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> emit(:backchannel_sent, %{text: phrase})
    |> emit(:assistant_response_started, %{source: :backchannel})
  end

  defp on_capability_call(%{"call_id" => call_id, "name" => name} = item, state)
       when is_binary(call_id) and is_binary(name) do
    tool_call = %{call_id: call_id, name: name}

    with %{} = capability <- Map.get(state.capabilities, name),
         {:ok, arguments} <- decode_call_arguments(item),
         true <- is_nil(state.current_task) do
      approved? = MapSet.member?(state.approved_capabilities, name)

      state =
        state
        |> Map.update!(:approved_capabilities, &MapSet.delete(&1, name))
        |> Map.put(:response_active, false)
        |> update_status(:thinking)
        |> emit(:capability_called, %{name: name, risk: capability.risk})

      case capability.executor do
        :workflow ->
          with {:ok, query} <- workflow_query(arguments, state) do
            start_workflow_task(state, query, tool_call)
          else
            {:error, reason} -> send_capability_error(state, tool_call, reason)
          end

        :direct ->
          start_capability_task(state, capability, arguments, tool_call, approved?)
      end
    else
      nil ->
        send_capability_error(state, tool_call, :unknown_capability)

      false ->
        send_capability_error(state, tool_call, :capability_already_running)

      {:error, reason} ->
        send_capability_error(state, tool_call, reason)
    end
  end

  defp on_capability_call(_item, state) do
    emit(state, :session_error, %{source: :provider, reason: :invalid_capability_call})
  end

  defp decode_call_arguments(%{"arguments" => arguments}) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :capability_arguments_must_be_an_object}
      {:error, _reason} -> {:error, :invalid_capability_arguments}
    end
  end

  defp decode_call_arguments(_item), do: {:ok, %{}}

  defp workflow_query(%{"query" => query}, _state) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, :missing_workflow_query}
      trimmed -> {:ok, trimmed}
    end
  end

  defp workflow_query(_arguments, state), do: last_input_query(state)

  defp last_input_query(%{last_final_input: %{text: text}})
       when is_binary(text) and text != "",
       do: {:ok, text}

  defp last_input_query(_state), do: {:error, :missing_workflow_query}

  defp start_workflow_task(state, input_text, tool_call \\ nil) do
    timeout_ms = state.workflow_timeout_ms
    run_id = state.run_id

    Logger.debug(
      "[voice.realtime] workflow_start session=#{state.session_id} run=#{run_id} query=#{inspect(input_text)}"
    )

    :telemetry.execute(
      [:synaptic, :voice, :realtime, :workflow, :start],
      %{},
      telemetry_metadata(state)
    )

    task = Task.async(fn -> run_workflow_turn(run_id, input_text, timeout_ms) end)

    state
    |> Map.put(:current_task, %{
      kind: :workflow,
      task: task,
      input: input_text,
      tool_call: tool_call
    })
    |> emit(:workflow_started, %{input: input_text})
  end

  defp start_capability_task(state, capability, arguments, tool_call, approved?) do
    context = state.session_context
    policy = state.profile.security_policy

    task =
      Task.async(fn ->
        CapabilityGateway.execute(capability, arguments, context, policy, confirmed: approved?)
      end)

    state
    |> Map.put(:current_task, %{
      kind: :capability,
      task: task,
      capability: capability,
      arguments: arguments,
      tool_call: tool_call
    })
    |> emit(:capability_started, %{name: capability.name})
  end

  defp handle_task_result(result, state, %{kind: :capability} = task_meta),
    do: handle_capability_result(result, state, task_meta)

  defp handle_task_result(result, state, task_meta),
    do: handle_workflow_result(result, state, task_meta)

  defp handle_capability_result(
         {:confirmation_required, details},
         state,
         %{capability: capability, tool_call: tool_call}
       ) do
    state
    |> Map.update!(:pending_confirmations, &MapSet.put(&1, capability.name))
    |> send_confirmation_required(tool_call, details)
  end

  defp handle_capability_result(
         {:ok, result},
         state,
         %{capability: capability, tool_call: tool_call}
       ) do
    send_capability_result(state, tool_call, capability, result)
  end

  defp handle_capability_result(
         {:error, reason},
         state,
         %{tool_call: tool_call}
       ) do
    send_capability_error(state, tool_call, reason)
  end

  defp handle_workflow_result({:ok, answer}, state, %{tool_call: tool_call})
       when is_map(tool_call) do
    send_capability_result(state, tool_call, Map.get(state.capabilities, tool_call.name), answer)
  end

  defp handle_workflow_result({:ok, answer}, state, _task_meta) do
    Logger.debug(
      "[voice.realtime] workflow_ok session=#{state.session_id} run=#{state.run_id} answer_chars=#{String.length(answer || "")}"
    )

    Logger.debug(
      "[voice.realtime] workflow_answer session=#{state.session_id} run=#{state.run_id} preview=#{inspect(truncate_for_log(answer, 240))}"
    )

    now_ms = System.monotonic_time(:millisecond)
    mark = Map.get(state.telemetry_marks, :user_final_at_ms)

    if is_integer(mark) do
      :telemetry.execute(
        [:synaptic, :voice, :realtime, :workflow, :stop],
        %{user_final_to_assistant_start_ms: max(now_ms - mark, 0)},
        telemetry_metadata(state)
      )
    end

    if state.response_active do
      _ = send_provider_event(state, %{"type" => "response.cancel"})
    end

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "output_modalities" => ["audio"],
          "max_output_tokens" => 800,
          "instructions" =>
            [
              "SERVER ORCHESTRATION MODE.",
              language_instruction(state),
              "Read the answer below to the user.",
              "Keep factual details intact.",
              "Do not add disclaimers or unrelated caveats.",
              "ANSWER:",
              answer
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> emit(:assistant_response_started, %{source: :workflow})
    |> update_status(:speaking)
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp handle_workflow_result({:error, reason}, state, %{tool_call: tool_call})
       when is_map(tool_call) do
    send_capability_error(state, tool_call, reason)
  end

  defp handle_workflow_result({:error, reason}, state, _task_meta) do
    Logger.error(
      "[voice.realtime] workflow_error session=#{state.session_id} run=#{state.run_id} reason=#{inspect(reason)}"
    )

    state
    |> Map.put(:response_active, false)
    |> emit(:session_error, %{source: :workflow, reason: reason})
    |> update_status(:listening)
    |> emit(:duplex_state_changed, %{status: :listening, mode: :realtime})
  end

  defp send_capability_result(state, tool_call, capability, result) do
    Logger.debug(
      "[voice.realtime] capability_ok session=#{state.session_id} run=#{state.run_id} name=#{tool_call.name}"
    )

    _ =
      send_provider_event(state, %{
        "type" => "conversation.item.create",
        "item" => %{
          "type" => "function_call_output",
          "call_id" => tool_call.call_id,
          "output" => Jason.encode!(%{ok: true, result: json_safe(result)})
        }
      })

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "output_modalities" => ["audio"],
          "instructions" =>
            [
              language_instruction(state),
              "Use the successful #{tool_call.name} capability result to answer the user.",
              "Preserve names, numbers, links, and other factual details.",
              capability_response_instruction(capability),
              "Phrase the answer naturally in your own conversational voice; do not read raw tool output verbatim."
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> update_status(:speaking)
    |> emit(:capability_completed, %{name: tool_call.name})
    |> emit(:assistant_response_started, %{source: :capability})
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp send_capability_error(state, tool_call, reason) do
    Logger.error(
      "[voice.realtime] capability_error session=#{state.session_id} run=#{state.run_id} name=#{tool_call.name} reason=#{inspect(reason)}"
    )

    _ =
      send_provider_event(state, %{
        "type" => "conversation.item.create",
        "item" => %{
          "type" => "function_call_output",
          "call_id" => tool_call.call_id,
          "output" => Jason.encode!(%{ok: false, error: capability_error_code(reason)})
        }
      })

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "output_modalities" => ["audio"],
          "instructions" =>
            [
              language_instruction(state),
              "Briefly explain that #{tool_call.name} could not complete the request.",
              "Ask the user whether they want to retry or provide more detail."
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> update_status(:speaking)
    |> emit(:capability_failed, %{name: tool_call.name, reason: reason})
    |> emit(:assistant_response_started, %{source: :capability_error})
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp send_confirmation_required(state, tool_call, details) do
    _ =
      send_provider_event(state, %{
        "type" => "conversation.item.create",
        "item" => %{
          "type" => "function_call_output",
          "call_id" => tool_call.call_id,
          "output" =>
            Jason.encode!(%{
              ok: false,
              confirmation_required: true,
              capability: tool_call.name,
              risk: details.risk
            })
        }
      })

    _ =
      send_provider_event(state, %{
        "type" => "response.create",
        "response" => %{
          "output_modalities" => ["audio"],
          "instructions" =>
            [
              language_instruction(state),
              "Ask the user for explicit confirmation before using #{tool_call.name}.",
              "Clearly summarize the intended action. Do not claim it has run.",
              "After the application records confirmation, retry the capability once."
            ]
            |> Enum.join("\n")
        }
      })

    state
    |> Map.put(:response_active, true)
    |> update_status(:speaking)
    |> emit(:capability_confirmation_required, %{
      name: tool_call.name,
      risk: details.risk,
      one_shot: true
    })
    |> emit(:assistant_response_started, %{source: :capability_confirmation})
    |> emit(:duplex_state_changed, %{status: :speaking, mode: :realtime})
  end

  defp run_workflow_turn(run_id, input_text, timeout_ms) do
    with :ok <- Synaptic.resume(run_id, %{human_input_text: input_text}),
         {:ok, snapshot} <- await_workflow_snapshot(run_id, timeout_ms) do
      assistant_answer = get_in(snapshot, [:context, :assistant_answer])

      if is_binary(assistant_answer) and String.trim(assistant_answer) != "" do
        {:ok, assistant_answer}
      else
        fallback = fallback_answer(snapshot, input_text)

        if is_binary(fallback) and String.trim(fallback) != "" do
          {:ok, fallback}
        else
          {:error, :missing_assistant_answer}
        end
      end
    end
  catch
    :exit, reason -> {:error, {:run_exit, reason}}
  end

  defp fallback_answer(snapshot, _input_text) do
    Enum.find_value([:answer, :response, :reply], fn key ->
      value = get_in(snapshot, [:context, key])

      if is_binary(value) and String.trim(value) != "" do
        value
      end
    end)
  end

  defp await_workflow_snapshot(run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_snapshot(run_id, deadline, 0)
  end

  defp do_await_snapshot(run_id, deadline_ms, attempts) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline_ms do
      {:error, :workflow_timeout}
    else
      case safe_inspect(run_id, 1_000) do
        {:ok, snapshot} ->
          case snapshot.status do
            status when status in [:waiting_for_human, :completed] ->
              {:ok, snapshot}

            :failed ->
              {:error, {:workflow_failed, snapshot.last_error}}

            :stopped ->
              {:error, {:workflow_stopped, snapshot.last_error}}

            _ ->
              Process.sleep(100)
              do_await_snapshot(run_id, deadline_ms, attempts + 1)
          end

        {:error, :busy_timeout} ->
          if rem(attempts + 1, 10) == 0 do
            Logger.debug(
              "[voice.realtime] workflow_waiting session_run=#{run_id} reason=runner_busy attempts=#{attempts + 1}"
            )
          end

          Process.sleep(100)
          do_await_snapshot(run_id, deadline_ms, attempts + 1)

        {:error, reason} ->
          {:error, {:workflow_snapshot_error, reason}}
      end
    end
  end

  defp safe_inspect(run_id, timeout_ms) do
    {:ok, Synaptic.inspect(run_id, timeout_ms)}
  catch
    :exit, {:timeout, _} -> {:error, :busy_timeout}
    :exit, reason -> {:error, {:inspect_exit, reason}}
  end

  defp cancel_inflight(%{current_task: nil} = state), do: state

  defp cancel_inflight(%{current_task: %{task: task}} = state) do
    _ = Task.shutdown(task, :brutal_kill)

    :telemetry.execute(
      [:synaptic, :voice, :realtime, :workflow, :cancel],
      %{},
      Map.put(telemetry_metadata(state), :reason, :interrupted)
    )

    state
    |> Map.put(:current_task, nil)
    |> emit(:workflow_canceled, %{reason: :interrupted})
  end

  defp send_provider_event(state, event) do
    state.sideband_adapter.send_event(state.sideband_pid, event)
  end

  defp update_status(state, status), do: %{state | status: status}

  defp put_telemetry_mark(state, key, value) do
    update_in(state.telemetry_marks, &Map.put(&1, key, value))
  end

  defp emit(state, name, data) do
    event = Event.build(state.session_id, state.run_id, state.seq + 1, name, data)

    PubSub.broadcast(
      Synaptic.PubSub,
      session_topic(state.session_id),
      {:synaptic_voice_event, event}
    )

    %{state | seq: state.seq + 1}
  end

  defp run_topic(run_id), do: "synaptic:run:" <> run_id
  defp session_topic(session_id), do: "synaptic:voice:session:" <> session_id

  defp public_transport(realtime) when is_map(realtime) do
    realtime
    |> Map.take([
      :provider,
      :experience,
      :model,
      :voice,
      :session_id,
      :expires_at,
      :client_secret
    ])
  end

  defp choose_backchannel_phrase([]), do: "One moment while I check that."
  defp choose_backchannel_phrase([single]), do: single
  defp choose_backchannel_phrase(phrases), do: Enum.random(phrases)

  defp language_instruction(%{preferred_language: "sk"}),
    do: "Speak only in Slovak (sk-SK)."

  defp language_instruction(%{preferred_language: "en"}),
    do: "Speak only in English (en-US)."

  defp language_instruction(%{preferred_language: code}) when is_binary(code),
    do: "Speak only in language code #{code}."

  defp log_provider_error(state, data) do
    Logger.error(
      "[voice.realtime] provider_error session=#{state.session_id} run=#{state.run_id} details=#{inspect(data, pretty: true, limit: 30)}"
    )
  end

  defp log_assistant_chunk(state, %{text: text}) when is_binary(text) do
    Logger.debug(
      "[voice.realtime] assistant_chunk session=#{state.session_id} run=#{state.run_id} chars=#{String.length(text)} text=#{inspect(truncate_for_log(text, 240))}"
    )
  end

  defp log_assistant_chunk(_state, _data), do: :ok

  defp suppress_provider_response?(%{
         suppress_provider_responses_during_workflow: true,
         current_task: current_task
       })
       when not is_nil(current_task),
       do: true

  defp suppress_provider_response?(_state), do: false

  defp resolve_profile(%Profile{} = profile), do: Profile.new!(profile)

  defp resolve_profile(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :profile, 0) do
      module.profile() |> Profile.new!()
    else
      raise ArgumentError, "voice profile module #{inspect(module)} must implement profile/0"
    end
  end

  defp resolve_profile(attrs), do: Profile.new!(attrs)

  defp resolve_experience(opts, config) do
    requested = Keyword.get(opts, :experience)

    cond do
      requested in [:legacy, "legacy"] ->
        :legacy

      requested in [:realtime_2_1, "realtime_2_1"] ->
        :realtime_2_1

      not is_nil(requested) ->
        raise ArgumentError,
              "unsupported OpenAI realtime experience: #{inspect(requested)}"

      not is_nil(Keyword.get(opts, :profile)) ->
        :realtime_2_1

      config[:default_experience] == :realtime_2_1 ->
        :realtime_2_1

      true ->
        :legacy
    end
  end

  defp experience_default(:legacy, :model, config),
    do: config[:realtime_model] || "gpt-4o-realtime-preview"

  defp experience_default(:legacy, :voice, config), do: config[:voice] || "alloy"

  defp experience_default(:legacy, :response_mode, config),
    do: config[:realtime_response_mode] || :orchestrated

  defp experience_default(:realtime_2_1, :model, config),
    do: config[:realtime_2_1_model] || "gpt-realtime-2.1"

  defp experience_default(:realtime_2_1, :voice, config),
    do: config[:realtime_2_1_voice] || "marin"

  defp experience_default(:realtime_2_1, :response_mode, config),
    do: config[:realtime_2_1_response_mode] || :native

  defp capability_response_instruction(nil),
    do: "Use only the facts returned by the capability."

  defp capability_response_instruction(capability) do
    case capability.limitations do
      [] -> "Use only the facts returned by the capability."
      limitations -> "Respect these limitations: #{Enum.join(limitations, "; ")}."
    end
  end

  defp capability_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp capability_error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp capability_error_code(_reason), do: "capability_failed"

  defp json_safe(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), json_safe(nested)} end)
    |> Map.new()
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_binary(value), do: value
  defp json_safe(value) when is_number(value), do: value
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_safe/1)

  defp json_safe(value), do: inspect(value, limit: 100, printable_limit: 2_000)

  defp truncate_for_log(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "..."
  end

  defp telemetry_metadata(state) do
    %{
      session_id: state.session_id,
      run_id: state.run_id,
      mode: :realtime,
      stt_provider: nil,
      tts_provider: nil,
      realtime_provider: state.stack.realtime
    }
  end

  defp normalize_response_mode(:orchestrated), do: :orchestrated
  defp normalize_response_mode("orchestrated"), do: :orchestrated
  defp normalize_response_mode(_), do: :native
end
