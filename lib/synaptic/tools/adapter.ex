defmodule Synaptic.Tools.Adapter do
  @moduledoc """
  Behaviour for LLM adapter implementations.

  Adapters must implement the `chat/2` function to be compatible with
  `Synaptic.Tools.chat/2`.

  ## Example

      defmodule MyAdapter do
        use Synaptic.Tools.Adapter

        @impl Synaptic.Tools.Adapter
        def chat(messages, opts) do
          # Your implementation here
        end
      end
  """

  @doc """
  Sends a chat completion request to the LLM provider.

  ## Parameters

    * `messages` - A list of message maps with `:role` (or `"role"`) and `:content` (or `"content"`) keys
    * `opts` - Keyword list of options:
      * `:stream` - Boolean, if `true` enables streaming mode
      * `:tools` - List of tool specifications (provider-specific format)
      * `:model` - Model name/identifier
      * `:temperature` - Temperature setting (float)
      * `:on_chunk` - Callback function `(chunk :: String.t(), accumulated :: String.t() -> :ok)` for streaming
      * `:response_format` - Response format specification (provider-specific)
      * Other provider-specific options

  ## Returns

    * `{:ok, content}` - Success with content (string or decoded JSON map)
    * `{:ok, %{content: content, tool_calls: tool_calls}}` - Success with tool calls (atom keys)
    * `{:ok, %{"content" => content, "tool_calls" => tool_calls}}` - Success with tool calls (string keys)
    * `{:ok, accumulated}` - Success for streaming (final accumulated content as string)
    * `{:error, reason}` - Error tuple

  ## Tool Calls Format

  Tool calls should be returned as a list of maps with:
    * `"id"` or `:id` - Tool call identifier
    * `"function"` or `:function` - Map with:
      * `"name"` or `:name` - Tool name
      * `"arguments"` or `:arguments` - JSON string of arguments

  ## Streaming

  When `stream: true` and `on_chunk` callback is provided:
    * Call `on_chunk.(chunk, accumulated)` for each chunk received
    * Return `{:ok, final_accumulated}` when streaming completes
    * The accumulated value should be the full content as a string
  """
  @callback chat(messages :: list(map()), opts :: keyword()) ::
              {:ok, String.t() | map()}
              | {:ok, %{content: String.t() | map(), tool_calls: list(map())}}
              | {:ok, %{String.t() => String.t() | map(), String.t() => list(map())}}
              | {:error, term()}


  @doc """
  Macro to implement the Adapter behaviour.
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Synaptic.Tools.Adapter
    end
  end

end
