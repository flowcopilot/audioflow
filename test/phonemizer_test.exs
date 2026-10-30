defmodule AudioFlow.PhonemizerTest do
  use ExUnit.Case, async: true

  @tag :model
  test "English espeak output preserves pauses and uses Kokoro diphthong symbols" do
    assert {:ok, "həlˈO, mI dˈɑɡ ɪz kjˈut."} =
             AudioFlow.Phonemizers.ESpeak.phonemize("Hello, my dog is cute.")

    assert {:ok, "ʧˈAnʤ ðə vˈYs!"} = AudioFlow.Phonemizers.ESpeak.phonemize("Change the voice!")
  end

  test "unsupported language and oversized text return a conversion error" do
    assert {:error, :unsupported_language} =
             AudioFlow.Phonemizers.ESpeak.phonemize("Hello", language: "xx")

    assert {:error, :text_too_large} =
             AudioFlow.Phonemizers.ESpeak.phonemize(String.duplicate("a", 16385),
               executable: "/unused"
             )
  end
end
