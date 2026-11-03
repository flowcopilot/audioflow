if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.ModelLanguageGraphTest do
    use ExUnit.Case, async: true
    alias AudioFlow.{Graph, ModelLanguages}
    alias AudioFlow.Graph.Nodes.Models

    defp graph(type, options, input) do
      %{
        "nodes" => [
          %{"id" => "in", "type" => input},
          %{"id" => "model", "type" => type, "options" => options}
        ],
        "edges" => [%{"from" => "in", "to" => "model"}]
      }
    end

    test "language metadata, graph validation, and cache keys preserve independent servings" do
      catalog = Graph.catalog([Graph.Nodes.Input, Models])
      whisper = Enum.find(Graph.node_types(catalog), &(&1.type == "whisper.stt"))
      assert Enum.find(whisper.options, &(&1.name == :language)).default == "auto"

      assert {:error, _} =
               Graph.validate(
                 graph("whisper.stt", %{"language" => "bad"}, "input.audio"),
                 catalog
               )

      assert :ok =
               Graph.validate(graph("whisper.stt", %{"language" => "es"}, "input.audio"), catalog)

      {_, auto} = Models.adapter("whisper.stt", %{model: "openai/whisper-tiny"})

      {_, spanish} =
        Models.adapter("whisper.stt", %{model: "openai/whisper-tiny", language: "es"})

      assert auto[:key] == {:whisper, "openai/whisper-tiny", "auto"}
      assert auto[:key] != spanish[:key]

      assert_raise ArgumentError, ~r/English-only/, fn ->
        Models.adapter("whisper.stt", %{model: "openai/whisper-tiny.en", language: "es"})
      end

      vits = Enum.find(Graph.node_types(catalog), &(&1.type == "vits.tts"))
      assert hd(vits.options).default == "Xenova/mms-tts-eng"

      for {repository, _} <- ModelLanguages.vits_models() do
        assert :ok =
                 Graph.validate(
                   graph("vits.tts", %{"model" => repository}, "input.text"),
                   catalog
                 )

        {_, adapter} = Models.adapter("vits.tts", %{model: repository})
        assert adapter[:key] == {:vits, repository}
      end

      assert {:error, _} =
               Graph.validate(graph("vits.tts", %{"model" => "invented"}, "input.text"), catalog)
    end

    @tag :model
    @tag timeout: 600_000
    test "multilingual VITS repositories produce non-silent PCM through the real graph adapter" do
      start_supervised!(AudioFlow.Servings)
      samples = %{"spa" => "Hola mundo.", "fra" => "Bonjour le monde.", "deu" => "Hallo Welt."}

      for {suffix, text} <- samples do
        {module, options} = Models.adapter("vits.tts", %{model: "Xenova/mms-tts-" <> suffix})
        {:ok, collector} = Agent.start_link(fn -> [] end)

        assert :ok =
                 module.run(text, options, fn audio -> Agent.update(collector, &[audio | &1]) end)

        chunks = Agent.get(collector, &Enum.reverse/1)
        Agent.stop(collector)
        assert chunks != []
        assert Enum.all?(chunks, &(AudioFlow.Audio.valid?(&1) and &1.sample_rate == 16_000))
        pcm = Enum.map_join(chunks, & &1.data)
        samples = for <<sample::little-signed-16 <- pcm>>, do: sample
        assert Enum.any?(samples, &(abs(&1) > 50))
      end
    end
  end
end
