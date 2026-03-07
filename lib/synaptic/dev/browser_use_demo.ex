if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
  defmodule Synaptic.Dev.BrowserUseDemo do
    @moduledoc """
    Demo workflow that uses the browser-use MCP sidecar to scrape
    the first 10 videos from Andrej Karpathy's YouTube channel.

    Uses `retry_with_browser_use_agent` to delegate the entire browsing
    task to browser-use's server-side agent which uses vision (screenshots)
    internally. This keeps token usage minimal on our side.

    ## Prerequisites

        cd sidecar/browser-use
        # fill in OPENAI_API_KEY in .env
        ./start.sh

    ## Usage

        iex -S mix
        Synaptic.Dev.BrowserUseDemo.run()

    """

    use Synaptic.Workflow
    require Logger

    @youtube_url "https://www.youtube.com/@AndrejKarpathy/videos"

    @browser_use_mcp %{
      name: "browser_use",
      transport: :http,
      adapter: Synaptic.MCP.Adapters.HTTP,
      base_url: "http://localhost:8989/mcp"
    }

    step :scrape_videos do
      mcp_config = browser_use_mcp(context)

      Logger.debug(
        "[browser_use_demo] Scraping #{@youtube_url} via browser-use MCP endpoint=#{mcp_config[:base_url]}"
      )

      task = """
      Go to #{@youtube_url}.

      IMPORTANT — Cookie / privacy consent:
      If the page title says "Before you continue" or a consent overlay appears,
      look for a button labelled "Accept all" or "I agree" and click it.
      If that exact label is not visible, look for any prominent accept/agree
      button on the consent form. Do NOT try to reject or customise — just accept.
      Wait for the page to load after dismissing the consent.

      Once on the videos page:
      1. Scroll down until at least 10 video entries are visible.
      2. For each of the first 10 videos, extract:
         - title
         - full YouTube video URL (https://www.youtube.com/watch?v=...)
         - description or subtitle text shown below the title (if any)
      3. Return ONLY a JSON object (no markdown, no explanation):
         {
           "status": "success",
           "videos": [{"title": "...", "link": "https://...", "description": "..."}],
           "failure_reason": null
         }

      If you cannot complete the task, return:
         {"status": "failed", "videos": [], "failure_reason": "reason here"}
      """

      messages = [
        %{
          role: "system",
          content: """
          You have access to a browser automation agent via the
          `browser_use__retry_with_browser_use_agent` tool.
          Call it ONCE with the user's task and allowed_domains=["youtube.com", "consent.youtube.com"].
          Do NOT call any other browser_use tools.
          Return the agent's final result verbatim.
          """
        },
        %{role: "user", content: task}
      ]

      case Synaptic.Tools.chat(messages,
             mcp: [mcp_config],
             mcp_debug: true,
             model: "gpt-5-mini"
           ) do
        {:ok, result} ->
          Logger.debug("[browser_use_demo] Got result from agent")
          parse_agent_result(result)

        {:error, reason} ->
          Logger.error("[browser_use_demo] Failed: #{inspect(reason)}")
          {:error, reason}
      end
    end

    step :format_output do
      videos = Map.get(context, :videos, [])
      formatted = format_videos(videos)
      Logger.debug("[browser_use_demo] Done.\n\n#{formatted}")
      {:ok, %{formatted_output: formatted}}
    end

    commit()

    @doc """
    Convenience function to run the workflow in one shot.

    Options:
      - `:base_url` - override the MCP server URL (default: http://localhost:8989/mcp)
    """
    def run(opts \\ []) do
      base_url = Keyword.get(opts, :base_url, "http://localhost:8989/mcp")

      initial =
        if base_url != "http://localhost:8989/mcp" do
          %{mcp_base_url: base_url}
        else
          %{}
        end

      case Synaptic.start(Synaptic.Dev.BrowserUseDemo, initial) do
        {:ok, run_id} ->
          # The server-side agent can take a while — allow up to 5 minutes
          case Synaptic.inspect(run_id, 300_000) do
            {:ok, snapshot} ->
              IO.puts("\n=== Browser-Use Demo Result ===")

              IO.puts(
                snapshot.context[:formatted_output] ||
                  inspect(
                    snapshot.context[:videos] || snapshot.context[:raw_result] || "No result"
                  )
              )

              {:ok, snapshot}

            error ->
              error
          end

        error ->
          error
      end
    end

    defp browser_use_mcp(context) do
      case Map.get(context, :mcp_base_url) do
        base_url when is_binary(base_url) and base_url != "" ->
          Map.put(@browser_use_mcp, :base_url, base_url)

        _ ->
          @browser_use_mcp
      end
    end

    # The agent returns a text summary. Try to extract JSON from it.
    defp parse_agent_result(result) when is_binary(result) do
      case extract_json(result) do
        {:ok, parsed} ->
          normalize_result(parsed, result)

        :error ->
          # No JSON found — store the raw text as the result
          Logger.debug("[browser_use_demo] No JSON in agent result, storing raw text")
          {:ok, %{raw_result: result, videos: []}}
      end
    end

    defp parse_agent_result(result) when is_map(result) do
      normalize_result(result, inspect(result))
    end

    defp parse_agent_result(result) do
      {:ok, %{raw_result: inspect(result), videos: []}}
    end

    defp extract_json(text) do
      # Find the first { ... } JSON block in the text
      case Regex.run(~r/\{[\s\S]*\}/U, text) do
        [json_str | _] ->
          case Jason.decode(json_str) do
            {:ok, parsed} -> {:ok, parsed}
            _ -> try_greedy_json(text)
          end

        nil ->
          :error
      end
    end

    defp try_greedy_json(text) do
      case Regex.run(~r/\{[\s\S]*\}/, text) do
        [json_str | _] ->
          case Jason.decode(json_str) do
            {:ok, parsed} -> {:ok, parsed}
            _ -> :error
          end

        nil ->
          :error
      end
    end

    defp normalize_result(%{"status" => "success", "videos" => videos}, _raw)
         when is_list(videos) do
      cleaned =
        videos
        |> Enum.map(&normalize_video/1)
        |> Enum.filter(&valid_video?/1)
        |> Enum.take(10)

      {:ok, %{videos: cleaned, raw_result: Jason.encode!(videos)}}
    end

    defp normalize_result(%{"status" => "failed"} = result, _raw) do
      {:error, {:browser_use_failed, Map.get(result, "failure_reason"), result}}
    end

    defp normalize_result(_parsed, raw) do
      {:ok, %{raw_result: raw, videos: []}}
    end

    defp normalize_video(video) when is_map(video) do
      %{
        "title" => string_field(video, "title"),
        "link" => string_field(video, "link"),
        "description" => string_field(video, "description")
      }
    end

    defp normalize_video(_), do: %{"title" => "", "link" => "", "description" => ""}

    defp valid_video?(%{"title" => title, "link" => link})
         when is_binary(title) and is_binary(link) do
      String.trim(title) != "" and String.starts_with?(link, "http")
    end

    defp valid_video?(_), do: false

    defp string_field(map, key) do
      atom_key =
        case key do
          "title" -> :title
          "link" -> :link
          "description" -> :description
        end

      value = Map.get(map, key) || Map.get(map, atom_key, "")

      case value do
        nil -> ""
        binary when is_binary(binary) -> String.trim(binary)
        other -> to_string(other)
      end
    end

    defp format_videos(videos) when is_list(videos) do
      videos
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {video, index} ->
        """
        #{index}. Title: #{video["title"]}
           Link: #{video["link"]}
           Description: #{blank_if_empty(video["description"])}
        """
        |> String.trim()
      end)
    end

    defp blank_if_empty(""), do: "(not visible)"
    defp blank_if_empty(value), do: value
  end
end
