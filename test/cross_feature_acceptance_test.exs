defmodule AudioFlow.CrossFeatureAcceptanceTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Adapters.Function
  alias AudioFlow.Audio
  alias AudioFlow.Graph
  alias AudioFlow.Graph.Conversation
  alias AudioFlow.Output
  alias AudioFlow.Privacy
  alias AudioFlow.Recording
  alias AudioFlow.Recording.Store
  alias AudioFlow.Test.HTTPFixture, as: HTTP
  alias AudioFlow.Text
  alias AudioFlow.VoiceInput

  setup do
    root =
      Path.join(System.tmp_dir!(), "audioflow-acceptance-#{System.unique_integer([:positive])}")

    {:ok, store} = Store.new(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{store: store, root: root}
  end

  defp recorder(session, store) do
    Recording.new(session, store, redactor: Privacy.rules([{~r/alice@example\.com/, "[EMAIL]"}]))
  end

  defp collect(recorder, session, turn) do
    receive do
      {AudioFlow, ^session, ^turn, _} = message ->
        case Recording.consume(recorder, message) do
          {:ok, next, nil} -> collect(next, session, turn)
          {:ok, next, id} -> {next, id}
          other -> flunk("recording failed: #{inspect(other)}")
        end
    after
      3000 -> flunk("turn did not terminate")
    end
  end

  defp track(session) do
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  test "real HTTP tool rounds and multi-turn history produce redacted artifacts", ctx do
    owner = self()

    {child, listener, endpoint} =
      HTTP.start(owner, fn socket, request ->
        HTTP.headers(socket)

        if Enum.any?(request.body["messages"], &(&1["role"] == "tool")) do
          HTTP.chunk(
            socket,
            HTTP.event("alice@") <> HTTP.event("example.com", "stop") <> HTTP.done()
          )
        else
          delta = %{
            tool_calls: [
              %{
                index: 0,
                id: "lookup",
                type: "function",
                function: %{name: "lookup", arguments: "{}"}
              }
            ]
          }

          HTTP.chunk(
            socket,
            "data: " <>
              JSON.encode!(%{choices: [%{index: 0, delta: delta, finish_reason: "tool_calls"}]}) <>
              "\n\n" <> HTTP.done()
          )
        end

        HTTP.finish(socket)
      end)

    start_supervised!(child)
    on_exit(fn -> :gen_tcp.close(listener) end)

    tool = %{
      name: "lookup",
      run: fn _ ->
        send(owner, :tool_called)
        {:ok, "alice@example.com"}
      end
    }

    options =
      Demo.options()
      |> Keyword.put(:history, true)
      |> Keyword.put(
        :llm,
        {AudioFlow.Adapters.ChatHTTP,
         endpoint: endpoint, model: "protocol-fixture", tools: [tool]}
      )

    {:ok, session} = AudioFlow.start_session(options)
    track(session)

    for question <- ["first", "second"], reduce: recorder(session, ctx.store) do
      recording ->
        {:ok, turn} = AudioFlow.submit(session, %Text{data: question})
        {recording, id} = collect(recording, session, turn)
        assert_receive :tool_called
        assert_receive {:http_request, _, initial}
        assert_receive {:http_request, _, followup}
        messages = initial.body["messages"]

        if question == "second" do
          assert Enum.any?(
                   messages,
                   &(&1["role"] == "assistant" and &1["content"] == "alice@example.com")
                 )
        end

        assert Enum.any?(
                 followup.body["messages"],
                 &(&1["role"] == "tool" and &1["content"] == "alice@example.com")
               )

        {:ok, artifact} = Store.read(ctx.store, id)
        assert artifact["status"] == "done"
        assert Enum.any?(artifact["streams"], &(&1["text"] == "[EMAIL]"))
        refute File.read!(Path.join(ctx.root, id)) =~ "alice"
        refute Enum.any?(artifact["events"], &(&1["kind"] == "audio"))
        recording
    end

    assert {:ok, ids} = Store.list(ctx.store)
    assert [_, _] = ids
  end

  test "recording retains generated text while cancellation retains only heard history and rolls back handoff",
       ctx do
    owner = self()

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

    plan =
      put_in(
        plan.steps["llm"].adapter,
        {Function,
         run: fn messages, emit ->
           send(owner, {:prompt, messages})
           emit.("Heard. ")
           emit.("alice@example.com.")
           send(owner, {:waiting, self()})
           receive do: (:finish -> :ok)
         end}
      )

    plan =
      put_in(
        plan.steps["tts"].adapter,
        {Function,
         run: fn _, emit ->
           emit.(%Audio{data: <<0, 0, 0, 0>>, sample_rate: 16_000})
         end}
      )

    flow = %Conversation{
      states: %{a: plan, b: plan},
      current: :a,
      transitions: %{{:a, :handoff} => :b}
    }

    {:ok, session} = Conversation.start_session(flow)
    track(session)
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:waiting, _}
    assert :ok = Conversation.event(session, :handoff)
    assert :ok = Output.acknowledge(session, turn, 125_000)
    assert :ok = AudioFlow.cancel(session)
    {recording, id} = collect(recorder(session, ctx.store), session, turn)
    {:ok, artifact} = Store.read(ctx.store, id)
    assert artifact["status"] == "cancelled"
    assert Enum.any?(artifact["streams"], &(&1["text"] == "Heard. [EMAIL]."))
    assert {:ok, :a} = Conversation.state(session)
    assert {:error, :stale_turn} = Output.acknowledge(session, turn, 250_000)
    assert_receive {:prompt, [%{content: "first"}]}
    {:ok, next} = AudioFlow.submit(session, %Text{data: "next"})
    assert_receive {:prompt, [%{content: "first"}, %{content: "Heard. "}, %{content: "next"}]}
    assert_receive {:waiting, worker}
    assert :ok = Conversation.event(session, :handoff)
    send(worker, :finish)
    {_, next_id} = collect(recording, session, next)
    assert {:ok, %{"status" => "done"}} = Store.read(ctx.store, next_id)
    assert {:ok, :b} = Conversation.state(session)
  end

  defmodule SubtractReference do
    def init(_, _, _), do: nil

    def process(audio, reference, state) do
      samples = for <<x::little-signed-16 <- audio.data>>, do: x
      refs = for <<x::little-signed-16 <- reference.data>>, do: x
      pcm = Enum.zip_with(samples, refs, fn x, y -> <<x - y::little-signed-16>> end)
      {%{audio | data: IO.iodata_to_binary(pcm)}, state}
    end
  end

  defmodule SemanticFixture do
    def init(owner), do: owner

    def predict(audio, owner) do
      send(owner, {:semantic_input, audio})
      0.9
    end
  end

  test "aligned DSP fixture feeds semantic ingress and the processed utterance reaches recorded Session STT",
       ctx do
    frame = fn x -> :binary.copy(<<x::little-signed-16>>, 512) end
    pcm = frame.(32_000) <> frame.(32_000) <> frame.(0)
    reference = frame.(32_000) <> frame.(0) <> frame.(0)
    audio = fn bytes -> %Audio{data: bytes, sample_rate: 16_000} end

    input =
      VoiceInput.new({AudioFlow.Test.FrameDetector, []},
        min_speech_ms: 32,
        min_silence_ms: 32,
        pre_roll_ms: 0,
        preprocessor: {SubtractReference, []},
        turn_detector: {SemanticFixture, self()}
      )

    <<head::binary-size(300), tail::binary>> = pcm
    <<ref_head::binary-size(300), ref_tail::binary>> = reference
    assert {[], input} = VoiceInput.push(input, audio.(head), audio.(ref_head))

    assert {[:speech_started, {:utterance, utterance, :semantic}], _} =
             VoiceInput.push(input, audio.(tail), audio.(ref_tail))

    assert utterance.data == frame.(32_000) <> frame.(0)
    assert_receive {:semantic_input, ^utterance}
    owner = self()

    options =
      Demo.options()
      |> Keyword.put(
        :stt,
        {Function,
         run: fn actual, emit ->
           send(owner, {:stt_input, actual})
           emit.("alice@example.com")
         end}
      )

    {:ok, session} = AudioFlow.start_session(options)
    track(session)
    {:ok, turn} = AudioFlow.submit(session, utterance)
    {_, id} = collect(recorder(session, ctx.store), session, turn)
    assert_receive {:stt_input, ^utterance}
    {:ok, artifact} = Store.read(ctx.store, id)

    assert Enum.any?(
             artifact["streams"],
             &(&1["kind"] == "transcript" and &1["text"] == "[EMAIL]")
           )

    refute File.read!(Path.join(ctx.root, id)) =~ "alice"
  end
end
