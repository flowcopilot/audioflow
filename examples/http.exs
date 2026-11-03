# No native model dependencies. Start a compatible server or use a cloud URL.
# AUDIOFLOW_CHAT_ENDPOINT and AUDIOFLOW_LLM are required. The API key is optional.
options = [
  base_url:
    System.fetch_env!("AUDIOFLOW_CHAT_ENDPOINT") |> String.replace_suffix("/chat/completions", ""),
  model: %{provider: :openai, id: System.fetch_env!("AUDIOFLOW_LLM")},
  temperature: 0.0,
  max_tokens: 64,
  system_prompt: AudioFlow.Prompt.default_system(),
  api_key: System.get_env("AUDIOFLOW_CHAT_API_KEY") || "local"
]

input = System.argv() |> Enum.join(" ")
if input == "", do: raise("Supply a message as the command argument")

case AudioFlow.Adapters.ReqLLM.run(input, options, fn text ->
       IO.write(text)
       :ok
     end) do
  :ok -> IO.puts("")
  {:error, reason} -> raise "Chat failed: #{inspect(reason)}"
end
