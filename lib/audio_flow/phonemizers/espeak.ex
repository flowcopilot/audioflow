defmodule AudioFlow.Phonemizers.ESpeak do
  @moduledoc """
  Local English phoneme conversion for Kokoro v1 with espeak-ng.

  Requires the `espeak-ng` executable. Options: `:executable` and `:language`
  (`"en-us"` or `"en-gb"`). Punctuation is retained as model pause tokens.
  Speech inference runs in Nx; espeak-ng only converts text to phonemes.
  """
  @behaviour AudioFlow.Phonemizer

  @impl true
  def phonemize(text, options \\ []) when is_binary(text) do
    language = Keyword.get(options, :language, "en-us")
    executable = Keyword.get(options, :executable) || System.find_executable("espeak-ng")

    cond do
      language not in ["en-us", "en-gb"] -> {:error, :unsupported_language}
      executable == nil -> {:error, :espeak_not_found}
      byte_size(text) > 16_384 -> {:error, :text_too_large}
      not String.valid?(text) -> {:error, :invalid_text}
      true -> convert(text, executable, language)
    end
  end

  defp convert(text, executable, language) do
    text = text |> String.replace(["’", "‘"], "'") |> String.replace(["“", "”"], "\"")
    parts = Regex.split(~r/([,.;:!?…—]+)/u, text, include_captures: true, trim: true)

    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, output} ->
      if Regex.match?(~r/^[,.;:!?…—]+$/u, part) do
        {:cont, {:ok, [part | output]}}
      else
        # Arguments go directly to the executable. Text never goes through a shell.
        case System.cmd(executable, ["-q", "--ipa", "-v", language, "--", part]) do
          {ipa, 0} -> {:cont, {:ok, [normalize(ipa, language) | output]}}
          {_output, status} -> {:halt, {:error, {:espeak_exit, status}}}
        end
      end
    end)
    |> case do
      {:ok, parts} ->
        phonemes = parts |> Enum.reverse() |> Enum.join(" ") |> String.trim()
        {:ok, Regex.replace(~r/\s+([,.;:!?…—])/u, phonemes, "\\1")}

      error ->
        error
    end
  rescue
    error in ErlangError -> {:error, {:espeak_start, Exception.message(error)}}
  end

  # English Kokoro v1 diphthongs and affricates use single vocabulary symbols.
  # Mapping follows the English fallback in hexgrad/misaki (Apache-2.0).
  defp normalize(ipa, language) do
    replacements = [
      {"aɪ", "I"},
      {"aʊ", "W"},
      {"eɪ", "A"},
      {"ɔɪ", "Y"},
      {"dʒ", "ʤ"},
      {"tʃ", "ʧ"},
      {"ɚ", "əɹ"},
      {"ɐ", "ə"},
      {"r", "ɹ"},
      {"ɾ", "T"},
      {"ʔ", "t"}
    ]

    ipa =
      Enum.reduce(replacements, ipa, fn {from, to}, result -> String.replace(result, from, to) end)

    ipa = Regex.replace(~r/(\S)\x{0329}/u, ipa, "ᵊ\\1")

    ipa =
      if language == "en-us" do
        ipa
        |> String.replace("oʊ", "O")
        |> String.replace("ɜːɹ", "ɜɹ")
        |> String.replace("ɜː", "ɜɹ")
        |> String.replace("ː", "")
      else
        ipa |> String.replace("əʊ", "Q") |> String.replace("eə", "ɛː")
      end

    ipa |> String.replace(~r/\s+/u, " ") |> String.trim()
  end
end
