defmodule AudioFlow.ConversationTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Graph.Handoff

  defmodule Nodes do
    @behaviour AudioFlow.Graph.Node
    def nodes do
      [
        %{
          type: "test.agent",
          title: "test",
          description: "",
          input: :text,
          output: :text,
          history: true,
          options: [%{name: :name, type: :string, required: true}]
        }
      ]
    end

    def adapter(_, %{name: name}) do
      owner = self()

      {AudioFlow.Adapters.Function,
       run: fn messages, emit ->
         case List.last(messages).content do
           "wait" ->
             send(owner, {:waiting, self()})

             receive do
               :resume -> :ok
               :fail -> throw(:test_failure)
             end

           _ ->
             :ok
         end

         emit.("#{name}:#{length(messages)}")
       end}
    end
  end

  defp graph(name) do
    %{
      nodes: [
        %{id: "in", type: "input.text"},
        %{id: "agent", type: "test.agent", options: %{name: name}}
      ],
      edges: [%{from: "in", to: "agent"}],
      settings: %{history: true}
    }
  end

  defp flow do
    Conversation.new(
      %{"triage" => graph("triage"), "billing" => graph("billing")},
      "triage",
      %{
        {"triage", {:intent, "billing"}} => "billing",
        {"billing", {:tool_result, "resolved", :ok}} => "triage"
      },
      AudioFlow.Graph.catalog([AudioFlow.Graph.Nodes.Input, Nodes])
    )
  end

  defp start do
    {:ok, session} = Conversation.start_session(flow())
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  defp turn(session, input, expected) do
    {:ok, ref} = AudioFlow.submit(session, %AudioFlow.Text{data: input})
    assert_receive {AudioFlow, ^session, ^ref, {:text, ^expected, "agent"}}
    assert_receive {AudioFlow, ^session, ^ref, {:done, _}}
  end

  test "intent and tool-result handoffs preserve session and ordered history, including a state cycle" do
    session = start()
    turn(session, "hello", "triage:1")
    assert :ok = Conversation.event(session, {:intent, "billing"})
    assert {:ok, "billing"} = Conversation.state(session)
    turn(session, "invoice", "billing:3")
    tool = Conversation.tool(session, "resolved", {:tool_result, "resolved", :ok})
    assert AudioFlow.Tool.call(tool, %{}) =~ "handoff"
    turn(session, "thanks", "triage:5")
    assert {:error, :invalid_transition} = Conversation.event(session, :unknown)
  end

  test "a staged handoff is discarded when its turn is cancelled" do
    session = start()
    {:ok, ref} = AudioFlow.submit(session, %AudioFlow.Text{data: "wait"})
    assert :ok = Conversation.event(session, {:intent, "billing"})
    assert {:ok, "triage"} = Conversation.state(session)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^ref, {:cancelled, _}}
    assert {:ok, "triage"} = Conversation.state(session)
    turn(session, "again", "triage:1")
  end

  test "each state retains DAG validation" do
    graph =
      graph("bad") |> Map.put(:edges, [%{from: "in", to: "agent"}, %{from: "agent", to: "agent"}])

    assert_raise ArgumentError, ~r/cycle/, fn ->
      Conversation.new(
        %{"bad" => graph},
        "bad",
        %{},
        AudioFlow.Graph.catalog([AudioFlow.Graph.Nodes.Input, Nodes])
      )
    end
  end

  test "Jido handoff commits after success and rejects stale tools" do
    session = start()
    {:ok, ref} = AudioFlow.submit(session, %AudioFlow.Text{data: "wait"})

    assert {:ok, %{handoff: "billing"}} =
             Handoff.run(%{intent: "billing"}, %{session: session, turn: ref})

    assert {:ok, "triage"} = Conversation.state(session)
    assert_receive {:waiting, task}
    send(task, :resume)
    assert_receive {AudioFlow, ^session, ^ref, {:done, _}}
    assert {:ok, "billing"} = Conversation.state(session)

    assert {:error, :stale_turn} =
             Handoff.run(%{intent: "billing"}, %{session: session, turn: ref})

    turn(session, "next", "billing:3")
  end

  test "failed turns discard staged transitions and history" do
    session = start()
    {:ok, ref} = AudioFlow.submit(session, %AudioFlow.Text{data: "wait"})
    assert :ok = Conversation.event(session, {:intent, "billing"})
    assert_receive {:waiting, task}
    send(task, :fail)
    assert_receive {AudioFlow, ^session, ^ref, {:error, :test_failure, _}}
    assert {:ok, "triage"} = Conversation.state(session)
    turn(session, "again", "triage:1")
  end
end
