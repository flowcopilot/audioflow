defmodule AudioFlow.TextChunksTest do
  use ExUnit.Case, async: true

  test "streamed sentences retain spaces and a final fragment" do
    chunks = ["Hello", " world.", " Next", " sentence! ", "Tail"]

    assert Enum.to_list(AudioFlow.TextChunks.sentences(chunks)) == [
             "Hello world. ",
             "Next sentence! ",
             "Tail"
           ]
  end

  test "titles and initials stay with names across token boundaries" do
    chunks = ["Mr.", " Quil", "ter and Dr. ", "J.", " Smith arrived.", " Welcome!"]

    assert Enum.to_list(AudioFlow.TextChunks.sentences(chunks)) == [
             "Mr. Quilter and Dr. J. Smith arrived. ",
             "Welcome!"
           ]
  end

  test "Unicode and closing quotes preserve the original text" do
    chunks = ["She said “café!", "”\n", "Then left", "."]

    assert Enum.to_list(AudioFlow.TextChunks.sentences(chunks)) == [
             "She said “café!”\n",
             "Then left."
           ]
  end

  test "CJK terminators end a sentence without whitespace" do
    chunks = ["你好。", "今天天气", "很好！你", "吃饭了吗？", "再见"]

    assert Enum.to_list(AudioFlow.TextChunks.sentences(chunks)) == [
             "你好。",
             "今天天气很好！",
             "你吃饭了吗？",
             "再见"
           ]
  end

  test "a CJK closing quote stays with its sentence when it arrives in the same chunk" do
    assert {["他说：「好。」"], "下"} = AudioFlow.TextChunks.push("", "他说：「好。」下")
  end

  test "the sentences do not depend on how the stream is split into chunks" do
    text =
      "Dr. J. Smith said: \"Yes!\" Then he left. Next, e.g. this one? 完了。好的！Tail (end.) " <>
        "More"

    whole = Enum.to_list(AudioFlow.TextChunks.sentences([text]))
    chars = text |> String.graphemes() |> AudioFlow.TextChunks.sentences() |> Enum.to_list()
    sevens = text |> String.graphemes() |> Enum.chunk_every(7) |> Enum.map(&Enum.join/1)

    assert chars == whole
    assert Enum.join(whole) == text
    assert Enum.to_list(AudioFlow.TextChunks.sentences(sevens)) == whole
  end

  test "a long buffer without a boundary splits at clause marks, whitespace, then characters" do
    opts = [max_bytes: 20]

    assert {["aaaa, bbbb, cccc, "], "dddd"} =
             AudioFlow.TextChunks.push("", "aaaa, bbbb, cccc, dddd", opts)

    assert {["word word word "], "word word"} =
             AudioFlow.TextChunks.push("", "word word word word word", max_bytes: 18)

    {pieces, rest} = AudioFlow.TextChunks.push("", String.duplicate("语", 30), opts)
    assert Enum.all?(pieces, &(byte_size(&1) <= 20 and String.valid?(&1)))
    assert Enum.join(pieces) <> rest == String.duplicate("语", 30)
  end
end
