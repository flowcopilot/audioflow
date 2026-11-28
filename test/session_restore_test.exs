defmodule AudioFlow.SessionRestoreTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Text

  defp text_session(options) do
    test = self()

    options =
      Demo.options()
      |> Keyword.merge(
        history: true,
        on_commit: &send(test, {:commit, &1}),
        llm:
          {Function,
           run: fn messages, emit ->
             send(test, {:prompt, messages})
             emit.("reply #{length(messages)}")
           end}
      )
      |> Keyword.merge(options)

    {:ok, session} = AudioFlow.start_session(options)
    session
  end

  defp turn(session, text) do
    {:ok, ref} = AudioFlow.submit(session, %Text{data: text})
    assert_receive {:prompt, messages}
    assert_receive {AudioFlow, ^session, ^ref, {:done, _}}
    messages
  end

  test "each committed turn reports a snapshot, and a restored session sends the same prompt" do
    first = text_session([])
    turn(first, "one")
    assert_receive {:commit, %{history: [{"one", "reply 1"}], turns: 1, conversation_state: nil}}
    turn(first, "two")
    assert_receive {:commit, snapshot}
    assert snapshot.history == [{"one", "reply 1"}, {"two", "reply 3"}]
    expected = turn(first, "three")

    restored = text_session(restore: snapshot, on_commit: nil)
    assert turn(restored, "three") == expected
  end

  def report(test, snapshot), do: send(test, {:reported, snapshot})

  test "on_commit also takes a pid with a tag, or a module, function and arguments" do
    pid_session = text_session(on_commit: {self(), :tagged})
    turn(pid_session, "one")
    assert_receive {:tagged, %{history: [{"one", "reply 1"}], turns: 1}}

    mfa_session = text_session(on_commit: {__MODULE__, :report, [self()]})
    turn(mfa_session, "one")
    assert_receive {:reported, %{history: [{"one", "reply 1"}], turns: 1}}
  end

  test "a throw or an exit in on_commit is logged with a stacktrace and ignored" do
    for callback <- [fn _ -> throw(:store_down) end, fn _ -> exit(:store_down) end] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          session = text_session(on_commit: callback)
          assert [%{content: "one"}] = turn(session, "one")
          # The commit runs after the done event; wait for the session to finish it.
          :sys.get_state(session)
        end)

      assert log =~ "Session on_commit failed"
      assert log =~ "store_down"
      assert log =~ "session_restore_test.exs"
    end
  end

  test "a cleared history is reported; a failed turn and a failing callback are not" do
    session = text_session(on_commit: fn _ -> raise "store down" end)
    turn(session, "one")
    assert :ok = AudioFlow.clear_history(session)
    assert [%{role: :user, content: "two"}] = turn(session, "two")

    reporter = text_session([])
    turn(reporter, "one")
    assert_receive {:commit, %{history: [_]}}
    :ok = AudioFlow.clear_history(reporter)
    assert_receive {:commit, %{history: []}}
  end

  test "restored history needs history enabled and valid turns" do
    assert {:error, {%ArgumentError{}, _}} =
             AudioFlow.start_session(
               Keyword.merge(Demo.options(), owner: self(), restore: %{history: [{"a", "b"}]})
             )

    assert {:error, {%ArgumentError{}, _}} =
             AudioFlow.start_session(
               Keyword.merge(Demo.options(),
                 owner: self(),
                 history: true,
                 restore: %{history: [{"a", 1}]}
               )
             )
  end

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

    def adapter(_, %{name: name}),
      do: {Function, run: fn messages, emit -> emit.("#{name}:#{length(messages)}") end}
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
      %{{"triage", {:intent, "billing"}} => "billing"},
      AudioFlow.Graph.catalog([AudioFlow.Graph.Nodes.Input, Nodes])
    )
  end

  defp graph_turn(session, input, expected) do
    {:ok, ref} = AudioFlow.submit(session, %Text{data: input})
    assert_receive {AudioFlow, ^session, ^ref, {:text, ^expected, "agent"}}
    assert_receive {AudioFlow, ^session, ^ref, {:done, _}}
  end

  test "the conversation state is saved on a transition and restored" do
    test = self()
    {:ok, first} = Conversation.start_session(flow(), on_commit: &send(test, {:commit, &1}))
    graph_turn(first, "hello", "triage:1")
    assert_receive {:commit, %{conversation_state: "triage", history: [_]}}
    assert :ok = Conversation.event(first, {:intent, "billing"})
    assert_receive {:commit, %{conversation_state: "billing"}}
    graph_turn(first, "invoice", "billing:3")
    assert_receive {:commit, snapshot}

    {:ok, restored} = Conversation.start_session(flow(), restore: snapshot)
    assert {:ok, "billing"} = Conversation.state(restored)
    graph_turn(restored, "thanks", "billing:5")

    assert {:error, {%ArgumentError{}, _}} =
             Conversation.start_session(flow(), restore: %{snapshot | conversation_state: "gone"})
  end
end
