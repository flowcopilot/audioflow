defmodule AudioFlow.ConversationHTTPTest do
  use ExUnit.Case, async: false
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  setup do
    name = "AUDIOFLOW_HANDOFF_TEST_KEY"
    previous = System.get_env(name)
    System.put_env(name, "local")

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  for adapter <- [:chat_http, :req_llm] do
    @adapter adapter
    test "#{adapter}: a Jido tool call swaps the actual HTTP prompt and tools while preserving history" do
      previous = Application.get_env(:audio_flow, :chat_tool_profiles)

      Application.put_env(:audio_flow, :chat_tool_profiles, %{
        "triage" => [AudioFlow.Graph.Handoff],
        "billing" => []
      })

      on_exit(fn ->
        if previous,
          do: Application.put_env(:audio_flow, :chat_tool_profiles, previous),
          else: Application.delete_env(:audio_flow, :chat_tool_profiles)
      end)

      {child, listener, endpoint} =
        HTTP.start(self(), fn socket, request ->
          messages = request.body["messages"]

          body =
            if hd(messages)["content"] == "Triage" and
                 not Enum.any?(messages, &(&1["role"] == "tool")) do
              "data: " <>
                JSON.encode!(%{
                  choices: [
                    %{
                      index: 0,
                      delta: %{
                        tool_calls: [
                          %{
                            index: 0,
                            id: "transfer",
                            type: "function",
                            function: %{
                              name: "handoff",
                              arguments: JSON.encode!(%{intent: "billing"})
                            }
                          }
                        ]
                      },
                      finish_reason: "tool_calls"
                    }
                  ]
                }) <> "\n\n" <> HTTP.done()
            else
              HTTP.event("Ready.", "stop") <> HTTP.done()
            end

          HTTP.headers(socket)
          HTTP.chunk(socket, body)
          HTTP.finish(socket)
        end)

      start_supervised!(child)
      on_exit(fn -> :gen_tcp.close(listener) end)

      graph = fn name, profile ->
        %{
          nodes: [
            %{id: "in", type: "input.text"},
            %{
              id: "llm",
              type: "llm.#{@adapter}",
              options:
                if @adapter == :req_llm do
                  %{
                    base_url: String.replace_suffix(endpoint, "/chat/completions", ""),
                    model: "openai:fixture",
                    api_key_env: "AUDIOFLOW_HANDOFF_TEST_KEY",
                    system_prompt: name,
                    tools_profile: profile
                  }
                else
                  %{endpoint: endpoint, model: "fixture", system: name, tools_profile: profile}
                end
            }
          ],
          edges: [%{from: "in", to: "llm"}],
          settings: %{history: true}
        }
      end

      flow =
        Conversation.new(
          %{"a" => graph.("Triage", "triage"), "b" => graph.("Billing", "billing")},
          "a",
          %{{"a", {:intent, "billing"}} => "b"}
        )

      {:ok, session} = Conversation.start_session(flow)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "invoice"})
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}, 10_000
      assert {:ok, "b"} = Conversation.state(session)
      assert_receive {:http_request, _, first}
      assert hd(first.body["messages"])["content"] == "Triage"
      assert [%{"function" => %{"name" => "handoff"}}] = first.body["tools"]
      assert_receive {:http_request, _, tool_result}
      assert List.last(tool_result.body["messages"])["content"] =~ "billing"
      {:ok, next} = AudioFlow.submit(session, %AudioFlow.Text{data: "follow up"})
      assert_receive {AudioFlow, ^session, ^next, {:done, _}}
      assert_receive {:http_request, _, final}
      refute Map.has_key?(final.body, "tools")

      assert Enum.map(final.body["messages"], & &1["content"]) == [
               "Billing",
               "invoice",
               "Ready.",
               "follow up"
             ]
    end
  end
end
