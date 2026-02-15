defmodule Synaptic.Voice.Event do
  @moduledoc """
  Helpers for building and validating normalized voice event envelopes.
  """

  @type t :: %{
          required(:v) => pos_integer(),
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:ts_ms) => integer(),
          required(:event) => atom(),
          required(:data) => map()
        }

  @spec build(String.t(), String.t(), non_neg_integer(), atom(), map()) :: t()
  def build(session_id, run_id, seq, event, data) do
    %{
      v: 1,
      session_id: session_id,
      run_id: run_id,
      seq: seq,
      ts_ms: System.system_time(:millisecond),
      event: event,
      data: data
    }
  end

  @spec valid?(map()) :: boolean()
  def valid?(event) when is_map(event) do
    is_integer(event[:v]) and event[:v] > 0 and
      is_binary(event[:session_id]) and event[:session_id] != "" and
      is_binary(event[:run_id]) and event[:run_id] != "" and
      is_integer(event[:seq]) and event[:seq] >= 0 and
      is_integer(event[:ts_ms]) and
      is_atom(event[:event]) and
      is_map(event[:data])
  end

  def valid?(_), do: false
end
