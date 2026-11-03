defmodule AudioFlow.ModelLanguagesTest do
  use ExUnit.Case, async: true
  alias AudioFlow.ModelLanguages

  test "Whisper auto default is unchanged and explicit languages reach serving options" do
    assert ModelLanguages.whisper_options!("openai/whisper-tiny") == []

    for language <- ModelLanguages.whisper_languages() -- ["auto"] do
      assert ModelLanguages.whisper_options!("openai/whisper-tiny", language) == [
               language: language
             ]
    end

    assert ModelLanguages.whisper_options!("openai/whisper-tiny.en", "en") == [task: nil]

    assert_raise ArgumentError, ~r/English-only/, fn ->
      ModelLanguages.whisper_options!("openai/whisper-tiny.en", "es")
    end

    assert_raise ArgumentError, ~r/unsupported/, fn ->
      ModelLanguages.whisper_options!("openai/whisper-tiny", "invented")
    end
  end

  test "MMS choices are real language-specific repositories with pinned revisions" do
    models = ModelLanguages.vits_models()

    assert Map.keys(models) |> Enum.sort() ==
             ~w(Xenova/mms-tts-deu Xenova/mms-tts-eng Xenova/mms-tts-fra Xenova/mms-tts-spa)

    assert Enum.sort(Enum.map(models, fn {_, info} -> info.language end)) == ~w(de en es fr)
    for {_, info} <- models, do: assert(Regex.match?(~r/\A[0-9a-f]{40}\z/, info.revision))
  end
end
