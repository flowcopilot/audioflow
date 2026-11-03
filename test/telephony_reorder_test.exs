defmodule AudioFlow.TelephonyReorderTest do
  use ExUnit.Case, async: true
  alias AudioFlow.Adapters.Demo
  alias AudioFlow.Telephony.WebSocket, as: Handler

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
             Handler.handle_info({AudioFlow.WebSocket, :push, key, audio, {self(), tag}}, state)

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
             Handler.handle_info({AudioFlow.WebSocket, :flush, key}, state)

    assert JSON.decode!(clear) == %{"event" => "clear"}
    assert :queue.is_empty(state.playout)
    assert state.pending == <<>> and state.playout_timer == nil
    assert Process.read_timer(timer) == false
    assert {:ok, ^state} = Handler.handle_info({Handler, :playout, old_token}, state)
  end

  test "output queue has a hard packet cap" do
    state = start(max_playout_packets: 1)
    ref = make_ref()
    state = %{state | pcm: %{state.pcm | turn: {ref, 1}}}
    audio = %AudioFlow.Audio{sample_rate: 8000, data: :binary.copy(<<0>>, 640)}

    assert {:stop, {:protocol_error, :playout_limit}, _, state} =
             Handler.handle_info(
               {AudioFlow.WebSocket, :push, {state.pcm.session, ref}, audio,
                {self(), make_ref()}},
               state
             )

    assert :queue.is_empty(state.playout) and state.playout_timer == nil
  end
end
