# Run with your real chat-completions endpoint:
# CHAT_ENDPOINT=http://localhost:8080/v1/chat/completions CHAT_MODEL=qwen3 \
#   mix run examples/conversation_handoff.exs
# Optional: CHAT_API_KEY. No model responses are simulated here.
alias AudioFlow.Graph.Conversation

endpoint = System.fetch_env!("CHAT_ENDPOINT")
model = System.fetch_env!("CHAT_MODEL")

Application.put_env(:audio_flow, :chat_tool_profiles, %{
  "triage" => [AudioFlow.Graph.Handoff],
  "billing" => []
})

graph = fn system, profile ->
  %{
    nodes: [
      %{id: "keyboard", type: "input.text"},
      %{
        id: "agent",
        type: "llm.chat_http",
        options: %{
          endpoint: endpoint,
          model: model,
          system: system,
          api_key_env: "CHAT_API_KEY",
          tools_profile: profile
        }
      }
    ],
    edges: [%{from: "keyboard", to: "agent"}],
    settings: %{history: true}
  }
end

flow =
  Conversation.new(
    %{
      "triage" =>
        graph.(
          "Help the user. For billing questions call handoff with intent billing. Finish with a brief transfer message.",
          "triage"
        ),
      "billing" =>
        graph.(
          "You are the billing assistant. Use the conversation context to help. Never claim access to an account or payment system.",
          "billing"
        )
    },
    "triage",
    %{
      {"triage", {:intent, "billing"}} => "billing",
      {"billing", {:tool_result, "resolved", :ok}} => "triage"
    }
  )

{:ok, session} = Conversation.start_session(flow)

await = fn await, turn ->
  receive do
    {AudioFlow, ^session, ^turn, {:text, text, _}} ->
      IO.write(text)
      await.(await, turn)

    {AudioFlow, ^session, ^turn, {:done, _}} ->
      IO.puts("")
      :ok

    {AudioFlow, ^session, ^turn, {:error, reason, _}} ->
      IO.inspect(reason, label: "Turn failed")
  end
end

try do
  Stream.repeatedly(fn -> IO.gets("You (/resolved to return to triage, EOF to quit): ") end)
  |> Enum.reduce_while(:ok, fn
    :eof, _ ->
      {:halt, :ok}

    {:error, reason}, _ ->
      {:halt, {:error, reason}}

    line, _ ->
      if String.trim(line) == "/resolved" do
        IO.inspect(Conversation.event(session, {:tool_result, "resolved", :ok}))
      else
        case AudioFlow.submit(session, %AudioFlow.Text{data: line}) do
          {:ok, turn} -> await.(await, turn)
          error -> IO.inspect(error)
        end
      end

      IO.inspect(Conversation.state(session), label: "Same session, current state")
      {:cont, :ok}
  end)
after
  AudioFlow.stop_session(session)
end
