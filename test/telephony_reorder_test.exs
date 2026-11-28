defmodule AudioFlow.TelephonyReorderTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Telephony.WebSocket, as: Handler
  alias AudioFlow.Transport.Connection

  defp start(options \\ []) do
    {:ok, state} =
      Handler.init(
        Keyword.merge(
          [
            provider: :telnyx,
            session: Demo.options(),
            vad: {AudioFlow.Test.AlwaysSpeechDetector, []}
          ],
          options
        )
      )

    {:ok, state} =
      send_frame(state, %{
        event: "start",
        sequence_number: "1",
        stream_id: "call-stream",
        start: %{
          call_control_id: "v3:fixture",
          tracks: ["inbound"],
          media_format: %{encoding: "PCMU", sample_rate: 8000, channels: 1}
        }
      })

    on_exit(fn -> Handler.terminate(:normal, state) end)
    state
  end

  defp send_frame(state, message),
    do: Handler.handle_in({JSON.encode!(message), opcode: :text}, state)

  defp media(state, chunk, bytes \\ :binary.copy(<<255>>, 160)) do
    send_frame(state, %{
      event: "media",
      sequence_number: Integer.to_string(chunk + 1),
      stream_id: "call-stream",
      media: %{
        track: "inbound",
        chunk: Integer.to_string(chunk),
        timestamp: Integer.to_string((chunk - 1) * 20),
        payload: Base.encode64(bytes)
      }
    })
  end

  test "Telnyx reorders first and subsequent chunks without decoding duplicates" do
    state = start()
    {:ok, state} = media(state, 2, :binary.copy(<<127>>, 160))
    assert state.last_chunk == nil
    {timer, token} = state.gap_timer
    {:ok, duplicate} = media(state, 2, :binary.copy(<<0>>, 160))
    assert duplicate == state
    {:ok, state} = media(state, 1)
    assert state.last_chunk == 2
    assert state.reorder == %{}
    assert state.reorder_bytes == 0
    assert state.gap_timer == nil
    assert Process.read_timer(timer) == false
    {:ok, unchanged} = media(state, 1)
    assert unchanged == state
    assert {:ok, ^state} = Handler.handle_info({Handler, :gap_timeout, token}, state)
    {:ok, state} = media(state, 4)
    {:ok, state} = media(state, 3)
    assert state.last_chunk == 4
  end

  test "missing chunks expire with bounded cleanup; stale timeout is harmless" do
    state = start(reorder_timeout_ms: 10)
    {:ok, state} = media(state, 2)
    assert_receive {Handler, :gap_timeout, token}, 100

    assert {:stop, {:protocol_error, :media_gap_timeout}, {1008, _}, state} =
             Handler.handle_info({Handler, :gap_timeout, token}, state)

    assert state.reorder == %{} and state.reorder_bytes == 0 and state.gap_timer == nil
  end

  test "reorder distance and byte caps fail closed" do
    state = start(reorder_window: 2, reorder_max_bytes: 200)
    assert {:stop, {:protocol_error, :reorder_limit}, _, _} = media(state, 4)
    {:ok, state} = media(state, 2)
    assert {:stop, {:protocol_error, :reorder_limit}, _, clean} = media(state, 3)
    assert clean.reorder == %{} and clean.gap_timer == nil
  end

  test "termination cancels outstanding gap timers" do
    {:ok, state} = media(start(), 2)
    {timer, _} = state.gap_timer
    Handler.terminate(:normal, state)
    assert Process.read_timer(timer) == false
  end

  test "output pacing emits one 20ms packet per tick and flush drops queued audio" do
    state = start()
    ref = make_ref()
    state = %{state | pcm: %{state.pcm | turn: {ref, 1}}}
    tag = make_ref()
    key = {state.pcm.session, ref}
    audio = %AudioFlow.Audio{sample_rate: 8000, data: :binary.copy(<<0>>, 960)}

    assert {:ok, state} =
             Handler.handle_info(
               {Connection, :push, key, audio, {self(), tag}},
               state
             )

    assert_receive {^tag, :ok}
    assert :queue.len(state.playout) == 3
    {timer, token} = state.playout_timer
    assert_receive {Handler, :playout, ^token}, 100

    assert {:push, [{:text, json}], state} =
             Handler.handle_info({Handler, :playout, token}, state)

    assert byte_size(Base.decode64!(JSON.decode!(json)["media"]["payload"])) == 160
    assert :queue.len(state.playout) == 2
    assert Process.read_timer(timer) == false
    {timer, old_token} = state.playout_timer

    assert {:push, [{:text, clear}], state} =
             Handler.handle_info({Connection, :flush, key}, state)

    assert JSON.decode!(clear) == %{"event" => "clear"}
    assert :queue.is_empty(state.playout)
    assert state.playout_timer == nil
    assert Process.read_timer(timer) == false
    assert {:ok, ^state} = Handler.handle_info({Handler, :playout, old_token}, state)
  end

  defp with_turn(state) do
    ref = make_ref()
    {%{state | pcm: %{state.pcm | turn: {ref, 1}}}, {state.pcm.session, ref}}
  end

  defp pcm8(packets),
    do: %AudioFlow.Audio{sample_rate: 8000, data: :binary.copy(<<0>>, packets * 320)}

  defp push_message(key, audio, tag),
    do: {Connection, :push, key, audio, {self(), tag}}

  # Plays the endpoint loop: handles pushes as they arrive and fires playout
  # ticks by hand until the producer task finishes and the queue is empty.
  defp drive(state, task, packets \\ 0, longest \\ 0, done? \\ false) do
    receive do
      {Connection, :push, _, _, _} = message ->
        {state, sent} = step(Handler.handle_info(message, state))
        drive(state, task, packets + sent, max(longest, :queue.len(state.playout)), done?)
    after
      0 ->
        done? = done? or match?({:ok, _}, Task.yield(task, 0))

        cond do
          done? and :queue.is_empty(state.playout) ->
            {state, packets, longest}

          state.playout_timer == nil ->
            Process.sleep(1)
            drive(state, task, packets, longest, done?)

          true ->
            {_, token} = state.playout_timer
            {state, sent} = step(Handler.handle_info({Handler, :playout, token}, state))
            drive(state, task, packets + sent, longest, done?)
        end
    end
  end

  defp step({:ok, state}), do: {state, 0}
  defp step({:push, frames, state}), do: {state, length(frames)}

  test "a producer faster than playout is held, not disconnected" do
    {state, key} = start(max_playout_packets: 5) |> with_turn()
    parent = self()

    task =
      Task.async(fn ->
        # 30 chunks of 100 ms: three seconds, with a ten-packet limit window.
        for _ <- 1..30, do: :ok = Connection.push(parent, key, pcm8(5))
      end)

    {state, packets, longest} = drive(state, task)
    assert packets == 150
    assert longest <= 10
    assert state.held == nil
  end

  test "a push over the high-water mark waits until playout drains the queue" do
    {state, key} = start(max_playout_packets: 2) |> with_turn()
    tag = make_ref()
    assert {:ok, state} = Handler.handle_info(push_message(key, pcm8(3), tag), state)
    refute_receive {^tag, _}, 20

    {_, token} = state.playout_timer
    assert {:push, [_], state} = Handler.handle_info({Handler, :playout, token}, state)
    assert_receive {^tag, :ok}
    assert state.held == nil
  end

  test "a push within the mark is acknowledged at once" do
    {state, key} = start(max_playout_packets: 5) |> with_turn()
    tag = make_ref()
    assert {:ok, _} = Handler.handle_info(push_message(key, pcm8(3), tag), state)
    assert_receive {^tag, :ok}
  end

  test "flush releases a held push with a stale turn error" do
    {state, key} = start(max_playout_packets: 1) |> with_turn()
    tag = make_ref()
    assert {:ok, state} = Handler.handle_info(push_message(key, pcm8(2), tag), state)
    refute_receive {^tag, _}, 20

    assert {:push, [{:text, _}], state} =
             Handler.handle_info({Connection, :flush, key}, state)

    assert_receive {^tag, {:error, :stale_turn}}
    assert state.held == nil
  end

  test "the end of a turn and termination release a held push" do
    {state, {session, ref} = key} = start(max_playout_packets: 1) |> with_turn()
    tag = make_ref()
    assert {:ok, held} = Handler.handle_info(push_message(key, pcm8(2), tag), state)

    assert {:ok, state} = Handler.handle_info({AudioFlow, session, ref, {:cancelled, %{}}}, held)
    assert_receive {^tag, {:error, :stale_turn}}
    assert state.held == nil

    tag = make_ref()
    {state, key} = with_turn(state)
    assert {:ok, held} = Handler.handle_info(push_message(key, pcm8(2), tag), state)
    Handler.terminate(:normal, held)
    assert_receive {^tag, {:error, :stale_turn}}
  end

  @tag :capture_log
  test "a failed turn leaves the call open" do
    {state, {session, ref}} = start() |> with_turn()

    for reason <- [:timeout, :busy, :context_limit, {:exception, "boom"}] do
      assert {:ok, %{pcm: %{turn: nil}}} =
               Handler.handle_info({AudioFlow, session, ref, {:error, reason, %{}}}, state)
    end
  end

  test "a chunk larger than the whole queue closes the call" do
    {state, key} = start(max_playout_packets: 1) |> with_turn()
    tag = make_ref()

    assert {:stop, {:protocol_error, :playout_limit}, _, state} =
             Handler.handle_info(push_message(key, pcm8(5), tag), state)

    assert_receive {^tag, {:error, :telephony_output_too_large}}
    assert :queue.is_empty(state.playout) and state.playout_timer == nil
  end

  test "playout ticks follow absolute deadlines and resync after a long stall" do
    {state, key} = start() |> with_turn()
    assert {:ok, state} = Handler.handle_info(push_message(key, pcm8(5), make_ref()), state)
    first = state.playout_deadline
    {_, token} = state.playout_timer

    assert {:push, [_], state} = Handler.handle_info({Handler, :playout, token}, state)
    assert state.playout_deadline == first + 20

    now = System.monotonic_time(:millisecond)
    state = %{state | playout_deadline: now - 1_000}
    {_, token} = state.playout_timer
    assert {:push, [_], state} = Handler.handle_info({Handler, :playout, token}, state)
    assert state.playout_deadline >= now + 20
  end

  test "an empty queue resets the playout clock" do
    {state, key} = start() |> with_turn()
    assert {:ok, state} = Handler.handle_info(push_message(key, pcm8(1), make_ref()), state)
    {_, token} = state.playout_timer
    assert {:push, [_], state} = Handler.handle_info({Handler, :playout, token}, state)
    assert state.playout_deadline == nil and state.playout_timer == nil
  end
end
