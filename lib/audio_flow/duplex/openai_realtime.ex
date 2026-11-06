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
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio

  @rate 24_000
  @truncate "audioflow_truncate_"
  @statuses %{
    "completed" => :completed,
    "cancelled" => :cancelled,
    "incomplete" => :incomplete,
    "failed" => :failed
  }

  @impl true
  def config(options) do
    options =
      Keyword.validate!(options, [
        :model,
        :api_key,
        voice: "marin",
        instructions: "",
        transcription_model: "gpt-4o-mini-transcribe",
        endpoint: "wss://api.openai.com/v1/realtime"
      ])

    for key <- [:model, :voice, :transcription_model, :endpoint] do
      unless is_binary(options[key]) and options[key] != "",
        do: raise(ArgumentError, "#{key} must be a nonempty string")
    end

    unless is_binary(options[:instructions]),
      do: raise(ArgumentError, "instructions must be a string")

    api_key = options[:api_key]

    unless is_function(api_key, 0) or (is_binary(api_key) and api_key != ""),
      do: raise(ArgumentError, "api_key must be a nonempty string or a function")

    %{
      url: Socket.url(options[:endpoint], %{"model" => options[:model]}),
      headers: fn -> [{"authorization", "Bearer " <> Socket.key(api_key: api_key)}] end,
      sample_rate: @rate,
      input_flow: :realtime,
      options: Keyword.take(options, [:model, :voice, :instructions, :transcription_model])
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
      {:ok, %{"type" => type} = event} when is_binary(type) -> event(type, event, state)
      _ -> {:error, :invalid_event}
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

  defp event("session.created", _event, %{phase: :connecting} = state),
    do:
      {:ok, [], [json(%{type: "session.update", session: session(state.session)})],
       %{state | phase: :updating}}

  defp event("session.updated", _event, %{phase: :updating} = state),
    do: {:ok, [:ready], [], %{state | phase: :ready}}

  defp event("error", event, state) do
    error = if is_map(event["error"]), do: event["error"], else: %{}

    # A rejected truncation only leaves the provider history longer.
    if is_binary(error["event_id"]) and String.starts_with?(error["event_id"], @truncate),
      do: {:ok, [], [], state},
      else: {:error, {:remote_error, code(error)}}
  end

  defp event(_type, _event, %{phase: phase} = state) when phase != :ready,
    do: {:ok, [], [], state}

  defp event("input_audio_buffer.speech_started", %{"item_id" => item}, state)
       when is_binary(item) do
    state = %{state | dropped: state.response, cut: state.output || state.cut, output: nil}
    {:ok, [{:speech_started, item}], [], state}
  end

  defp event(
         "conversation.item.input_audio_transcription.completed",
         %{"item_id" => item, "transcript" => text},
         state
       )
       when is_binary(item) and is_binary(text),
       do: {:ok, [{:transcript, item, text}], [], state}

  defp event("conversation.item.input_audio_transcription.failed", %{"item_id" => item}, state)
       when is_binary(item),
       do: {:ok, [{:transcript, item, :failed}], [], state}

  defp event("response.created", %{"response" => %{"id" => id}}, state) when is_binary(id),
    do: {:ok, [{:response, id, :created}], [], %{state | response: id}}

  defp event("response.output_audio.delta", %{"response_id" => id}, %{dropped: id} = state),
    do: {:ok, [], [], state}

  defp event(
         "response.output_audio.delta",
         %{"item_id" => item, "delta" => delta} = event,
         state
       )
       when is_binary(item) and is_binary(delta) do
    case Base.decode64(delta) do
      {:ok, pcm} when rem(byte_size(pcm), 2) == 0 -> audio(pcm, item, event, state)
      _ -> {:error, :invalid_audio}
    end
  end

  defp event(type, %{"response_id" => id}, %{dropped: id} = state)
       when type in ["response.output_audio_transcript.delta", "response.output_text.delta"],
       do: {:ok, [], [], state}

  defp event(type, %{"delta" => text}, state)
       when type in ["response.output_audio_transcript.delta", "response.output_text.delta"] and
              is_binary(text),
       do: {:ok, [{:text, text}], [], state}

  defp event("response.done", %{"response" => %{"id" => id} = response}, state)
       when is_binary(id) do
    output = if is_list(response["output"]), do: response["output"], else: []

    cond do
      Enum.any?(output, &(is_map(&1) and &1["type"] == "function_call")) ->
        {:error, :unsupported_tool_call}

      status = @statuses[response["status"]] ->
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

  defp event(type, _event, _state)
       when type in [
              "input_audio_buffer.speech_started",
              "response.created",
              "response.output_audio.delta",
              "response.output_audio_transcript.delta",
              "response.output_text.delta",
              "response.done",
              "conversation.item.input_audio_transcription.completed",
              "conversation.item.input_audio_transcription.failed"
            ],
       do: {:error, :invalid_event}

  defp event(_type, _event, state), do: {:ok, [], [], state}

  defp audio(pcm, item, event, state) do
    {started, output} =
      case state.output do
        %{item: ^item} = output -> {[], output}
        _ -> {[{:output, item}], %{item: item, content_index: index(event), samples: 0}}
      end

    output = %{output | samples: output.samples + div(byte_size(pcm), 2)}
    audio = {:audio, %Audio{data: pcm, sample_rate: @rate}}
    {:ok, started ++ [audio], [], %{state | output: output}}
  end

  defp session(options) do
    %{
      type: "realtime",
      model: options[:model],
      output_modalities: ["audio"],
      instructions: options[:instructions],
      audio: %{
        input: %{
          format: %{type: "audio/pcm", rate: @rate},
          transcription: %{model: options[:transcription_model]},
          turn_detection: %{type: "server_vad", create_response: true, interrupt_response: true}
        },
        output: %{format: %{type: "audio/pcm", rate: @rate}, voice: options[:voice]}
      }
    }
  end

  defp index(%{"content_index" => index}) when is_integer(index) and index >= 0, do: index
  defp index(_event), do: 0

  # Only the short code or type: provider messages can quote request data.
  defp code(%{"code" => code}) when is_binary(code), do: String.slice(code, 0, 64)
  defp code(%{"type" => type}) when is_binary(type), do: String.slice(type, 0, 64)
  defp code(_error), do: "unknown"

  defp json(value), do: {:text, JSON.encode!(value)}
end
