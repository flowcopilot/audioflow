defmodule AudioFlow.PromptTest do
  use ExUnit.Case, async: true

  test "Qwen3 prompt matches the original template with thinking disabled" do
    reference = File.read!(Path.join(__DIR__, "fixtures/qwen3_prompt.json")) |> JSON.decode!()
    assert AudioFlow.Prompt.qwen3(reference["text"]) == reference["prompt"]

    assert AudioFlow.Prompt.qwen3(reference["text"], system: reference["system"]) ==
             reference["prompt"]
  end
end
