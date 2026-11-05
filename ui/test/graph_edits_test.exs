defmodule AudioFlowUI.GraphEditsTest do
  use ExUnit.Case, async: true
  alias AudioFlowUI.GraphEdits

  @types %{
    "tool" => %{
      "options" => [
        %{"name" => "label", "type" => "string", "required" => true},
        %{"name" => "count", "type" => "integer", "default" => 2},
        %{"name" => "enabled", "type" => "boolean"},
        %{"name" => "mode", "type" => "enum", "values" => ["fast", "slow"]}
      ]
    }
  }

  defp graph(options),
    do: %{"nodes" => [%{"id" => "tool", "type" => "tool", "options" => options}]}

  test "partial edits preserve absent fields and remove blanks without filling defaults or required fields" do
    original = graph(%{"label" => "old", "enabled" => true, "legacy" => "kept"})
    params = %{"label" => " \t", "count" => " 3 ", "mode" => "slow", "unknown" => "ignored"}
    assert {:ok, edited} = GraphEdits.set_options(original, "tool", params, @types)

    assert hd(edited["nodes"])["options"] ==
             %{"count" => 3, "mode" => "slow", "enabled" => true, "legacy" => "kept"}

    assert {:ok, edited} =
             GraphEdits.set_options(graph(%{"count" => 9}), "tool", %{"count" => ""}, @types)

    refute Map.has_key?(hd(edited["nodes"]), "options")
    assert {:ok, edited} = GraphEdits.set_options(graph(%{}), "tool", %{}, @types)
    refute Map.has_key?(hd(edited["nodes"]), "options")
  end

  test "checkbox coercion stays deliberate and invalid form values are rejected" do
    for {value, expected} <- [
          {"on", true},
          {"true", true},
          {true, true},
          {"false", false},
          {"", false}
        ] do
      assert {:ok, edited} =
               GraphEdits.set_options(graph(%{}), "tool", %{"enabled" => value}, @types)

      assert hd(edited["nodes"])["options"] == %{"enabled" => expected}
    end

    for {params, message} <- [
          {%{"count" => "3x"}, "option count must be an integer"},
          {%{"count" => 3}, "option count has an incorrect value"},
          {%{"mode" => "other"}, "option mode must be one of fast, slow"}
        ] do
      assert {:error, ^message} = GraphEdits.set_options(graph(%{}), "tool", params, @types)
    end
  end
end
