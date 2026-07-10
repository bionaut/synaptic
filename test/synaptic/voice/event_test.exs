defmodule Synaptic.Voice.EventTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.Event

  test "build/5 produces a valid envelope" do
    event = Event.build("session-1", "run-1", 2, :assistant_text_chunk, %{text: "hello"})

    assert event.v == 1
    assert event.session_id == "session-1"
    assert event.run_id == "run-1"
    assert event.seq == 2
    assert event.event == :assistant_text_chunk
    assert Event.valid?(event)
  end

  test "valid?/1 rejects malformed payloads" do
    refute Event.valid?(%{v: 1})

    refute Event.valid?(%{
             v: 1,
             session_id: "x",
             run_id: "y",
             seq: -1,
             ts_ms: 1,
             event: :ok,
             data: %{}
           })
  end
end
