defmodule AudioFlow.PCMSink do
  @moduledoc """
  Membrane ingress for mono s16le buffers.

  With `vad`, input buffers are audio chunks. Speech confirmation cancels
  the active turn and notifies the parent to flush playback. Endpoint detection
  submits a complete utterance. Without `vad`, each buffer is one utterance.
  Busy input is reported to the parent; it is not queued.
  """
  use Membrane.Sink

  def_options(
    session: [spec: pid()],
    vad: [spec: {module(), keyword()} | nil, default: nil],
    endpoint_options: [spec: keyword(), default: []]
  )

  def_input_pad(:input,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1},
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, options) do
    input = if options.vad, do: AudioFlow.VoiceInput.new(options.vad, options.endpoint_options)
    {[], %{session: options.session, rate: nil, input: input}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    if state.input && state.input.rate != format.sample_rate,
      do: raise(ArgumentError, "resample audio to #{state.input.rate} Hz before VAD")

    {[], %{state | rate: format.sample_rate}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    audio = %AudioFlow.Audio{data: buffer.payload, sample_rate: state.rate}

    if state.input do
      {events, input} = AudioFlow.VoiceInput.push(state.input, audio)
      {dispatch(events, state.session), %{state | input: input}}
    else
      {dispatch([{:utterance, audio, :buffer}], state.session), state}
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{input: nil} = state), do: {[], state}

  def handle_end_of_stream(:input, _ctx, state) do
    {events, input} = AudioFlow.VoiceInput.flush(state.input)
    {dispatch(events, state.session), %{state | input: input}}
  end

  defp dispatch(events, session) do
    Enum.map(events, fn
      :speech_started ->
        :ok = AudioFlow.cancel(session)
        {:notify_parent, {:audio_flow_speech_started, session}}

      {:utterance, audio, _reason} ->
        {:notify_parent, {:audio_flow_input, AudioFlow.submit(session, audio)}}
    end)
  end
end
