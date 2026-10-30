if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.PlaybackTest do
    use ExUnit.Case, async: true
    @moduletag capture_log: true
    alias AudioFlow.{Audio, Playback}

    defp player do
      start_supervised!(
        {Playback,
         sink: %AudioFlow.Test.DemandSink{owner: self()}, max_bytes: 4, observer: self()}
      )
    end

    defp audio(value),
      do: %Audio{data: <<value::little-signed-16, value::little-signed-16>>, sample_rate: 16000}

    defp demand(sink, count), do: send(sink, {:demand, count})

    test "a bounded queue applies back pressure and delivers PCM in order with timestamps" do
      player = player()
      key = {self(), make_ref()}
      assert :ok = Playback.start_turn(player, key)
      assert :ok = Playback.push(player, key, audio(1))
      assert_receive {Playback, ^player, ^key, {:pipeline_started, _pipeline}}

      assert_receive {:sink_ready, sink}, 2000

      assert_receive {Playback, ^player, ^key, {:first_buffer, _}}, 2000
      :ok = Playback.push(player, key, audio(2))
      pending = Task.async(fn -> Playback.push(player, key, audio(3)) end)

      assert_receive {Playback, ^player, ^key,
                      {:backpressure, %{queued_bytes: 4, waiting_bytes: 4}}}

      assert Task.yield(pending, 0) == nil
      assert %{queued_bytes: 4, blocked?: true} = Playback.stats(player)
      demand(sink, 1)
      assert :ok = Task.await(pending)
      first = audio(1).data

      assert_receive {:played, ^sink, %Membrane.Buffer{payload: ^first, pts: 0}}, 2000

      assert :ok = Playback.finish(player, key)
      demand(sink, 2)
      second = audio(2).data
      third = audio(3).data

      assert_receive {:played, ^sink, %Membrane.Buffer{payload: ^second, pts: 125_000}}, 2000

      assert_receive {:played, ^sink, %Membrane.Buffer{payload: ^third, pts: 250_000}}, 2000
      assert_receive {Playback, ^player, ^key, :drained}, 2000
    end

    test "flush releases a blocked producer, closes the old pipeline, and isolates the new turn" do
      player = player()
      key = {self(), make_ref()}
      :ok = Playback.start_turn(player, key)
      :ok = Playback.push(player, key, audio(1))
      assert_receive {Playback, ^player, ^key, {:pipeline_started, pipeline}}
      ref = Process.monitor(pipeline)
      assert_receive {:sink_ready, _old_sink}, 2000
      assert_receive {Playback, ^player, ^key, {:first_buffer, _}}, 2000
      :ok = Playback.push(player, key, audio(2))
      pending = Task.async(fn -> Playback.push(player, key, audio(3)) end)
      assert_receive {Playback, ^player, ^key, {:backpressure, _}}, 2000
      assert :ok = Playback.flush(player, key)
      assert {:error, :stale_turn} = Task.await(pending)
      assert_receive {:DOWN, ^ref, :process, ^pipeline, _}
      assert_receive {Playback, ^player, ^key, {:flushed, %{control_us: us}}}
      assert us >= 0
      assert {:error, :stale_turn} = Playback.push(player, key, audio(3))
      next = {self(), make_ref()}
      :ok = Playback.start_turn(player, next)
      :ok = Playback.push(player, next, audio(4))
      assert_receive {Playback, ^player, ^next, {:pipeline_started, _next_pipeline}}
      assert_receive {:sink_ready, next_sink}, 2000
      :ok = Playback.finish(player, next)
      demand(next_sink, 2)
      expected = audio(4).data

      assert_receive {:played, ^next_sink, %Membrane.Buffer{payload: ^expected}}, 2000

      assert_receive {Playback, ^player, ^next, :drained}, 2000
    end

    test "session cancellation stops output while the turn worker waits for capacity" do
      player = player()
      owner = self()

      tts =
        {AudioFlow.Adapters.Function,
         run: fn _, emit ->
           send(owner, {:worker, self()})
           Enum.each(1..3, fn value -> emit.(audio(value)) end)
           :ok
         end}

      options =
        AudioFlow.Adapters.Demo.options()
        |> Keyword.put(:tts, tts)
        |> Keyword.put(:output, {Playback, player})

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      {:ok, turn} = AudioFlow.submit(session, audio(0))
      key = {session, turn}
      assert_receive {:worker, worker}
      ref = Process.monitor(worker)
      assert_receive {Playback, ^player, ^key, {:pipeline_started, pipeline}}
      pipeline_ref = Process.monitor(pipeline)
      assert_receive {Playback, ^player, ^key, {:backpressure, _}}, 2000
      assert :ok = AudioFlow.cancel(session)
      assert_receive {AudioFlow, ^session, ^turn, {:cancelled, _}}
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
      assert_receive {:DOWN, ^pipeline_ref, :process, ^pipeline, _}
      assert %{queued_bytes: 0, blocked?: false, key: nil} = Playback.stats(player)
      assert {:ok, _} = AudioFlow.submit(session, audio(0))
    end

    test "a completed turn can still be interrupted while output is queued" do
      player = player()
      tts = {AudioFlow.Adapters.Function, run: fn _, emit -> emit.(audio(1)) end}

      options =
        AudioFlow.Adapters.Demo.options()
        |> Keyword.put(:tts, tts)
        |> Keyword.put(:output, {Playback, player})

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      {:ok, turn} = AudioFlow.submit(session, audio(0))
      key = {session, turn}
      assert_receive {Playback, ^player, ^key, {:pipeline_started, pipeline}}
      ref = Process.monitor(pipeline)
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
      assert :ok = AudioFlow.cancel(session)
      assert_receive {:DOWN, ^ref, :process, ^pipeline, _}
      assert %{queued_bytes: 0, key: nil} = Playback.stats(player)
    end

    test "an abrupt session exit closes its output pipeline" do
      player = player()
      options = Keyword.put(AudioFlow.Adapters.Demo.options(), :output, {Playback, player})
      # Demo PCM exceeds this test player's bound, so use a small actual output.
      options =
        Keyword.put(
          options,
          :tts,
          {AudioFlow.Adapters.Function, run: fn _, emit -> emit.(audio(1)) end}
        )

      {:ok, session} = AudioFlow.start_session(options)
      {:ok, turn} = AudioFlow.submit(session, audio(0))
      key = {session, turn}
      assert_receive {Playback, ^player, ^key, {:pipeline_started, pipeline}}
      ref = Process.monitor(pipeline)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pipeline, _}, 2000
      assert %{queued_bytes: 0, key: nil} = Playback.stats(player)
    end

    test "a failed sink releases a blocked producer and reports the failure" do
      player = player()
      key = {self(), make_ref()}
      :ok = Playback.start_turn(player, key)
      :ok = Playback.push(player, key, audio(1))
      assert_receive {:sink_ready, sink}, 2000
      assert_receive {Playback, ^player, ^key, {:first_buffer, _}}, 2000
      :ok = Playback.push(player, key, audio(2))
      pending = Task.async(fn -> Playback.push(player, key, audio(3)) end)
      assert_receive {Playback, ^player, ^key, {:backpressure, _}}, 2000
      send(sink, :crash)
      assert {:error, {:pipeline_exit, _}} = Task.await(pending)
      assert_receive {Playback, ^player, ^key, {:failed, _}}, 2000
      assert %{queued_bytes: 0, blocked?: false, key: nil} = Playback.stats(player)
    end

    test "an empty transcript finishes and drains without PCM" do
      player = player()

      options =
        AudioFlow.Adapters.Demo.options()
        |> Keyword.put(:stt, {AudioFlow.Adapters.Function, run: fn _, emit -> emit.("") end})
        |> Keyword.put(:output, {Playback, player})

      {:ok, session} = AudioFlow.start_session(options)
      on_exit(fn -> if Process.alive?(session), do: AudioFlow.stop_session(session) end)
      {:ok, turn} = AudioFlow.submit(session, audio(0))
      key = {session, turn}
      assert_receive {AudioFlow, ^session, ^turn, {:done, _}}
      assert_receive {Playback, ^player, ^key, :drained}
      assert %{queued_bytes: 0, pipeline: nil} = Playback.stats(player)
    end
  end
end
