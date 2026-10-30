if System.get_env("AUDIOFLOW_ML") == "1" do
  defmodule AudioFlow.KokoroTest do
    use ExUnit.Case, async: true

    test "phoneme encoding adds boundaries and preserves every symbol across long sections" do
      vocabulary = %{"h" => 50, "ə" => 83, "l" => 54, "ˈ" => 156, "O" => 31, "." => 4, " " => 16}
      assert [[0, 50, 83, 54, 156, 31, 4, 0]] = AudioFlow.Kokoro.encode("həlˈO.", vocabulary)
      phonemes = String.duplicate("h ", 260) <> "O"
      [first, second] = AudioFlow.Kokoro.encode(phonemes, vocabulary)
      expected_first = [0] ++ List.flatten(List.duplicate([50, 16], 255)) ++ [0]
      assert first == expected_first
      assert second == [0, 50, 16, 50, 16, 50, 16, 50, 16, 50, 16, 31, 0]
    end

    test "unknown and empty phonemes fail instead of losing speech" do
      assert_raise ArgumentError, ~r/unsupported phoneme/, fn ->
        AudioFlow.Kokoro.encode("h☃", %{"h" => 50})
      end

      assert_raise ArgumentError, ~r/empty/, fn -> AudioFlow.Kokoro.encode(" ", %{" " => 16}) end
    end
  end
end
