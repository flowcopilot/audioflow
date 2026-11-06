defmodule AudioFlow.WebSocket do
  @moduledoc """
  Raw PCM WebSocket transport for one conversation.

  This is a `WebSock` handler. Mount it with an adapter such as `WebSockAdapter`:

      WebSockAdapter.upgrade(conn, AudioFlow.WebSocket,
        [session: AudioFlow.Adapters.Demo.options(), vad: {Detector, []}],
        max_frame_size: 1_000_000)

  Each connection starts one session and owns it. The session stops when the
  connection closes. The client never becomes the session owner. The
  connection is also the session's `AudioFlow.Output` transport, so it
  replaces an `:output` option. A turn worker waits until the connection
  accepts each output chunk.

  ## Options

    * `:session` - session options for `AudioFlow.start_session/1`. Required.
    * `:vad` - voice detector tuple. With a detector, the connection streams
      input through `AudioFlow.VoiceInput`. Confirmed speech cancels the active
      reply, and an endpoint submits the utterance. Without a detector, input
      collects until the client sends `commit`.
    * `:endpoint_options` - options for `AudioFlow.VoiceInput.new/2`.
    * `:sample_rate` - input sample rate (16,000). With a detector, the rate
      must match the detector rate.
    * `:max_chunk_bytes` - largest binary input frame (64,000).
    * `:max_buffer_bytes` - largest committed utterance (960,000).

  ## Client messages

  A binary frame is mono signed 16-bit little-endian PCM at the input rate.
  It must contain whole samples. A text frame is a JSON object:

    * `{"type": "text", "text": "Hello"}` submits a typed message.
    * `{"type": "commit"}` submits collected input. With a detector, it ends
      the current utterance.
    * `{"type": "cancel"}` cancels the active reply.
    * `{"type": "clear_history"}` clears saved history while idle.

  ## Server messages

  A binary frame is mono s16le output PCM for the current turn. An
  `output_format` message with `sample_rate` comes before the first binary
  frame and before each change of sample rate. Other messages are JSON objects
  with a `type` field:

    * `ready` with the `input` format and `mode` (`"vad"` or `"commit"`)
    * `speech_started` when the detector confirms speech
    * `flush` when the client must discard queued playback
    * `turn_started`, `transcript`, `description`, `text`, `done`, and
      `cancelled`, each with the connection-local integer `turn`
    * `partial_transcript` with unstable `text`, when the STT adapter emits
      partial results. A `transcript` from a timed segment also has `start_ms`,
      `end_ms` and `words`
    * `history_cleared`
    * `error` with a `reason`, and a `turn` when a turn failed

  Graph node text events include a `node` field. Image and vector node outputs
  are not sent. After a cancellation, the connection drops output from the old
  turn.
  """
  @behaviour WebSock
  @behaviour AudioFlow.Output
  alias AudioFlow.Transport.Connection

  @impl AudioFlow.Output
  defdelegate start_turn(connection, key), to: Connection
  @impl AudioFlow.Output
  defdelegate push(connection, key, audio), to: Connection
  @impl AudioFlow.Output
  defdelegate finish(connection, key), to: Connection
  @impl AudioFlow.Output
  defdelegate flush(connection, key), to: Connection

  @impl WebSock
  def init(options), do: encode(Connection.init(options))

  @impl WebSock
  def handle_in({data, opcode: :binary}, state), do: encode(Connection.audio(data, state))

  def handle_in({data, opcode: :text}, state) do
    case JSON.decode(data) do
      {:ok, %{"type" => type} = message} ->
        encode(Connection.command(command(type, message), state))

      _ ->
        encode(Connection.command(:invalid, state))
    end
  end

  @impl WebSock
  def handle_info(message, state), do: encode(Connection.handle_info(message, state))

  @impl WebSock
  def terminate(reason, state), do: Connection.terminate(reason, state)

  defp command("text", %{"text" => text}), do: {:text, text}
  defp command("commit", _), do: :commit
  defp command("cancel", _), do: :cancel
  defp command("clear_history", _), do: :clear_history
  defp command(_, _), do: :invalid

  defp encode({:events, events, state}),
    do: {:push, Enum.map(events, &encode_event/1), state}

  defp encode(result), do: result
  defp encode_event({:event, message}), do: {:text, JSON.encode!(message)}
  defp encode_event({:audio, data}), do: {:binary, data}
end
