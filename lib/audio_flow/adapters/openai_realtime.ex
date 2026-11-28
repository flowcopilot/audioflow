defmodule AudioFlow.Adapters.OpenAIRealtime do
  @moduledoc """
  One committed audio turn over OpenAI's GA Realtime WebSocket protocol.
  `run/3` emits `{:transcript, text}`, `{:text, delta}`, `{:audio, Audio}`.
  Use directly or in Session `:speech_to_speech`, never an STT/LLM/TTS slot.

  The turn ends when the response is done and the input transcript has
  arrived. OpenAI sends the transcript on its own schedule. If it has not
  arrived `:transcript_grace_ms` (default 3000) after `response.done`, the turn
  fails with `:transcript_timeout`.

  See
  https://flowcopilot.github.io/audioflow/docs/features/providers/
  for options and integration limits.
  """
  @behaviour AudioFlow.Adapter
  alias AudioFlow.Adapters.Options
  alias AudioFlow.Adapters.Providers.OpenAIRealtime, as: Protocol
  alias AudioFlow.Adapters.Providers.Socket
  alias AudioFlow.Audio

  @impl true
  def validate_options(options) do
    Protocol.validate_options!(options)
    Options.positive!(options, :transcript_grace_ms, 3_000)
    Socket.validate_options!(options)
  end

  @impl true
  def run(audio, options, emit) do
    :ok = validate_options(options)
    Socket.audio!(audio, Protocol.rate())
    grace = Keyword.get(options, :transcript_grace_ms, 3_000)

    input = [
      Socket.json(%{type: "input_audio_buffer.append", audio: Base.encode64(audio.data)}),
      Socket.json(%{type: "input_audio_buffer.commit"}),
      Socket.json(%{type: "response.create"})
    ]

    url =
      Socket.url(Keyword.get(options, :endpoint, Protocol.endpoint()), %{
        "model" => options[:model]
      })

    Socket.run(
      url,
      [{"authorization", "Bearer " <> Socket.key(options)}],
      [Socket.json(%{type: "session.update", session: Protocol.session(options, nil)})],
      %{sent: false, response: false, transcript: false},
      &event(Protocol.decode(&1), &2, input, emit, grace),
      options
    )
  end

  defp event(:session_updated, %{sent: false} = state, input, _emit, _grace),
    do: {:cont, %{state | sent: true}, input}

  defp event({:remote_error, _error}, _state, _input, _emit, _grace), do: {:error, :remote_error}

  defp event({:transcript_failed, _item}, _state, _input, _emit, _grace),
    do: {:error, :transcription_failed}

  defp event({:transcript, _item, text}, state, _input, emit, grace) do
    :ok = emit.({:transcript, text})
    finish(%{state | transcript: true}, grace)
  end

  defp event({:audio, %{pcm: pcm}}, state, _input, emit, _grace) do
    :ok = emit.({:audio, %Audio{data: pcm, sample_rate: Protocol.rate()}})
    {:cont, state, []}
  end

  defp event(:invalid_audio, _state, _input, _emit, _grace), do: {:error, :invalid_audio}

  defp event({:text, _response, text}, state, _input, emit, _grace) do
    :ok = emit.({:text, text})
    {:cont, state, []}
  end

  defp event({:response_done, %{tool_call?: true}}, _state, _input, _emit, _grace),
    do: {:error, :unsupported_tool_call}

  defp event({:response_done, %{status: :completed}}, state, _input, _emit, grace),
    do: finish(%{state | response: true}, grace)

  defp event({:response_done, _response}, _state, _input, _emit, _grace),
    do: {:error, :response_failed}

  defp event({:invalid, _type}, _state, _input, _emit, _grace), do: {:error, :invalid_event}
  defp event(_ignored, state, _input, _emit, _grace), do: {:cont, state, []}

  # Without a transcript, the response is complete but the turn waits for it, for
  # the grace time at most.
  defp finish(%{response: true, transcript: true}, _grace), do: :done

  defp finish(%{response: true} = state, grace),
    do: {:wait, state, [], grace, :transcript_timeout}

  defp finish(state, _grace), do: {:cont, state, []}
end
