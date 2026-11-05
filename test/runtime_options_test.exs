defmodule AudioFlow.RuntimeOptionsTest do
  use ExUnit.Case, async: true
  alias AudioFlow.History
  alias AudioFlow.Output

  test "history and interruption options remain strict with actionable argument errors" do
    for options <- [[max_turns: 0], [max_bytes: nil]] do
      {key, _} = hd(options)

      assert_raise ArgumentError, "history #{key} must be positive", fn ->
        History.new(options)
      end
    end

    assert_raise ArgumentError, fn -> History.new(unknown: true) end
    assert_raise ArgumentError, fn -> Output.interrupt(self(), "wait", unknown: true) end

    assert_raise ArgumentError, "min_words must be positive", fn ->
      Output.interrupt(self(), "wait", min_words: 0)
    end

    assert {:ok, :ignored} = Output.interrupt(self(), "wait")
  end
end
