defmodule AudioFlow.Prompt do
  @moduledoc "Explicit prompt formats for conversational language models."

  @system "You are a voice assistant. Reply in one short sentence. Use plain text."
  def default_system, do: @system

  @doc "Qwen3 ChatML for one string or a user/assistant message list ending with a user message."
  def qwen3(input, options \\ [])

  def qwen3(text, options) when is_binary(text),
    do: qwen3([%{role: :user, content: text}], options)

  def qwen3(messages, options) when is_list(messages) and messages != [] do
    system =
      Keyword.get(
        options,
        :system,
        default_system()
      )

    if List.last(messages).role not in [:user, "user"],
      do: raise(ArgumentError, "Qwen3 messages must end with a user message")

    rendered =
      Enum.map_join(messages, "", fn %{role: role, content: content}
                                     when role in [:user, :assistant, "user", "assistant"] and
                                            is_binary(content) ->
        content =
          if role in [:assistant, "assistant"] and String.contains?(content, "</think>"),
            do: content |> String.split("</think>") |> List.last() |> String.trim_leading("\n"),
            else: content

        "<|im_start|>#{role}\n#{content}<|im_end|>\n"
      end)

    "<|im_start|>system\n#{system}<|im_end|>\n" <>
      rendered <>
      "<|im_start|>assistant\n<think>\n\n</think>\n\n"
  end
end
