# No native model dependencies. Start a compatible server or use a cloud URL.
# AUDIOFLOW_CHAT_ENDPOINT and AUDIOFLOW_LLM are required. The API key is optional.
options = [
  endpoint: System.fetch_env!("AUDIOFLOW_CHAT_ENDPOINT"),
  model: System.fetch_env!("AUDIOFLOW_LLM"),
  parameters: %{temperature: 0, max_tokens: 64}
]

options =
  if System.get_env("AUDIOFLOW_CHAT_API_KEY"),
    do: Keyword.put(options, :api_key, fn -> System.fetch_env!("AUDIOFLOW_CHAT_API_KEY") end),
    else: options

input = System.argv() |> Enum.join(" ")
if input == "", do: raise("Supply a message as the command argument")

case AudioFlow.Adapters.ChatHTTP.run(input, options, fn text ->
       IO.write(text)
       :ok
     end) do
  :ok -> IO.puts("")
  {:error, reason} -> raise "Chat failed: #{inspect(reason)}"
end
