defmodule AudioFlow.GraphCheckpointTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio
  alias AudioFlow.Graph
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Output
  alias AudioFlow.Text

  defp plan(mode) do
    graph = %{
      nodes: [
        %{id: "in", type: "input.text"},
        %{id: "llm", type: "demo.llm"},
        %{id: "tts", type: "demo.tts"}
      ],
      edges: [%{from: "in", to: "llm"}, %{from: "llm", to: "tts"}],
      settings: %{history: true}
    }

    {:ok, options} = Graph.session_options(graph, Graph.catalog())
    plan = options[:graph]
    owner = self()

    plan =
      put_in(
        plan.steps["llm"].adapter,
        {Function,
         run: fn messages, emit ->
           send(owner, {:prompt, messages})
           emit.("Héard. ")
           emit.("Unheard.")
           send(owner, {:waiting, self()})

           receive do
             :finish -> :ok
             :fail -> {:error, :failed}
           end
         end}
      )

    plan =
      put_in(
        plan.steps["tts"].adapter,
        {Function,
         run: fn text, emit ->
           if mode != :silent or text != "Héard. ",
             do: emit.(%Audio{data: <<0, 0, 0, 0>>, sample_rate: 16_000})

           if mode == :partial do
             send(owner, {:synth_wait, self()})

             receive do
               :finish -> :ok
             end
           end

           :ok
         end}
      )

    case mode do
      :branch ->
        other = %{plan.steps["tts"] | id: "other"}
        plan = put_in(plan.steps["other"], other)
        put_in(plan.steps["llm"].targets, ["tts", "other"])

      :join ->
        put_in(plan.steps["tts"].input_mode, :join)

      _ ->
        plan
    end
  end

  defp start(mode) do
    plan = plan(mode)

    flow = %Conversation{
      states: %{a: plan, b: plan},
      current: :a,
      transitions: %{{:a, :handoff} => :b}
    }

    {:ok, session} = Conversation.start_session(flow)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  test "aligned acknowledged graph chunks survive cancel while staged handoffs roll back" do
    session = start(:aligned)
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, _}
    assert :ok = Conversation.event(session, :handoff)
    assert :ok = Output.acknowledge(session, turn, 125_000)
    assert :ok = AudioFlow.cancel(session)
    assert {:ok, :a} = Conversation.state(session)
    {:ok, next} = AudioFlow.submit(session, %Text{data: "next"})
    assert_receive {:prompt, [%{content: "first"}, %{content: "Héard. "}, %{content: "next"}]}
    assert_receive {:waiting, worker}
    assert :ok = Conversation.event(session, :handoff)
    send(worker, :finish)
    assert_receive {AudioFlow, ^session, ^next, {:done, _}}
    assert {:ok, :b} = Conversation.state(session)
    assert :ok = Output.acknowledge(session, next, 125_000)
    assert :ok = AudioFlow.cancel(session)
    assert {:ok, :b} = Conversation.state(session)
    {:ok, _} = AudioFlow.submit(session, %Text{data: "third"})

    assert_receive {:prompt,
                    [
                      %{content: "first"},
                      %{content: "Héard. "},
                      %{content: "next"},
                      %{content: "Héard. "},
                      %{content: "third"}
                    ]}
  end

  test "branches, joins, missing speech and incomplete synthesis never invent alignment" do
    for mode <- [:branch, :join, :silent, :partial] do
      session = start(mode)
      {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
      assert_receive {:prompt, _}

      if mode == :partial,
        do: assert_receive({:synth_wait, _}),
        else: assert_receive({:waiting, _})

      emitted_ns =
        case mode do
          :branch -> 500_000
          :join -> 0
          _ -> 125_000
        end

      assert :ok = Output.acknowledge(session, turn, emitted_ns)
      assert :ok = AudioFlow.cancel(session)
      {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})
      assert_receive {:prompt, [%{content: "next"}]}

      if mode == :partial,
        do: assert_receive({:synth_wait, _}),
        else: assert_receive({:waiting, _})

      AudioFlow.stop_session(session)
    end
  end

  test "failed graph turns roll back both staged state and generated history after acknowledged output" do
    session = start(:aligned)
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, worker}
    assert :ok = Conversation.event(session, :handoff)
    assert :ok = Output.acknowledge(session, turn, 250_000)
    send(worker, :fail)
    assert_receive {AudioFlow, ^session, ^turn, {:error, _, _}}
    assert {:ok, :a} = Conversation.state(session)
    {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})
    assert_receive {:prompt, [%{content: "next"}]}
  end
end
