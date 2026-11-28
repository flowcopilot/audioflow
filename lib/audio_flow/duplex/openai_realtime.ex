defmodule AudioFlow.Duplex.OpenAIRealtime do
  @moduledoc """
  `AudioFlow.Duplex` adapter for one continuous OpenAI Realtime conversation
  over the GA WebSocket protocol. Needs no media dependencies.

  The adapter sends `session.update` after `session.created` and emits `:ready`
  after `session.updated`. Input is mono s16le PCM at 24 kHz; each push becomes
  one `input_audio_buffer.append`. OpenAI server VAD detects speech, commits each
  utterance and creates the reply (`create_response`). New speech cancels the
  current reply (`interrupt_response`). The adapter never commits input or
  creates replies itself. The provider conversation keeps every utterance of
  one connection; a new connection starts a new conversation.

  Events: `{:speech_started, item}`, `{:transcript, item, text | :failed}`,
  `{:response, id, status}`, `{:output, item}`, `{:audio, audio}` and
  `{:text, delta}` (assistant audio transcript or text). After
  `{:speech_started, _}`, late audio and text of the interrupted reply are
  dropped.

  Control `{:played, item, ms}` reports how much audio of the interrupted reply
  `item` played before the owner flushed it. If that is less than the audio
  received for `item`, the adapter sends `conversation.item.truncate` with
  `audio_end_ms` capped to the received audio, so the provider history keeps
  only the played part. Only the last interrupted reply is accepted, once;
  anything else returns `{:error, :stale}`.

  Fatal reasons: `{:remote_error, code}` (provider `error` event, except for a
  rejected truncation), `:unsupported_tool_call` (no tools are configured),
  `:invalid_audio` and `:invalid_event`.

  Options: `:model` (required), `:api_key` (required; a function is resolved
  only to connect), `:voice` (`"marin"`), `:instructions` (`""`),
  `:transcription_model` (`"gpt-4o-mini-transcribe"`) and `:endpoint`
  (`"wss://api.openai.com/v1/realtime"`).
  """
  @behaviour AudioFlow.Duplex.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.OpenAIRealtime, as: Protocol
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio

  @rate Protocol.rate()
  @truncate "audioflow_truncate_"
  @turn_detection %{type: "server_vad", create_response: true, interrupt_response: true}
  @allowed [:model, :api_key, :voice, :instructions, :transcription_model, :endpoint]

  @impl true
  def config(options) do
    options |> Options.keyword!() |> Options.known!(@allowed)
    Protocol.validate_options!(options)
    api_key = options[:api_key]

    %{
      url:
        Socket.url(Keyword.get(options, :endpoint, Protocol.endpoint()), %{
          "model" => options[:model]
        }),
      headers: fn -> [{"authorization", "Bearer " <> Socket.key(api_key: api_key)}] end,
      sample_rate: @rate,
      input_flow: :realtime,
      options:
        Keyword.merge(
          [voice: "marin", instructions: "", transcription_model: "gpt-4o-mini-transcribe"],
          Keyword.take(options, [:model, :voice, :instructions, :transcription_model])
        )
    }
  end

  @impl true
  def init(options) do
    %{
      session: options,
      phase: :connecting,
      response: nil,
      dropped: nil,
      output: nil,
      cut: nil,
      truncates: 0
    }
  end

  @impl true
  def handle_frame({:text, data}, state) do
    case JSON.decode(data) do
      {:ok, %{"type" => type} = event} when is_binary(type) ->
        event(Protocol.decode(event), state)

      _ ->
        {:error, :invalid_event}
    end
  end

  def handle_frame(_frame, _state), do: {:error, :invalid_event}

  @impl true
  def handle_audio(%Audio{data: data}, state),
    do: {:ok, [json(%{type: "input_audio_buffer.append", audio: Base.encode64(data)})], state}

  @impl true
  def handle_control({:played, item, ms}, %{cut: %{item: item} = cut} = state)
      when is_binary(item) and is_integer(ms) and ms >= 0 do
    received = div(cut.samples * 1000, @rate)
    state = %{state | cut: nil}

    if ms < received do
      count = state.truncates + 1

      truncate = %{
        type: "conversation.item.truncate",
        event_id: @truncate <> Integer.to_string(count),
        item_id: item,
        content_index: cut.content_index,
        audio_end_ms: ms
      }

      {:ok, [json(truncate)], %{state | truncates: count}}
    else
      {:ok, [], state}
    end
  end

  def handle_control({:played, item, ms}, _state)
      when is_binary(item) and is_integer(ms) and ms >= 0,
      do: {:error, :stale}

  def handle_control(_command, _state), do: {:error, :invalid_command}

  defp event(:session_created, %{phase: :connecting} = state),
    do:
      {:ok, [], [json(%{type: "session.update", session: session(state.session)})],
       %{state | phase: :updating}}

  defp event(:session_updated, %{phase: :updating} = state),
    do: {:ok, [:ready], [], %{state | phase: :ready}}

  defp event({:remote_error, error}, state) do
    # A rejected truncation only leaves the provider history longer.
    if is_binary(error["event_id"]) and String.starts_with?(error["event_id"], @truncate),
      do: {:ok, [], [], state},
      else: {:error, {:remote_error, code(error)}}
  end

  defp event(_decoded, %{phase: phase} = state) when phase != :ready,
    do: {:ok, [], [], state}

  defp event({:speech_started, item}, state) do
    state = %{state | dropped: state.response, cut: state.output || state.cut, output: nil}
    {:ok, [{:speech_started, item}], [], state}
  end

  defp event({:transcript, item, text}, state) when is_binary(item),
    do: {:ok, [{:transcript, item, text}], [], state}

  defp event({:transcript_failed, item}, state) when is_binary(item),
    do: {:ok, [{:transcript, item, :failed}], [], state}

  defp event({:response_created, id}, state),
    do: {:ok, [{:response, id, :created}], [], %{state | response: id}}

  defp event({:audio, %{response_id: id}}, %{dropped: id} = state) when is_binary(id),
    do: {:ok, [], [], state}

  defp event({:audio, %{item_id: item} = audio}, state) when is_binary(item),
    do: audio(audio.pcm, item, audio.content_index, state)

  defp event(:invalid_audio, _state), do: {:error, :invalid_audio}

  defp event({:text, id, _text}, %{dropped: id} = state) when is_binary(id),
    do: {:ok, [], [], state}

  defp event({:text, _response, text}, state), do: {:ok, [{:text, text}], [], state}

  defp event({:response_done, %{id: id, tool_call?: tool_call?, status: status}}, state)
       when is_binary(id) do
    cond do
      tool_call? ->
        {:error, :unsupported_tool_call}

      status != nil ->
        state = %{
          state
          | response: if(state.response == id, do: nil, else: state.response),
            dropped: if(state.dropped == id, do: nil, else: state.dropped)
        }

        {:ok, [{:response, id, status}], [], state}

      true ->
        {:error, :invalid_event}
    end
  end

  # A missing id, or a known event type with missing fields.
  defp event({kind, _}, _state) when kind in [:audio, :transcript_failed, :invalid],
    do: {:error, :invalid_event}

  defp event({kind, _, _}, _state) when kind in [:transcript], do: {:error, :invalid_event}
  defp event({:response_done, _response}, _state), do: {:error, :invalid_event}
  defp event(_ignored, state), do: {:ok, [], [], state}

  defp audio(pcm, item, content_index, state) do
    {started, output} =
      case state.output do
        %{item: ^item} = output -> {[], output}
        _ -> {[{:output, item}], %{item: item, content_index: content_index, samples: 0}}
      end

    output = %{output | samples: output.samples + div(byte_size(pcm), 2)}
    audio = {:audio, %Audio{data: pcm, sample_rate: @rate}}
    {:ok, started ++ [audio], [], %{state | output: output}}
  end

  defp session(options), do: Protocol.session(options, @turn_detection)

  # Only the short code or type: provider messages can quote request data.
  defp code(%{"code" => code}) when is_binary(code), do: String.slice(code, 0, 64)
  defp code(%{"type" => type}) when is_binary(type), do: String.slice(type, 0, 64)
  defp code(_error), do: "unknown"

  defp json(value), do: {:text, JSON.encode!(value)}
end
