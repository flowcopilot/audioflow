defmodule AudioFlow.SessionHistoryTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Adapters.Function, Audio, Image}

  defmodule Output do
    @behaviour AudioFlow.Output
    def start_turn(_, _), do: :ok
    def push(_, _, _), do: :ok
    def flush(_, _), do: :ok

    def finish(owner, _) do
      send(owner, {:output_finish, self()})

      receive do
        {:finish, result} -> result
      end
    end
  end

  defp start(options \\ [], reply \\ fn _, emit -> emit.("a") end) do
    owner = self()

    options =
      AudioFlow.Adapters.Demo.options()
      |> Keyword.put(:history, true)
      |> Keyword.put(
        :stt,
        {Function, run: fn audio, emit -> emit.(String.trim_trailing(audio.data, <<0>>)) end}
      )
      |> Keyword.put(
        :llm,
        {Function,
         run: fn messages, emit ->
           send(owner, {:prompt, messages})
           reply.(messages, emit)
         end}
      )
      |> Keyword.merge(options)

    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  defp submit(session, text) do
    bytes = if rem(byte_size(text), 2) == 0, do: text, else: text <> <<0>>
    AudioFlow.submit(session, %Audio{data: bytes, sample_rate: 16_000})
  end

  defp complete(session, text) do
    {:ok, turn} = submit(session, text)
    assert_receive {:prompt, messages}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    messages
  end

  test "audio and image descriptions share ordered user/assistant history" do
    session =
      start([vision: {Function, run: fn _, emit -> emit.("Two cats.") end}], fn messages, emit ->
        case List.last(messages).content do
          "u1" ->
            emit.("First ")
            emit.("reply. ")

          _ ->
            emit.("a")
        end
      end)

    assert complete(session, "u1") == [%{role: :user, content: "u1"}]

    {:ok, turn} =
      AudioFlow.submit(session, %Image{data: <<0, 0, 0>>, width: 1, height: 1, pts: 1_500_000_000})

    assert_receive {:prompt, messages}

    assert messages == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "First reply. "},
             %{role: :user, content: "At video time 1500 ms: Two cats."}
           ]

    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}

    assert complete(session, "u2") == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "First reply. "},
             %{role: :user, content: "At video time 1500 ms: Two cats."},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u2"}
           ]
  end

  test "turn and byte limits evict complete pairs while retaining the new user input" do
    for {limits, last, expected} <- [
          {[max_turns: 1, max_bytes: 128], "u3",
           [
             %{role: :user, content: "u2"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u3"}
           ]},
          {[max_turns: 8, max_bytes: 6], "long", [%{role: :user, content: "long"}]}
        ] do
      session = start(history: limits)
      complete(session, "u1")
      complete(session, "u2")
      assert complete(session, last) == expected
    end
  end

  test "failed and cancelled partial replies leave the last successful pair available" do
    owner = self()

    session =
      start([], fn messages, emit ->
        case List.last(messages).content do
          "bad" ->
            emit.("Partial. ")
            {:error, :model_failed}

          "wait" ->
            emit.("Partial. ")
            send(owner, {:blocked, self()})

            receive do
              :continue -> :ok
            end

          _ ->
            emit.("a")
        end
      end)

    complete(session, "u1")

    {:ok, failed} = submit(session, "bad")
    assert_receive {:prompt, _}

    assert_receive {AudioFlow, ^session, ^failed,
                    {:error, {:adapter_error, Function, :model_failed}, _}}

    {:ok, cancelled} = submit(session, "wait")

    assert_receive {:prompt,
                    [
                      %{role: :user, content: "u1"},
                      %{role: :assistant, content: "a"},
                      %{role: :user, content: "wait"}
                    ]}

    assert_receive {:blocked, worker}
    ref = Process.monitor(worker)
    assert {:error, :busy} = AudioFlow.clear_history(session)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^cancelled, {:cancelled, _}}
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

    assert complete(session, "u2") == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u2"}
           ]
  end

  test "history commits only after the output transport accepts completion" do
    session = start(output: {Output, self()})
    {:ok, first} = submit(session, "u1")
    assert_receive {:prompt, _}
    assert_receive {:output_finish, actor}
    send(actor, {:finish, :ok})
    assert_receive {AudioFlow, ^session, ^first, {:done, _}}

    {:ok, failed} = submit(session, "bad")
    assert_receive {:prompt, _}
    assert_receive {:output_finish, ^actor}
    send(actor, {:finish, {:error, :offline}})
    assert_receive {AudioFlow, ^session, ^failed, {:error, {:output, :offline}, _}}

    {:ok, next} = submit(session, "u2")

    assert_receive {:prompt,
                    [
                      %{role: :user, content: "u1"},
                      %{role: :assistant, content: "a"},
                      %{role: :user, content: "u2"}
                    ]}

    assert_receive {:output_finish, ^actor}
    send(actor, {:finish, :ok})
    assert_receive {AudioFlow, ^session, ^next, {:done, _}}
  end

  test "context byte limits reject excess input and reply text without corrupting history" do
    session =
      start([history: [max_bytes: 8]], fn messages, emit ->
        if List.last(messages).content == "u2", do: emit.("1234567"), else: emit.("a")
      end)

    {:ok, input} = submit(session, "1234567890")
    assert_receive {AudioFlow, ^session, ^input, {:error, :context_limit, _}}
    assert complete(session, "u1") == [%{role: :user, content: "u1"}]
    {:ok, reply} = submit(session, "u2")
    assert_receive {:prompt, _}
    assert_receive {AudioFlow, ^session, ^reply, {:error, :context_limit, _}}

    assert complete(session, "u3") == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u3"}
           ]
  end

  test "empty input and blank replies do not create unanswered history entries" do
    session =
      start([], fn messages, emit ->
        if List.last(messages).content == "blank", do: emit.(" \n"), else: emit.("a")
      end)

    complete(session, "u1")
    {:ok, empty} = submit(session, "")
    assert_receive {AudioFlow, ^session, ^empty, {:done, _}}
    complete(session, "blank")

    assert complete(session, "u2") == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u2"}
           ]
  end

  test "clearing history starts a new conversation on the same session" do
    session = start()
    complete(session, "u1")
    assert :ok = AudioFlow.clear_history(session)
    assert complete(session, "u2") == [%{role: :user, content: "u2"}]
  end

  test "sessions keep separate history when they use the same inference worker" do
    owner = self()

    worker =
      start_supervised!(
        {AudioFlow.Worker,
         adapter:
           {Function,
            run: fn messages, emit ->
              send(owner, {:prompt, messages})
              emit.("a")
            end},
         max_concurrency: 2}
      )

    first = start(llm: {AudioFlow.Worker, worker: worker})
    second = start(llm: {AudioFlow.Worker, worker: worker})
    complete(first, "u1")
    assert complete(second, "v1") == [%{role: :user, content: "v1"}]

    assert complete(first, "u2") == [
             %{role: :user, content: "u1"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "u2"}
           ]

    assert complete(second, "v2") == [
             %{role: :user, content: "v1"},
             %{role: :assistant, content: "a"},
             %{role: :user, content: "v2"}
           ]
  end
end
