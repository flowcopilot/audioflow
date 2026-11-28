defmodule AudioFlow.Adapters.Providers.OpenAIRealtime do
  @moduledoc false
  # The OpenAI Realtime GA protocol, shared by the per-turn adapter
  # (`AudioFlow.Adapters.OpenAIRealtime`) and the continuous one
  # (`AudioFlow.Duplex.OpenAIRealtime`). This module builds the session
  # configuration and decodes server events into tagged tuples. Each adapter
  # keeps its own flow control and its own strictness about missing ids.
  alias AudioFlow.Adapters.Options

  @rate 24_000
  @endpoint "wss://api.openai.com/v1/realtime"
  @statuses %{
    "completed" => :completed,
    "cancelled" => :cancelled,
    "incomplete" => :incomplete,
    "failed" => :failed
  }

  def rate, do: @rate
  def endpoint, do: @endpoint

  @doc "Checks the options that both adapters share. Raises `ArgumentError`."
  def validate_options!(options) do
    Options.string!(options, :model)
    Options.api_key!(options)

    for key <- [:voice, :transcription_model, :endpoint],
        do: Options.optional_string!(options, key)

    Options.text!(options, :instructions)
    :ok
  end

  @doc """
  The `session` object of `session.update`. `turn_detection` is `nil` for
  committed turns, or the server VAD settings for a continuous conversation.
  """
  def session(options, turn_detection) do
    %{
      type: "realtime",
      model: Keyword.fetch!(options, :model),
      output_modalities: ["audio"],
      instructions: Keyword.get(options, :instructions, ""),
      audio: %{
        input: %{
          format: %{type: "audio/pcm", rate: @rate},
          turn_detection: turn_detection,
          transcription: %{
            model: Keyword.get(options, :transcription_model, "gpt-4o-mini-transcribe")
          }
        },
        output: %{
          format: %{type: "audio/pcm", rate: @rate},
          voice: Keyword.get(options, :voice, "marin")
        }
      }
    }
  end

  @doc """
  Decodes one server event (a JSON object). Ids can be `nil`; the caller decides
  whether it needs them.

    * `:session_created`, `:session_updated`
    * `{:remote_error, error}` with the provider error object (a map)
    * `{:speech_started, item}`
    * `{:transcript, item | nil, text}` and `{:transcript_failed, item | nil}`
    * `{:response_created, id}`
    * `{:audio, %{response_id, item_id, content_index, pcm}}`
    * `{:text, response_id, text}`: assistant audio transcript or text delta
    * `{:response_done, %{id, status, tool_call?}}`, `status` is `nil` when unknown
    * `:invalid_audio` for a delta that is not whole 16-bit samples in base64
    * `{:invalid, type}` for a known event type with missing or mistyped fields
    * `:ignored` for every other type
  """
  def decode(%{"type" => type} = event) when is_binary(type), do: decode(type, event)
  def decode(_event), do: {:invalid, nil}

  defp decode("session.created", _event), do: :session_created
  defp decode("session.updated", _event), do: :session_updated

  defp decode("error", event),
    do: {:remote_error, if(is_map(event["error"]), do: event["error"], else: %{})}

  defp decode("input_audio_buffer.speech_started", %{"item_id" => item}) when is_binary(item),
    do: {:speech_started, item}

  defp decode(
         "conversation.item.input_audio_transcription.completed",
         %{"transcript" => text} = event
       )
       when is_binary(text),
       do: {:transcript, binary(event["item_id"]), text}

  defp decode("conversation.item.input_audio_transcription.failed", event),
    do: {:transcript_failed, binary(event["item_id"])}

  defp decode("response.created", %{"response" => %{"id" => id}}) when is_binary(id),
    do: {:response_created, id}

  defp decode("response.output_audio.delta", %{"delta" => delta} = event)
       when is_binary(delta) do
    case Base.decode64(delta) do
      {:ok, pcm} when rem(byte_size(pcm), 2) == 0 ->
        {:audio,
         %{
           response_id: binary(event["response_id"]),
           item_id: binary(event["item_id"]),
           content_index: content_index(event),
           pcm: pcm
         }}

      _ ->
        :invalid_audio
    end
  end

  defp decode(type, %{"delta" => text} = event)
       when type in ["response.output_audio_transcript.delta", "response.output_text.delta"] and
              is_binary(text),
       do: {:text, binary(event["response_id"]), text}

  defp decode("response.done", %{"response" => response}) when is_map(response) do
    output = if is_list(response["output"]), do: response["output"], else: []

    {:response_done,
     %{
       id: binary(response["id"]),
       status: @statuses[response["status"]],
       tool_call?: Enum.any?(output, &(is_map(&1) and &1["type"] == "function_call"))
     }}
  end

  defp decode(type, _event)
       when type in [
              "input_audio_buffer.speech_started",
              "conversation.item.input_audio_transcription.completed",
              "response.created",
              "response.output_audio.delta",
              "response.output_audio_transcript.delta",
              "response.output_text.delta",
              "response.done"
            ],
       do: {:invalid, type}

  defp decode(_type, _event), do: :ignored

  defp binary(value) when is_binary(value), do: value
  defp binary(_value), do: nil

  defp content_index(%{"content_index" => index}) when is_integer(index) and index >= 0, do: index
  defp content_index(_event), do: 0
end
