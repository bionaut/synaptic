defmodule Synaptic.Tools.CodexExec do
  @moduledoc """
  Adapter that delegates a Synaptic chat request to local Codex non-interactive mode.

  This adapter runs `codex exec` as a local subprocess and returns the final Codex
  response. It is useful when a workflow wants to delegate a bounded coding or
  repository-reasoning task to Codex without changing Synaptic's adapter facade.

  The adapter does not implement Synaptic's OpenAI-style tool-call loop. Codex can
  still use tools configured in Codex itself, but `tools:` and `mcp:` entries passed
  through `Synaptic.Tools.chat/2` are rejected because there is no stable mapping
  from Codex exec output back to OpenAI tool-call messages.

  ## Configuration

      config :synaptic, Synaptic.Tools.CodexExec,
        codex_bin: "/Applications/Codex.app/Contents/Resources/codex",
        model: "gpt-5.5",
        model_reasoning_effort: "low",
        sandbox: :read_only,
        approval_policy: :never,
        ephemeral: true,
        timeout_ms: 300_000

  Per-call options override application config.
  """

  use Synaptic.Tools.Adapter

  @app_bundle_bin "/Applications/Codex.app/Contents/Resources/codex"
  @default_timeout_ms 300_000

  @impl Synaptic.Tools.Adapter
  def chat(messages, opts \\ [])

  def chat(messages, opts) when is_list(messages) do
    with :ok <- validate_supported_opts(opts),
         {:ok, codex_bin} <- codex_bin(opts),
         {:ok, cwd} <- cwd(opts) do
      response_format = Keyword.get(opts, :response_format)
      prompt = build_prompt(messages, response_format)
      json? = option(opts, :json, true)
      args = build_args(opts, cwd, json?, prompt)
      command_opts = command_opts(opts, cwd)

      opts
      |> command_runner()
      |> run_with_timeout(codex_bin, args, command_opts, timeout_ms(opts))
      |> handle_exec_result(json?, response_format)
    end
  end

  def chat(_messages, _opts), do: {:error, :invalid_messages}

  @doc false
  def parse_exec_output(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{messages: [], usage: nil, errors: []}, &collect_event/2)
    |> final_from_events(output)
  end

  defp validate_supported_opts(opts) do
    case Keyword.get(opts, :tools, []) do
      nil -> :ok
      [] -> :ok
      _tools -> {:error, {:unsupported, :codex_exec_tool_loop}}
    end
  end

  defp codex_bin(opts) do
    [
      Keyword.get(opts, :codex_bin),
      config()[:codex_bin],
      System.get_env("SYNAPTIC_CODEX_BIN"),
      app_bundle_bin(),
      System.find_executable("codex")
    ]
    |> Enum.find(&usable_bin?/1)
    |> case do
      nil -> {:error, :codex_bin_not_found}
      bin -> {:ok, bin}
    end
  end

  defp usable_bin?(bin) when is_binary(bin) and byte_size(bin) > 0 do
    File.exists?(bin) or System.find_executable(bin)
  end

  defp usable_bin?(_), do: false

  defp app_bundle_bin do
    if File.exists?(@app_bundle_bin), do: @app_bundle_bin
  end

  defp cwd(opts) do
    cwd = Keyword.get(opts, :cwd) || config()[:cwd] || File.cwd!()

    if File.dir?(cwd) do
      {:ok, cwd}
    else
      {:error, {:invalid_cwd, cwd}}
    end
  end

  defp build_args(opts, cwd, json?, prompt) do
    []
    |> append_pair(
      "--ask-for-approval",
      normalize_approval_policy(option(opts, :approval_policy, :never))
    )
    |> Kernel.++(["exec"])
    |> maybe_append(json?, "--json")
    |> maybe_append(option(opts, :ephemeral, true), "--ephemeral")
    |> maybe_append(option(opts, :ignore_user_config, false), "--ignore-user-config")
    |> maybe_append(option(opts, :ignore_rules, false), "--ignore-rules")
    |> maybe_append(option(opts, :skip_git_repo_check, false), "--skip-git-repo-check")
    |> append_pair("-C", cwd)
    |> append_pair("--model", option(opts, :model, "gpt-5.5"))
    |> append_pair("--sandbox", normalize_sandbox(option(opts, :sandbox, :read_only)))
    |> append_pair("--profile", Keyword.get(opts, :profile))
    |> append_pair("--output-schema", Keyword.get(opts, :output_schema))
    |> append_repeated("--add-dir", Keyword.get(opts, :add_dir, []))
    |> append_pair("-c", reasoning_effort_config(option(opts, :model_reasoning_effort, "low")))
    |> append_repeated("-c", Keyword.get(opts, :config, []))
    |> append_extra_args(Keyword.get(opts, :extra_args, []))
    |> Kernel.++([prompt])
  end

  defp command_opts(opts, cwd) do
    opts
    |> Keyword.get(:cmd_opts, [])
    |> Keyword.merge(cd: cwd)
    |> Keyword.put_new(:stderr_to_stdout, true)
    |> maybe_put_env(opts)
  end

  defp maybe_put_env(command_opts, opts) do
    env = Keyword.get(opts, :env, config()[:env] || [])

    case env do
      [] -> command_opts
      env when is_list(env) -> Keyword.put(command_opts, :env, env)
      _ -> command_opts
    end
  end

  defp command_runner(opts) do
    Keyword.get(opts, :command_runner) ||
      config()[:command_runner] ||
      (&run_system_cmd/3)
  end

  defp run_system_cmd(codex_bin, args, opts) do
    case :os.type() do
      {:unix, _} ->
        System.cmd(
          "/bin/sh",
          ["-c", "exec \"$@\" </dev/null", "codex-exec"] ++ [codex_bin | args],
          opts
        )

      _other ->
        System.cmd(codex_bin, args, opts)
    end
  end

  defp timeout_ms(opts), do: option(opts, :timeout_ms, @default_timeout_ms)

  defp run_with_timeout(runner, codex_bin, args, command_opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    task = Task.async(fn -> run_command(runner, codex_bin, args, command_opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp run_with_timeout(runner, codex_bin, args, command_opts, _timeout_ms),
    do: run_command(runner, codex_bin, args, command_opts)

  defp run_command(runner, codex_bin, args, command_opts) do
    case runner.(codex_bin, args, command_opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, output, status}

      {:ok, output, status} when is_binary(output) and is_integer(status) ->
        {:ok, output, status}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_command_result, other}}
    end
  rescue
    error -> {:error, {:command_failed, error}}
  catch
    :exit, reason -> {:error, {:command_exited, reason}}
  end

  defp handle_exec_result({:ok, output, 0}, true, response_format) do
    output
    |> parse_exec_output()
    |> decode_response_format(response_format)
  end

  defp handle_exec_result({:ok, output, 0}, false, response_format) do
    output
    |> String.trim()
    |> ok_or_missing()
    |> decode_response_format(response_format)
  end

  defp handle_exec_result({:ok, output, status}, true, _response_format) do
    reason =
      case parse_exec_output(output) do
        {:error, parsed_reason} -> parsed_reason
        {:ok, content} -> %{content: content}
        {:ok, content, metadata} -> %{content: content, metadata: metadata}
      end

    {:error, {:codex_exec_failed, status, reason}}
  end

  defp handle_exec_result({:ok, output, status}, false, _response_format) do
    {:error, {:codex_exec_failed, status, String.trim(output)}}
  end

  defp handle_exec_result({:error, reason}, _json?, _response_format), do: {:error, reason}

  defp ok_or_missing(""), do: {:error, :missing_final_message}
  defp ok_or_missing(content), do: {:ok, content}

  defp collect_event(line, acc) do
    case Jason.decode(line) do
      {:ok, event} -> collect_decoded_event(event, acc)
      {:error, _reason} -> acc
    end
  end

  defp collect_decoded_event(
         %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}},
         acc
       )
       when is_binary(text) do
    %{acc | messages: acc.messages ++ [text]}
  end

  defp collect_decoded_event(
         %{"type" => "item.completed", "item" => %{"type" => "agent_message", "content" => text}},
         acc
       )
       when is_binary(text) do
    %{acc | messages: acc.messages ++ [text]}
  end

  defp collect_decoded_event(%{"type" => "turn.completed", "usage" => usage}, acc)
       when is_map(usage) do
    %{acc | usage: normalize_usage(usage)}
  end

  defp collect_decoded_event(%{"type" => "turn.failed"} = event, acc) do
    %{acc | errors: acc.errors ++ [Map.drop(event, ["type"])]}
  end

  defp collect_decoded_event(%{"type" => "error"} = event, acc) do
    %{acc | errors: acc.errors ++ [Map.drop(event, ["type"])]}
  end

  defp collect_decoded_event(_event, acc), do: acc

  defp final_from_events(%{messages: [message | rest], usage: usage}, _output) do
    content = List.last([message | rest])

    if usage do
      {:ok, content, %{usage: usage}}
    else
      {:ok, content}
    end
  end

  defp final_from_events(%{errors: [error | _]}, _output), do: {:error, error}

  defp final_from_events(_acc, output) do
    case String.trim(output) do
      "" -> {:error, :missing_final_message}
      raw -> {:error, {:invalid_jsonl_output, raw}}
    end
  end

  defp decode_response_format({:ok, content, metadata}, response_format) do
    case decode_response_content(content, response_format) do
      {:ok, decoded} -> {:ok, decoded, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_response_format({:ok, content}, response_format),
    do: decode_response_content(content, response_format)

  defp decode_response_format({:error, reason}, _response_format), do: {:error, reason}

  defp decode_response_content(content, nil), do: {:ok, content}
  defp decode_response_content(content, :text), do: {:ok, content}

  defp decode_response_content(content, :json_object), do: decode_json_content(content)

  defp decode_response_content(content, %{type: "json_object"}), do: decode_json_content(content)

  defp decode_response_content(content, %{"type" => "json_object"}),
    do: decode_json_content(content)

  defp decode_response_content(content, _response_format), do: {:ok, content}

  defp decode_json_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json_response}
    end
  end

  defp decode_json_content(content), do: {:ok, content}

  defp normalize_usage(usage) do
    %{
      prompt_tokens: Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) || 0,
      completion_tokens: Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) || 0,
      total_tokens:
        Map.get(usage, "total_tokens") ||
          Map.get(usage, :total_tokens) ||
          (Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) || 0) +
            (Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) || 0),
      cached_input_tokens:
        Map.get(usage, "cached_input_tokens") || Map.get(usage, :cached_input_tokens) || 0,
      reasoning_output_tokens:
        Map.get(usage, "reasoning_output_tokens") ||
          Map.get(usage, :reasoning_output_tokens) ||
          0
    }
  end

  defp build_prompt(messages, response_format) do
    parts =
      messages
      |> Enum.map(&format_message/1)
      |> Enum.join("\n\n")

    [
      "Respond to this conversation as the local Codex agent.",
      response_format_instruction(response_format),
      parts
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_message(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role") || "user"
    content = Map.get(message, :content) || Map.get(message, "content") || ""

    """
    [#{String.upcase(to_string(role))}]
    #{format_content(content)}
    """
    |> String.trim()
  end

  defp format_message(message), do: "[USER]\n#{format_content(message)}"

  defp format_content(content) when is_binary(content), do: content

  defp format_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{type: "text", text: text} -> text
      %{"text" => text} -> text
      %{text: text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp format_content(content), do: inspect(content)

  defp response_format_instruction(:json_object), do: "Return only a valid JSON object."
  defp response_format_instruction(%{type: "json_object"}), do: "Return only a valid JSON object."

  defp response_format_instruction(%{"type" => "json_object"}),
    do: "Return only a valid JSON object."

  defp response_format_instruction(_), do: nil

  defp option(opts, key, default) do
    Keyword.get(opts, key, Keyword.get(config(), key, default))
  end

  defp config, do: Application.get_env(:synaptic, __MODULE__, [])

  defp maybe_append(args, true, flag), do: args ++ [flag]
  defp maybe_append(args, _condition, _flag), do: args

  defp append_pair(args, _flag, nil), do: args
  defp append_pair(args, _flag, ""), do: args
  defp append_pair(args, flag, value), do: args ++ [flag, to_string(value)]

  defp append_repeated(args, _flag, nil), do: args
  defp append_repeated(args, _flag, []), do: args

  defp append_repeated(args, flag, values) when is_list(values) do
    Enum.reduce(values, args, fn value, acc -> append_pair(acc, flag, value) end)
  end

  defp append_repeated(args, flag, value), do: append_pair(args, flag, value)

  defp append_extra_args(args, extra_args) when is_list(extra_args),
    do: args ++ Enum.map(extra_args, &to_string/1)

  defp append_extra_args(args, _extra_args), do: args

  defp normalize_approval_policy(nil), do: nil
  defp normalize_approval_policy(:never), do: "never"
  defp normalize_approval_policy(:on_request), do: "on-request"
  defp normalize_approval_policy(:on_failure), do: "on-failure"
  defp normalize_approval_policy(:untrusted), do: "untrusted"
  defp normalize_approval_policy(policy), do: policy

  defp reasoning_effort_config(nil), do: nil
  defp reasoning_effort_config(""), do: nil
  defp reasoning_effort_config(effort), do: ~s(model_reasoning_effort="#{effort}")

  defp normalize_sandbox(nil), do: nil
  defp normalize_sandbox(:read_only), do: "read-only"
  defp normalize_sandbox(:workspace_write), do: "workspace-write"
  defp normalize_sandbox(:danger_full_access), do: "danger-full-access"
  defp normalize_sandbox(sandbox), do: sandbox
end
