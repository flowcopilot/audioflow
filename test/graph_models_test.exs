if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.GraphModelsTest do
    use ExUnit.Case, async: false
    alias AudioFlow.{Graph, Servings, Text}

    setup do
      start_supervised!(Servings)
      :ok
    end

    defp doubler, do: Nx.Serving.jit(&Nx.multiply(&1, 2), compiler: EXLA)

    defp double(name, number),
      do: Nx.Serving.batched_run(name, Nx.Batch.stack([Nx.tensor([number])])) |> Nx.to_flat_list()

    test "concurrent fetches share one load, and the serving is shared" do
      parent = self()

      build = fn ->
        send(parent, :building)
        Process.sleep(50)
        doubler()
      end

      [{:ok, name}, {:ok, name}] =
        [
          Task.async(fn -> Servings.fetch(:double, build) end),
          Task.async(fn -> Servings.fetch(:double, build) end)
        ]
        |> Task.await_many()

      assert_received :building
      refute_received :building
      assert double(name, 3) == [6.0]
      assert {:ok, ^name} = Servings.fetch(:double, build)
      assert Servings.loaded() == [:double]

      assert :ok = Servings.release(:double)
      assert Servings.loaded() == []
    end

    @tag :capture_log
    test "a failed load is reported and tried again on the next fetch" do
      assert {:error, :offline} = Servings.fetch(:flaky, fn -> {:error, :offline} end)
      assert {:error, {:load_exit, _}} = Servings.fetch(:flaky, fn -> raise "no weights" end)
      assert {:ok, _} = Servings.fetch(:flaky, &doubler/0)
    end

    test "every model node type has a valid spec and adapter" do
      catalog = Graph.catalog([Graph.Nodes.Input, Graph.Nodes.Models])

      for spec <- Graph.node_types(catalog), spec.input != nil do
        options =
          for option <- spec.options, into: %{} do
            {option.name, Map.get(option, :default, "x")}
          end

        assert {AudioFlow.Graph.ModelAdapter, adapter} =
                 Graph.Nodes.Models.adapter(spec.type, options)

        assert is_function(adapter[:build], 0)
      end

      # British voices share one serving with British English phonemes.
      key = fn voice ->
        {_, options} = Graph.Nodes.Models.adapter("kokoro.tts", %{voice: voice})
        options[:key]
      end

      assert key.("bf_emma") == key.("bm_george")
      assert key.("bf_emma") != key.("af_heart")
    end

    @tag :model
    @tag timeout: 600_000
    test "a text graph replies with Qwen3 and embeds the message" do
      graph = %{
        "nodes" => [
          %{"id" => "in", "type" => "input.text"},
          %{"id" => "llm", "type" => "qwen3.llm", "options" => %{"max_new_tokens" => 24}},
          %{"id" => "embed", "type" => "text.embedding"}
        ],
        "edges" => [%{"from" => "in", "to" => "llm"}, %{"from" => "in", "to" => "embed"}],
        "settings" => %{"timeout_ms" => 600_000}
      }

      catalog = Graph.catalog([Graph.Nodes.Input, Graph.Nodes.Models])
      {:ok, options} = Graph.session_options(graph, catalog)
      {:ok, session} = AudioFlow.start_session(options)
      {:ok, turn} = AudioFlow.submit(session, %Text{data: "Say hello."})

      assert_receive {AudioFlow, ^session, ^turn, {:text, text, "llm"}}, 600_000
      assert String.trim(text) != ""
      assert_receive {AudioFlow, ^session, ^turn, {:vector, vector, "embed"}}, 600_000
      assert length(vector) == 384
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}, 600_000
    end
  end
end
