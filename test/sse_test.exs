defmodule AudioFlow.SSETest do
  use ExUnit.Case, async: true

  test "SSE preserves UTF-8 and data lines across every byte boundary" do
    bytes = <<239, 187, 191>> <> ": comment\rdata: {\"text\":\r\ndata: \"café\"}\r\r"

    {events, _} =
      for <<byte <- bytes>>, reduce: {[], AudioFlow.SSE.new(128)} do
        {events, state} ->
          {:ok, next, state} = AudioFlow.SSE.push(state, <<byte>>)
          {events ++ next, state}
      end

    assert events == ["{\"text\":\n\"café\"}"]
  end

  test "an unterminated event cannot grow beyond the byte limit" do
    {:ok, [], state} = AudioFlow.SSE.push(AudioFlow.SSE.new(16), "data: 123")
    assert {:error, :event_too_large} = AudioFlow.SSE.push(state, "4567890123")
  end
end
