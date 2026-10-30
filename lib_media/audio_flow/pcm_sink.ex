defmodule AudioFlow.PCMSink do
  @moduledoc """
  Membrane ingress for utterance-aligned mono s16le buffers.

  Put resampling and VAD/utterance framing before this sink. Each buffer is
  one complete utterance. Busy input is reported to the parent for routing
  or retry; it is not stored in an unbounded queue.
  """
  use Membrane.Sink

  def_options(session: [spec: pid()])

  def_input_pad(:input,
    accepted_format: %Membrane.RawAudio{sample_format: :s16le, channels: 1},
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, options), do: {[], %{session: options.session, rate: nil}}

  @impl true
  def handle_stream_format(:input, format, _ctx, state),
    do: {[], %{state | rate: format.sample_rate}}

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    audio = %AudioFlow.Audio{data: buffer.payload, sample_rate: state.rate}
    result = AudioFlow.submit(state.session, audio)
    {[notify_parent: {:audio_flow_input, result}], state}
  end
end
