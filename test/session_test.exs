defmodule AudioFlow.SessionTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Audio, Adapters.Demo}

  defp audio, do: %Audio{data: <<0, 0>>, sample_rate: 16_000}

  defp start(options \\ []) do
    {:ok, session} = AudioFlow.start_session(Keyword.merge(Demo.options(), options))
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  defp function(fun), do: {AudioFlow.Adapters.Function, [run: fun]}

  test "a turn emits ordered transcript, text, PCM, and monotonic metrics" do
    session = start()
    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hello"}}
    assert_receive {AudioFlow, ^session, ^turn, {:text, "You said: Hello."}}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{sample_rate: 16_000, data: pcm}}}
    assert byte_size(pcm) == 3200
    assert_receive {AudioFlow, ^session, ^turn, {:done, metrics}}
    assert metrics.events == 3
    assert 0 <= metrics.first_transcript_us
    assert metrics.first_transcript_us <= metrics.first_text_us
    assert metrics.first_text_us <= metrics.first_audio_us
    assert metrics.first_audio_us <= metrics.duration_us
    assert {:ok, _} = AudioFlow.submit(session, audio())
  end

  test "STT chunks form one prompt and generated chunks reach TTS in order" do
    owner = self()

    session =
      start(
        stt:
          function(fn _, emit ->
            emit.("Hello ")
            emit.("world")
          end),
        llm:
          function(fn prompt, emit ->
            send(owner, {:prompt, prompt})
            emit.("One.")
            emit.("Two.")
          end),
        tts: function(fn text, emit -> emit.(%Audio{data: text, sample_rate: 8000}) end)
      )

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {:prompt, "Hello world"}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{data: "One."}}}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{data: "Two."}}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  test "a whitespace text tail is preserved without sending empty speech to TTS" do
    session =
      start(
        llm:
          function(fn _, emit ->
            emit.("Hello.")
            emit.(" ")
          end),
        tts:
          function(fn text, emit ->
            if String.trim(text) == "", do: {:error, :empty_text}, else: emit.(audio())
          end)
      )

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:text, "Hello."}}
    assert_receive {AudioFlow, ^session, ^turn, {:text, " "}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  test "busy input is rejected, cancellation kills the task, and a new turn runs" do
    owner = self()

    session =
      start(
        llm:
          function(fn _, _ ->
            send(owner, {:blocked, self()})

            receive do
              :continue -> :ok
            end
          end)
      )

    {:ok, first} = AudioFlow.submit(session, audio())
    assert_receive {:blocked, worker}
    assert_receive {AudioFlow, ^session, ^first, {:transcript, "Hello"}}
    monitor = Process.monitor(worker)
    assert {:error, :busy} = AudioFlow.submit(session, audio())
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^first, {:cancelled, _}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    {:ok, second} = AudioFlow.submit(session, audio())
    assert second != first
    assert_receive {:blocked, next_worker}
    send(next_worker, :continue)
    assert_receive {AudioFlow, ^session, ^second, {:done, _}}
    refute_receive {AudioFlow, ^session, ^first, _}
  end

  test "a timeout stops inference and leaves the session ready" do
    session =
      start(
        timeout_ms: 10,
        stt:
          function(fn _, _ ->
            receive do
              :wait -> :ok
            end
          end)
      )

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:error, :timeout, _}}
    assert {:ok, _} = AudioFlow.submit(session, audio())
  end

  test "adapter errors and crashes do not stop other sessions" do
    for adapter <- [
          function(fn _, _ -> {:error, :offline} end),
          function(fn _, _ -> raise "broken" end),
          function(fn _, _ -> Process.exit(self(), :kill) end)
        ] do
      session = start(stt: adapter)
      {:ok, turn} = AudioFlow.submit(session, audio())
      assert_receive {AudioFlow, ^session, ^turn, {:error, _, _}}
      assert Process.alive?(session)
    end

    session = start()
    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
  end

  test "input and output limits reject excess data" do
    session = start(max_input_bytes: 2, max_events: 1)

    assert {:error, :input_too_large} =
             AudioFlow.submit(session, %Audio{data: <<0, 0, 0, 0>>, sample_rate: 8000})

    assert {:error, :invalid_audio} =
             AudioFlow.submit(session, %Audio{data: <<0>>, sample_rate: 8000})

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:transcript, "Hello"}}
    assert_receive {AudioFlow, ^session, ^turn, {:error, :output_limit, _}}
  end

  test "owner exit stops the session and its active inference task" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} =
          AudioFlow.start_session(
            Keyword.put(
              Demo.options(),
              :stt,
              function(fn _, _ ->
                send(parent, {:worker, self()})

                receive do
                  :wait -> :ok
                end
              end)
            )
          )

        AudioFlow.submit(session, audio())
        send(parent, {:session, session})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:session, session}
    assert_receive {:worker, worker}
    session_ref = Process.monitor(session)
    worker_ref = Process.monitor(worker)
    send(owner, :stop)
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end
end
