defmodule AudioFlow.InterruptionTest do
  use ExUnit.Case, async: true
  alias AudioFlow.{Adapters.Function, Audio, Output, Text}

  defp session(overrides \\ []) do
    owner = self()

    options =
      AudioFlow.Adapters.Demo.options()
      |> Keyword.put(:history, true)
      |> Keyword.put(
        :tts,
        {Function,
         run: fn _, emit ->
           emit.(%Audio{data: <<0, 0, 0, 0>>, sample_rate: 16_000})
         end}
      )
      |> Keyword.put(
        :llm,
        {Function,
         run: fn messages, emit ->
           send(owner, {:prompt, messages})
           emit.("Héard. ")
           emit.("Unheard.")
           send(owner, {:waiting, self()})

           receive do
             :finish -> :ok
           end
         end}
      )

    {:ok, session} = AudioFlow.start_session(Keyword.merge(options, overrides))
    on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
    session
  end

  test "cancel retains only whole acknowledged chunks and rejects stale acknowledgements" do
    session = session()
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, _}
    assert {:error, :invalid_playback_offset} = Output.acknowledge(session, turn, 999_999)
    assert :ok = Output.acknowledge(session, turn, 125_000)
    assert {:error, :invalid_playback_offset} = Output.acknowledge(session, turn, 0)
    assert :ok = AudioFlow.cancel(session)
    assert {:error, :stale_turn} = Output.acknowledge(session, turn, 250_000)
    {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})

    assert_receive {:prompt,
                    [
                      %{role: :user, content: "first"},
                      %{role: :assistant, content: "Héard. "},
                      %{role: :user, content: "next"}
                    ]}
  end

  test "cancel during synthesis does not attribute partially synthesized text to heard history" do
    owner = self()

    session =
      session(
        tts:
          {Function,
           run: fn _, emit ->
             emit.(%Audio{data: <<0, 0, 0, 0>>, sample_rate: 16_000})
             send(owner, {:synth_wait, self()})

             receive do
               :continue -> :ok
             end
           end}
      )

    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:synth_wait, worker}
    assert :ok = Output.acknowledge(session, turn, 125_000)
    ref = Process.monitor(worker)
    assert :ok = AudioFlow.cancel(session)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})
    assert_receive {:prompt, [%{role: :user, content: "next"}]}
  end

  test "partial audio without a whole checkpoint and queued audio are not heard" do
    for offset <- [0, 124_999] do
      session = session()
      {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
      assert_receive {:prompt, _}
      assert_receive {:waiting, _}
      assert :ok = Output.acknowledge(session, turn, offset)
      assert :ok = AudioFlow.cancel(session)
      {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})
      assert_receive {:prompt, [%{role: :user, content: "next"}]}
      assert_receive {:waiting, _}
      AudioFlow.stop_session(session)
    end
  end

  test "completed generation can be truncated while audio remains queued; clear does not resurrect it" do
    session = session()
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, worker}
    send(worker, :finish)
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    assert :ok = Output.acknowledge(session, turn, 125_000)
    assert :ok = AudioFlow.cancel(session)
    assert :ok = AudioFlow.cancel(session)
    assert :ok = AudioFlow.clear_history(session)
    assert :ok = AudioFlow.cancel(session)
    {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})
    assert_receive {:prompt, [%{role: :user, content: "next"}]}
  end

  test "cancelling completed generation replaces its committed reply with heard text" do
    session = session()
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, worker}
    send(worker, :finish)
    assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
    assert :ok = Output.acknowledge(session, turn, 125_000)
    assert :ok = AudioFlow.cancel(session)
    {:ok, _} = AudioFlow.submit(session, %Text{data: "next"})

    assert_receive {:prompt,
                    [
                      %{role: :user, content: "first"},
                      %{role: :assistant, content: "Héard. "},
                      %{role: :user, content: "next"}
                    ]}

    assert {:error, :stale_turn} = Output.acknowledge(session, turn, 250_000)
  end

  test "minimum-word gate preserves the running worker on a false trigger" do
    session = session()
    {:ok, turn} = AudioFlow.submit(session, %Text{data: "first"})
    assert_receive {:prompt, _}
    assert_receive {:waiting, worker}
    assert {:ok, :ignored} = Output.interrupt(session, "uh", min_words: 2)
    assert Process.alive?(worker)
    refute_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
    assert :ok = Output.interrupt(session, "please stop", min_words: 2)
    assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
  end
end
