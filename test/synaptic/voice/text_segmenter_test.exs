defmodule Synaptic.Voice.TextSegmenterTest do
  use ExUnit.Case, async: true

  alias Synaptic.Voice.TextSegmenter

  test "consume splits complete sentence segments and keeps remainder" do
    {segments, remainder} = TextSegmenter.consume("", "Hello world. How are")

    assert segments == ["Hello world."]
    assert remainder == " How are"
  end

  test "flush emits final remainder when present" do
    assert TextSegmenter.flush("leftover") == ["leftover"]
    assert TextSegmenter.flush("  ") == []
  end
end
