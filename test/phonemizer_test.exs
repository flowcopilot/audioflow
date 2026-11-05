defmodule AudioFlow.PhonemizerTest do
  use ExUnit.Case, async: true

  alias AudioFlow.Phonemizers.ESpeak

  @tag :model
  test "English espeak output preserves pauses and uses Kokoro diphthong symbols" do
    assert {:ok, "həlˈO, mI dˈɑɡ ɪz kjˈut."} =
             ESpeak.phonemize("Hello, my dog is cute.")

    assert {:ok, "ʧˈAnʤ ðə vˈYs!"} = ESpeak.phonemize("Change the voice!")
  end

  test "unsupported language and oversized text return a conversion error" do
    assert {:error, :unsupported_language} =
             ESpeak.phonemize("Hello", language: "xx")

    assert {:error, :text_too_large} =
             ESpeak.phonemize(String.duplicate("a", 16_385),
               executable: "/unused"
             )
  end
end
