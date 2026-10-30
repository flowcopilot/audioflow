defmodule AudioFlow.PromptTest do
  use ExUnit.Case, async: true

  test "Qwen3 prompt matches the original template with thinking disabled" do
    reference = File.read!(Path.join(__DIR__, "fixtures/qwen3_prompt.json")) |> JSON.decode!()
    assert AudioFlow.Prompt.qwen3(reference["text"]) == reference["prompt"]

    assert AudioFlow.Prompt.qwen3(reference["text"], system: reference["system"]) ==
             reference["prompt"]

    for conversation <- reference["conversations"] do
      messages =
        Enum.map(conversation["messages"], fn message ->
          %{role: message["role"], content: message["content"]}
        end)

      assert AudioFlow.Prompt.qwen3(messages) == conversation["prompt"]
    end
  end
end
