defmodule AudioFlow.TelemetryTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Audio, Graph, Text}
  alias AudioFlow.Adapters.Demo

  @events [
    [:audio_flow, :session, :start],
    [:audio_flow, :session, :stop],
    [:audio_flow, :turn, :start],
    [:audio_flow, :turn, :stop],
    [:audio_flow, :stage, :start],
    [:audio_flow, :stage, :stop],
    [:audio_flow, :stage, :exception]
  ]

  setup do
    ref = :telemetry_test.attach_event_handlers(self(), @events)
    on_exit(fn -> :telemetry.detach(ref) end)
    %{ref: ref}
  end

  defp audio, do: %Audio{data: <<0, 0>>, sample_rate: 16_000}
  defp function(fun), do: {AudioFlow.Adapters.Function, [run: fun]}

  defp start(options) do
    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  defp stages(ref, session, turn) do
    receive do
      {[:audio_flow, :stage, phase], ^ref, _, %{session: ^session, turn: ^turn} = meta} ->
        [{phase, meta.stage} | stages(ref, session, turn)]
    after
      100 -> []
    end
  end

  test "a session and its turn emit spans with stage spans for each adapter", %{ref: ref} do
    session = start(Demo.options())
    owner = self()

    assert_receive {[:audio_flow, :session, :start], ^ref, %{system_time: _},
                    %{session: ^session, owner: ^owner, graph?: false}}

    {:ok, turn} = AudioFlow.submit(session, audio())

    assert_receive {[:audio_flow, :turn, :start], ^ref, %{monotonic_time: _},
                    %{
                      session: ^session,
                      turn: ^turn,
                      input: :audio,
                      telemetry_span_context: ^turn
                    }}

    assert_receive {AudioFlow, ^session, ^turn, {:done, metrics}}

    assert_receive {[:audio_flow, :turn, :stop], ^ref, %{duration: duration, events: 3},
                    %{session: ^session, turn: ^turn, status: :done, error: nil} = meta}

    assert duration > 0
    assert meta.metrics == metrics

    assert stages(ref, session, turn) == [
             start: :stt,
             stop: :stt,
             start: :llm,
             start: :tts,
             stop: :tts,
             stop: :llm
           ]

    AudioFlow.stop_session(session)

    assert_receive {[:audio_flow, :session, :stop], ^ref, %{duration: _, turns: 1},
                    %{session: ^session, reason: :shutdown}}
  end

  test "an adapter error emits a stage exception and an error turn", %{ref: ref} do
    session = start(Keyword.put(Demo.options(), :llm, function(fn _, _ -> {:error, :down} end)))
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "hi"})
    assert_receive {AudioFlow, ^session, ^turn, {:error, reason, _}}

    assert_receive {[:audio_flow, :stage, :exception], ^ref, %{duration: _},
                    %{session: ^session, turn: ^turn, stage: :llm, kind: :throw}}

    assert_receive {[:audio_flow, :turn, :stop], ^ref, _,
                    %{turn: ^turn, input: :text, status: :error, error: ^reason}}
  end

  test "a cancelled turn stops with the cancelled status", %{ref: ref} do
    test = self()

    llm =
      function(fn _, _ ->
        send(test, :running)
        Process.sleep(:infinity)
      end)

    session = start(Keyword.put(Demo.options(), :llm, llm))
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "hi"})
    assert_receive :running
    :ok = AudioFlow.cancel(session)

    assert_receive {[:audio_flow, :turn, :stop], ^ref, _,
                    %{turn: ^turn, status: :cancelled, error: nil}}

    refute_received {[:audio_flow, :stage, :stop], ^ref, _, %{turn: ^turn}}
  end

  test "a session that stops during a turn closes the turn", %{ref: ref} do
    test = self()

    llm =
      function(fn _, _ ->
        send(test, :running)
        Process.sleep(:infinity)
      end)

    session = start(Keyword.put(Demo.options(), :llm, llm))
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "hi"})
    assert_receive :running
    AudioFlow.stop_session(session)

    assert_receive {[:audio_flow, :turn, :stop], ^ref, _,
                    %{turn: ^turn, status: :error, error: {:session_stop, :shutdown}}}
  end

  test "graph stages carry the node type and id", %{ref: ref} do
    graph = %{
      "nodes" => [
        %{"id" => "mic", "type" => "input.audio"},
        %{"id" => "stt", "type" => "demo.stt"},
        %{"id" => "llm", "type" => "demo.llm"},
        %{"id" => "tts", "type" => "demo.tts"}
      ],
      "edges" => [
        %{"from" => "mic", "to" => "stt"},
        %{"from" => "stt", "to" => "llm"},
        %{"from" => "llm", "to" => "tts"}
      ]
    }

    {:ok, options} = Graph.session_options(graph, Graph.catalog())
    session = start(options)

    assert_receive {[:audio_flow, :session, :start], ^ref, _, %{session: ^session, graph?: true}}

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}

    assert_receive {[:audio_flow, :stage, :stop], ^ref, _,
                    %{turn: ^turn, stage: "demo.llm", node: "llm", adapter: _}}
  end
end
