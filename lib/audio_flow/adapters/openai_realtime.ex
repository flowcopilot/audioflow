defmodule AudioFlow.Adapters.OpenAIRealtime do
  @moduledoc """
  One committed audio turn over OpenAI's GA Realtime WebSocket protocol.
  `run/3` emits `{:transcript, text}`, `{:text, delta}`, `{:audio, Audio}`.
  Use directly or in Session `:speech_to_speech`, never an STT/LLM/TTS slot.
  See docs/providers.md for options and integration limits.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Providers.Socket

  def run(audio, options, emit) do
    Socket.audio!(audio, 24_000)

    input = [
      Socket.json(%{type: "input_audio_buffer.append", audio: Base.encode64(audio.data)}),
      Socket.json(%{type: "input_audio_buffer.commit"}),
      Socket.json(%{type: "response.create"})
    ]

    url =
      Socket.url(Keyword.get(options, :endpoint, "wss://api.openai.com/v1/realtime"), %{
        "model" => options[:model]
      })

    Socket.run(
      url,
      [{"authorization", "Bearer " <> Socket.key(options)}],
      [Socket.json(%{type: "session.update", session: session(options)})],
      %{sent: false, response: false, transcript: false},
      &event(&1, &2, input, emit),
      options
    )
  end

  defp session(options) do
    %{
      type: "realtime",
      model: Keyword.fetch!(options, :model),
      output_modalities: ["audio"],
      instructions: Keyword.get(options, :instructions, ""),
      audio: %{
        input: %{
          format: %{type: "audio/pcm", rate: 24_000},
          turn_detection: nil,
          transcription: %{
            model: Keyword.get(options, :transcription_model, "gpt-4o-mini-transcribe")
          }
        },
        output: %{
          format: %{type: "audio/pcm", rate: 24_000},
          voice: Keyword.get(options, :voice, "marin")
        }
      }
    }
  end

  defp event(%{"type" => "session.updated"}, state, input, _emit) when not state.sent,
    do: {:cont, %{state | sent: true}, input}

  defp event(%{"type" => "error"}, _state, _input, _emit), do: {:error, :remote_error}

  defp event(%{"type" => "conversation.item.input_audio_transcription.failed"}, _, _, _),
    do: {:error, :transcription_failed}

  defp event(
         %{
           "type" => "conversation.item.input_audio_transcription.completed",
           "transcript" => text
         },
         state,
         _input,
         emit
       )
       when is_binary(text) do
    :ok = emit.({:transcript, text})
    finish(%{state | transcript: true})
  end

  defp event(%{"type" => "response.output_audio.delta", "delta" => data}, state, _input, emit)
       when is_binary(data) do
    case Socket.audio_event(data, 24_000, emit) do
      :ok -> {:cont, state, []}
      error -> error
    end
  end

  defp event(%{"type" => type, "delta" => text}, state, _input, emit)
       when type in ["response.output_audio_transcript.delta", "response.output_text.delta"] and
              is_binary(text) do
    :ok = emit.({:text, text})
    {:cont, state, []}
  end

  defp event(
         %{
           "type" => "response.done",
           "response" => %{"status" => "completed", "output" => output}
         },
         state,
         _input,
         _emit
       ) do
    if Enum.any?(output, &(&1["type"] == "function_call")),
      do: {:error, :unsupported_tool_call},
      else: finish(%{state | response: true})
  end

  defp event(%{"type" => "response.done"}, _state, _input, _emit), do: {:error, :response_failed}
  defp event(%{"type" => _}, state, _input, _emit), do: {:cont, state, []}
  defp event(_event, _state, _input, _emit), do: {:error, :invalid_event}

  defp finish(%{response: true, transcript: true}), do: :done
  defp finish(state), do: {:cont, state, []}
end
