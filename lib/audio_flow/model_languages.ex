defmodule AudioFlow.ModelLanguages do
  @moduledoc """
  Curated native speech language configuration, independent of model loading.

  Whisper's `"auto"` preserves automatic language detection. Explicit languages
  use Bumblebee's ISO alpha-2 codes. English-only `.en` repositories reject
  non-English languages before downloading. MMS uses a separate model per
  language, with its model's single speaker rather than selectable Kokoro voices.
  """
  @whisper ~w(auto en es fr de it pt ro ja zh hi)
  @vits %{
    "Xenova/mms-tts-eng" => %{
      language: "en",
      revision: "3f8955a2adbd6487ce57420620d4916de22b9dac"
    },
    "Xenova/mms-tts-spa" => %{
      language: "es",
      revision: "03f05a694412894ff930e9418fa05f52d66d6ad3"
    },
    "Xenova/mms-tts-fra" => %{
      language: "fr",
      revision: "c7aa283bf5b599d3c804e4accab07f6394a2b4ae"
    },
    "Xenova/mms-tts-deu" => %{
      language: "de",
      revision: "b95ad64a0715453237dc47ed873235a0024b4275"
    }
  }

  def whisper_languages, do: @whisper
  def vits_models, do: @vits

  @doc "Validate and return Bumblebee serving language options."
  def whisper_options!(repository, language \\ "auto") do
    unless language in @whisper,
      do: raise(ArgumentError, "unsupported Whisper language: #{inspect(language)}")

    if String.ends_with?(repository, ".en") and language not in ["auto", "en"],
      do: raise(ArgumentError, "English-only Whisper models require auto or en")

    cond do
      String.ends_with?(repository, ".en") -> [task: nil]
      language == "auto" -> []
      true -> [language: language]
    end
  end
end
