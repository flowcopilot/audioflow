defmodule AudioFlow.GraphOptionSchemaTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Graph

  defmodule Nodes do
    @behaviour AudioFlow.Graph.Node
    def nodes do
      [
        %{
          type: "test.options",
          title: "Options",
          description: "",
          input: :text,
          output: :text,
          options: [
            %{name: :label, type: :string, required: true},
            %{name: :count, type: :integer, default: 2},
            %{name: :enabled, type: :boolean, default: false},
            %{name: :mode, type: {:enum, ["fast", "slow"]}},
            %{name: :optional, type: :string}
          ]
        }
      ]
    end

    def adapter(_, options), do: {__MODULE__, Map.to_list(options)}
  end

  defp graph(options, settings) do
    %{
      "nodes" => [
        %{"id" => "input", "type" => "input.text"},
        %{"id" => "tool", "type" => "test.options", "options" => options}
      ],
      "edges" => [%{"from" => "input", "to" => "tool"}],
      "settings" => settings
    }
  end

  defp catalog, do: Graph.catalog([Graph.Nodes.Input, Nodes])

  test "nil requests defaults, optional nil is omitted, and false reaches the adapter" do
    for options <- [
          %{"label" => "", "count" => nil, "optional" => nil},
          %{label: "", enabled: false}
        ] do
      assert {:ok, session} =
               Graph.session_options(graph(options, %{"timeout_ms" => nil}), catalog())

      assert {Nodes, options} = session[:graph].steps["tool"].adapter
      assert Map.new(options) == %{label: "", count: 2, enabled: false}
      refute Keyword.has_key?(session, :timeout_ms)
    end
  end

  test "runtime accumulates unknown, required, type, enum and settings errors without coercion" do
    invalid = %{"extra" => 1, "count" => "3", "enabled" => "false", "mode" => "other"}
    settings = %{"history" => "false", "timeout_ms" => 0, "max_events" => 1.5}

    assert {:error, errors} = Graph.validate(graph(invalid, settings), catalog())

    assert errors == [
             ~s(node "tool": unknown option "extra"),
             ~s(node "tool": option label is required),
             ~s(node "tool": option count must be a integer),
             ~s(node "tool": option enabled must be a boolean),
             ~s(node "tool": option mode must be one of "fast", "slow"),
             "setting history must be a boolean",
             "setting max_events must be a positive integer",
             "setting timeout_ms must be a positive integer"
           ]
  end
end
