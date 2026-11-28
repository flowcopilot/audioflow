defmodule AudioFlow.SessionTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Audio

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

  test "a turn waits for a busy session longer than the default call timeout" do
    owner = self()

    session =
      start(
        llm:
          function(fn _, emit ->
            send(owner, {:worker, self()})

            receive do
              :go -> emit.("late")
            end
          end),
        tts: function(fn text, emit -> emit.(%Audio{data: text, sample_rate: 8000}) end)
      )

    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {:worker, worker}
    :sys.suspend(session)
    send(worker, :go)
    Process.sleep(5_300)
    :sys.resume(session)
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}, 1_000
  end

  test "an adapter exception is logged with its stacktrace and reported by message" do
    session = start(llm: function(fn _, _ -> raise "boom" end))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, turn} = AudioFlow.submit(session, audio())
        assert_receive {AudioFlow, ^session, ^turn, {:error, {:exception, "boom"}, _}}
      end)

    assert log =~ "** (RuntimeError) boom"
    assert log =~ "session_test.exs"
  end

  defmodule PcmOutput do
    @behaviour AudioFlow.Output
    def start_turn(_, _), do: :ok

    def push(owner, _key, audio) do
      send(owner, {:pcm, audio.data})
      :ok
    end

    def finish(_, _), do: :ok
    def flush(_, _), do: :ok
  end

  test "notify_audio false keeps audio events from the owner but not from the output" do
    session = start(notify_audio: false, output: {PcmOutput, self()})
    {:ok, turn} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^turn, {:text, _}}
    assert_receive {:pcm, pcm}
    assert byte_size(pcm) == 3200
    assert_receive {AudioFlow, ^session, ^turn, {:done, %{events: 3}}}
    refute_received {AudioFlow, ^session, ^turn, {:audio, _}}
  end

  test "a turn task exits when its session is killed" do
    owner = self()

    session =
      start(
        llm:
          function(fn _, _ ->
            send(owner, {:worker, self()})
            Process.sleep(:infinity)
          end)
      )

    {:ok, _turn} = AudioFlow.submit(session, audio())
    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_000
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

  @tag :capture_log
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

  test "an image-only session joins description chunks and speaks one response" do
    owner = self()

    options =
      Demo.options()
      |> Keyword.delete(:stt)
      |> Keyword.put(
        :vision,
        function(fn %AudioFlow.Image{}, emit ->
          emit.("Two cats ")
          emit.("on a couch.")
        end)
      )
      |> Keyword.put(
        :llm,
        function(fn prompt, emit ->
          send(owner, {:prompt, prompt})
          emit.("The cats are resting.")
        end)
      )

    {:ok, session} = AudioFlow.start_session(options)
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    image = %AudioFlow.Image{data: <<255, 0, 0>>, width: 1, height: 1}
    {:ok, turn} = AudioFlow.submit(session, image)
    assert_receive {AudioFlow, ^session, ^turn, {:description, "Two cats "}}
    assert_receive {AudioFlow, ^session, ^turn, {:description, "on a couch."}}
    assert_receive {:prompt, "Two cats on a couch."}
    assert_receive {AudioFlow, ^session, ^turn, {:text, "The cats are resting."}}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{}}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, metrics}}
    assert is_integer(metrics.first_description_us)
    assert metrics.first_transcript_us == nil
    assert metrics.first_description_us <= metrics.first_text_us
  end

  test "image input validates RGB size, rejects excess bytes, and requires a vision adapter" do
    image = %AudioFlow.Image{data: <<255, 0, 0>>, width: 1, height: 1}
    session = start(max_image_bytes: 2, vision: function(fn _, emit -> emit.("Red.") end))

    for invalid <- [
          %{image | width: 0},
          %{image | height: -1},
          %{image | data: <<255, 0>>},
          %{image | data: :invalid},
          %{image | pts: 1.5}
        ] do
      assert {:error, :invalid_image} = AudioFlow.submit(session, invalid)
    end

    assert {:error, :input_too_large} = AudioFlow.submit(session, image)
    without_vision = start()
    assert {:error, {:unsupported_input, :vision}} = AudioFlow.submit(without_vision, image)
  end

  test "a text turn skips the input stage and speaks the reply" do
    owner = self()

    session =
      start(
        stt: function(fn _, _ -> raise "STT must not run" end),
        llm:
          function(fn prompt, emit ->
            send(owner, {:prompt, prompt})
            emit.("Hi.")
          end)
      )

    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: "  Hello there \n"})
    assert_receive {:prompt, "Hello there"}
    assert_receive {AudioFlow, ^session, ^turn, {:text, "Hi."}}
    assert_receive {AudioFlow, ^session, ^turn, {:audio, %Audio{}}}
    assert_receive {AudioFlow, ^session, ^turn, {:done, metrics}}
    assert metrics.first_transcript_us == nil
    assert metrics.events == 2
    refute_received {AudioFlow, ^session, ^turn, {:transcript, _}}
  end

  test "text input validates UTF-8 and the input byte limit" do
    session = start(max_input_bytes: 4)
    assert {:error, :invalid_text} = AudioFlow.submit(session, %AudioFlow.Text{data: <<255>>})
    assert {:error, :invalid_text} = AudioFlow.submit(session, %AudioFlow.Text{data: :hello})

    assert {:error, :input_too_large} =
             AudioFlow.submit(session, %AudioFlow.Text{data: "Hello"})

    {:ok, turn} = AudioFlow.submit(session, %AudioFlow.Text{data: " "})
    assert_receive {AudioFlow, ^session, ^turn, {:done, %{events: 0}}}
  end

  test "an image turn can be cancelled before a voice turn on the same session" do
    owner = self()

    session =
      start(
        vision:
          function(fn _, _ ->
            send(owner, {:vision_task, self()})

            receive do
              :continue -> :ok
            end
          end)
      )

    {:ok, first} =
      AudioFlow.submit(session, %AudioFlow.Image{data: <<255, 0, 0>>, width: 1, height: 1})

    assert_receive {:vision_task, vision_task}
    ref = Process.monitor(vision_task)
    assert {:error, :busy} = AudioFlow.submit(session, audio())
    assert :ok = AudioFlow.cancel(session)
    assert_receive {AudioFlow, ^session, ^first, {:cancelled, _}}
    assert_receive {:DOWN, ^ref, :process, ^vision_task, :killed}
    {:ok, second} = AudioFlow.submit(session, audio())
    assert_receive {AudioFlow, ^session, ^second, {:transcript, "Hello"}}
    assert_receive {AudioFlow, ^session, ^second, {:done, _}}
  end
end
