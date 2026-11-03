defmodule AudioFlow.ConversationEvaluationTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.ChatHTTP
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Evaluation.Conversation, as: Conversation
  alias AudioFlow.Test.HTTPFixture, as: HTTP

  defmodule Lookup do
    use Jido.Action, name: "lookup", schema: [city: [type: :string, required: true]]
    def run(%{city: city}, context), do: {:ok, %{forecast: "#{city}: #{context.forecast}"}}
  end

  defp start(llm, extra \\ []) do
    {:ok, session} =
      AudioFlow.start_session(Keyword.merge(Demo.options(), [llm: llm, history: true] ++ extra))

    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  test "two real HTTP tool turns assert replies, arguments, context, and carried history" do
    {tools, observer} = Conversation.observe_tools([Lookup])

    {child, listener, endpoint} =
      HTTP.start(self(), fn socket, request ->
        messages = request.body["messages"]
        last = List.last(messages)
        HTTP.headers(socket)

        if last["role"] == "tool" do
          HTTP.chunk(
            socket,
            HTTP.event(JSON.decode!(last["content"])["forecast"], "stop") <> HTTP.done()
          )
        else
          city = last["content"]

          call = %{
            id: "call",
            type: "function",
            function: %{name: "lookup", arguments: JSON.encode!(%{city: city})}
          }

          HTTP.chunk(
            socket,
            "data: " <>
              JSON.encode!(%{
                choices: [
                  %{
                    index: 0,
                    delta: %{tool_calls: [Map.put(call, :index, 0)]},
                    finish_reason: "tool_calls"
                  }
                ]
              }) <> "\n\n" <> HTTP.done()
          )
        end

        HTTP.finish(socket)
      end)

    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)

    session =
      start(
        {ChatHTTP,
         endpoint: endpoint, model: "fixture", tools: tools, tool_context: %{forecast: "sun"}}
      )

    [first, second] =
      Conversation.run!(
        session,
        [
          %{input: "Oslo", reply: "Oslo: sun", tools: [{"lookup", %{"city" => "Oslo"}}]},
          %{input: "Paris", reply: ~r/Paris: sun/, tools: [{"lookup", %{"city" => "Paris"}}]}
        ],
        observer: observer
      )

    assert first.turn != second.turn
    assert first.metrics != %{}
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, _}
    assert_receive {:http_request, _, third}

    assert Enum.any?(
             third.body["messages"],
             &(&1["role"] == "assistant" and &1["content"] == "Oslo: sun")
           )

    assert Enum.filter(third.body["messages"], &(&1["role"] == "user")) == [
             %{"role" => "user", "content" => "Oslo"},
             %{"role" => "user", "content" => "Paris"}
           ]
  end

  test "reply and tool mismatches fail with the step number; unrelated messages survive" do
    {_, observer} = Conversation.observe_tools([])
    session = start({Function, run: fn _, emit -> emit.("hello") end})
    send(self(), :unrelated)

    assert_raise ExUnit.AssertionError, ~r/step 1: reply/, fn ->
      Conversation.run!(session, [%{input: "hi", reply: "wrong"}])
    end

    assert_raise ExUnit.AssertionError, ~r/tool calls/, fn ->
      Conversation.run!(session, [%{input: "hi", tools: [{"missing", %{}}]}], observer: observer)
    end

    assert [%{reply: "hello"}] =
             Conversation.run!(
               session,
               [%{input: "hi", reply: &String.starts_with?(&1, "he"), tools: []}],
               observer: observer
             )

    assert_received :unrelated
    assert_raise ArgumentError, fn -> Conversation.run!(session, [%{input: "hi", tools: []}]) end
  end

  test "adapter failures and deadline expiry are failures, and expiry cancels the turn" do
    session = start({Function, run: fn _, _ -> {:error, :offline} end})

    assert_raise ExUnit.AssertionError, ~r/turn failed/, fn ->
      Conversation.run!(session, [%{input: "hi"}])
    end

    session = start({Function, run: fn _, _ -> Process.sleep(:infinity) end})

    assert_raise ExUnit.AssertionError, ~r/timed out/, fn ->
      Conversation.run!(session, [%{input: "hi"}], timeout_ms: 10)
    end

    assert_receive {AudioFlow, ^session, _, {:cancelled, _}}
    assert :ok = AudioFlow.clear_history(session)
  end

  test "graph replies can select a node and concatenate streamed text" do
    graph = %{
      "nodes" => [
        %{"id" => "in", "type" => "input.text"},
        %{"id" => "reply", "type" => "demo.llm"}
      ],
      "edges" => [%{"from" => "in", "to" => "reply"}]
    }

    {:ok, options} = AudioFlow.Graph.session_options(graph, AudioFlow.Graph.catalog())
    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> AudioFlow.stop_session(session) end)

    assert [%{reply: reply}] =
             Conversation.run!(session, [%{input: "hi", reply: &(byte_size(&1) > 0)}],
               node: "reply"
             )

    assert is_binary(reply)
  end
end
