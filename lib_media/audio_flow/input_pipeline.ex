defmodule AudioFlow.InputPipeline do
  @moduledoc """
  Input source → FFmpeg resampler → voice detector → session.

  Options: `:source`, `:session`, `:vad`, `:endpoint_options`, `:sample_rate`
  (16,000), and `:observer` (caller). A source can be `PCMFileSource` or a
  PortAudio microphone. Notifications are sent as
  `{AudioFlow.InputPipeline, pipeline_pid, notification}`. The pipeline stops
  at input EOS; its session and output drain independently.
  """
  use Membrane.Pipeline

  def start_link(options),
    do: Membrane.Pipeline.start_link(__MODULE__, Keyword.put_new(options, :observer, self()))

  @impl true
  def handle_init(_ctx, options) do
    session = Keyword.fetch!(options, :session)
    source = child(:source, Keyword.fetch!(options, :source))
    spec = AudioFlow.Input.attach(source, session, options)
    {[spec: spec], %{observer: Keyword.fetch!(options, :observer)}}
  end

  @impl true
  def handle_child_notification(notification, _child, _ctx, state) do
    send(state.observer, {__MODULE__, self(), notification})
    {[], state}
  end

  @impl true
  def handle_element_end_of_stream(:audio_flow_input, :input, _ctx, state) do
    send(state.observer, {__MODULE__, self(), :end_of_stream})
    {[terminate: :normal], state}
  end

  def handle_element_end_of_stream(_child, _pad, _ctx, state), do: {[], state}
end
