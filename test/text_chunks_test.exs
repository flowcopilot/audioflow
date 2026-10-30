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
end
