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

    session = %{
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
      [Socket.json(%{type: "session.update", session: session})],
      %{sent: false, response: false, transcript: false},
      fn event, state ->
        case event do
          %{"type" => "session.updated"} when not state.sent ->
            {:cont, %{state | sent: true}, input}

          %{"type" => "error"} ->
            {:error, :remote_error}

          %{"type" => "conversation.item.input_audio_transcription.failed"} ->
            {:error, :transcription_failed}

          %{
            "type" => "conversation.item.input_audio_transcription.completed",
            "transcript" => text
          }
          when is_binary(text) ->
            :ok = emit.({:transcript, text})
            finish(%{state | transcript: true})

          %{"type" => "response.output_audio.delta", "delta" => data} when is_binary(data) ->
            case Socket.audio_event(data, 24_000, emit) do
              :ok -> {:cont, state, []}
              error -> error
            end

          %{"type" => type, "delta" => text}
          when type in ["response.output_audio_transcript.delta", "response.output_text.delta"] and
                 is_binary(text) ->
            :ok = emit.({:text, text})
            {:cont, state, []}

          %{
            "type" => "response.done",
            "response" => %{"status" => "completed", "output" => output}
          } ->
            if Enum.any?(output, &(&1["type"] == "function_call")),
              do: {:error, :unsupported_tool_call},
              else: finish(%{state | response: true})

          %{"type" => "response.done"} ->
            {:error, :response_failed}

          %{"type" => _} ->
            {:cont, state, []}

          _ ->
            {:error, :invalid_event}
        end
      end,
      options
    )
  end

  defp finish(%{response: true, transcript: true}), do: :done
  defp finish(state), do: {:cont, state, []}
end
