defmodule AudioFlow.Prompt do
  @moduledoc "Explicit prompt formats for conversational language models."

  @doc "Qwen3 ChatML prompt with thinking disabled for spoken replies."
  def qwen3(text, options \\ []) when is_binary(text) do
    system =
      Keyword.get(
        options,
        :system,
        "You are a voice assistant. Reply in one short sentence. Use plain text."
      )

    "<|im_start|>system\n#{system}<|im_end|>\n" <>
      "<|im_start|>user\n#{text}<|im_end|>\n" <>
      "<|im_start|>assistant\n<think>\n\n</think>\n\n"
  end
end
