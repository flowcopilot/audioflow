defmodule AudioFlow.ToolTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Tool

  defp error(text), do: JSON.decode!(text)["error"]

  test "results are text for the model and failures become error objects" do
    tool = fn run -> Tool.new(%{name: "t", run: run}) end

    assert Tool.call(tool.(fn %{"a" => 1} -> {:ok, %{b: [:c]}} end), %{"a" => 1}) ==
             ~s({"b":["c"]})

    assert error(Tool.call(tool.(fn _ -> {:error, :down} end), %{})) == ":down"
    assert error(Tool.call(tool.(fn _ -> raise "boom" end), %{})) == "boom"
    assert error(Tool.call(tool.(fn _ -> :ok end), %{})) =~ "invalid tool result"

    assert error(Tool.call(tool.(fn _ -> {:ok, "long"} end), %{}, max_result_bytes: 3)) =~
             "larger than 3 bytes"

    slow = tool.(fn _ -> Process.sleep(:infinity) end)
    assert error(Tool.call(slow, %{}, timeout_ms: 10)) == "tool timed out after 10 ms"
  end

  test "invalid definitions are rejected" do
    assert_raise ArgumentError, fn -> Tool.new(%{name: "has space", run: &{:ok, &1}}) end
    assert_raise ArgumentError, fn -> Tool.new(Enum) end
  end
end
