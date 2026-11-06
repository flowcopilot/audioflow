defmodule AudioFlow.RTVI.WebSocket do
  @moduledoc """
  RTVI 2.x control-message subset over WebSock: client-ready, send-text,
  llm-raw-text, bot-tts-audio, bot-interrupted, and errors. This endpoint is
  for custom transports; it does not implement Daily/LiveKit signaling or
  Pipecat's protobuf WebSocket media framing. See `docs/transports.md`.
  """
  @behaviour WebSock
  alias AudioFlow.Transport.Connection

  @impl true
  def init(options) do
    case Connection.init(options) do
      {:events, _ready, pcm} -> {:ok, %{pcm: pcm, ready: false, rate: nil, request: nil}}
      other -> other
    end
  end

  @impl true
  def handle_in({data, opcode: :text}, state) when byte_size(data) <= 64_000 do
    case JSON.decode(data) do
      {:ok, %{"label" => "rtvi-ai", "id" => id, "type" => type} = message}
      when is_binary(id) and is_binary(type) ->
        command(type, message, state)

      _ ->
        error(nil, "Invalid RTVI envelope", state)
    end
  end

  def handle_in(_, state), do: error(nil, "Only RTVI JSON control messages are supported", state)

  defp command(
         "client-ready",
         %{"id" => id, "data" => %{"version" => version, "about" => %{"library" => library}}},
         state
       )
       when is_binary(version) and is_binary(library) do
    if Regex.match?(~r/^2\.[0-9]+\.[0-9]+$/, version) do
      {:push,
       [
         json(
           "bot-ready",
           %{version: "2.0.0", about: %{library: "audio_flow", library_version: "0.1.0"}},
           id
         )
       ], %{state | ready: true}}
    else
      error(id, "Supported RTVI major version: 2", state)
    end
  end

  defp command(
         "send-text",
         %{"id" => id, "data" => %{"content" => content} = data},
         %{ready: true} = state
       )
       when is_binary(content) do
    options = Map.get(data, "options") || %{}

    if is_map(options) and Map.get(options, "run_immediately", true) == true and
         Map.get(options, "audio_response", true) == true and
         Map.keys(options) -- ["run_immediately", "audio_response"] == [] do
      # RTVI run_immediately interrupts the current response before submitting.
      case Connection.command(:cancel, state.pcm)
           |> translate(state) do
        {:ok, state} -> submit(content, id, state, [])
        {:push, frames, state} -> submit(content, id, state, frames)
      end
    else
      error(id, "Only immediate text with audio response is supported", state)
    end
  end

  defp command(_, %{"id" => id}, state),
    do: error(id, "Unsupported message, invalid data, or client not ready", state)

  defp submit(content, id, state, frames) do
    case translate(
           Connection.command({:text, content}, state.pcm),
           %{state | request: id}
         ) do
      {:ok, state} -> reply(frames, state)
      {:push, new, state} -> reply(frames ++ new, state)
    end
  end

  @impl true
  def handle_info(message, state),
    do: translate(Connection.handle_info(message, state.pcm), state)

  @impl true
  def terminate(reason, state), do: Connection.terminate(reason, state.pcm)

  defp translate({:ok, pcm}, state), do: {:ok, %{state | pcm: pcm}}

  defp translate({:stop, reason, close, pcm}, state),
    do: {:stop, reason, close, %{state | pcm: pcm}}

  defp translate({:events, frames, pcm}, state) do
    {frames, state} =
      Enum.reduce(frames, {[], %{state | pcm: pcm}}, fn frame, {frames, state} ->
        {new, state} = outgoing(frame, state)
        {frames ++ new, state}
      end)

    reply(frames, state)
  end

  # Keep custom media events below the SDK transport's 64 KB message bound.
  defp outgoing({:audio, data}, state) do
    frames =
      for chunk <- audio_chunks(data),
          do:
            json("bot-tts-audio", %{
              audio: Base.encode64(chunk),
              sample_rate: state.rate,
              num_channels: 1
            })

    {frames, state}
  end

  defp outgoing({:event, message}, state) do
    case message do
      %{type: :output_format, sample_rate: rate} ->
        {[], %{state | rate: rate}}

      %{type: :text, text: text} ->
        {[json("llm-raw-text", %{text: text})], state}

      %{type: :flush} ->
        {[json("bot-interrupted", nil)], state}

      %{type: :error, reason: reason} = message when not is_map_key(message, :turn) ->
        {[json("error-response", %{error: reason}, state.request || "")], state}

      %{type: :error, reason: reason} ->
        {[json("error", %{error: reason, fatal: false})], state}

      _ ->
        {[], state}
    end
  end

  defp audio_chunks(<<>>), do: []
  defp audio_chunks(data) when byte_size(data) <= 24_000, do: [data]

  defp audio_chunks(<<chunk::binary-size(24_000), rest::binary>>),
    do: [chunk | audio_chunks(rest)]

  defp error(id, reason, state),
    do: {:push, [json("error-response", %{error: reason}, id || "")], state}

  defp json(type, data, id \\ nil) do
    message = %{label: "rtvi-ai", type: type}
    message = if data, do: Map.put(message, :data, data), else: message
    message = if id, do: Map.put(message, :id, id), else: message
    {:text, JSON.encode!(message)}
  end

  defp reply([], state), do: {:ok, state}
  defp reply(frames, state), do: {:push, frames, state}
end
