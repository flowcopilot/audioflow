defmodule AudioFlow.PlaybackPipeline do
  @moduledoc false
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, options) do
    spec =
      child(:source, %AudioFlow.PCMSource{
        playback: options.playback,
        id: options.id,
        sample_rate: options.rate,
        alignment_samples:
          if(is_struct(options.sink, Membrane.PortAudio.Sink),
            do: options.sink.portaudio_buffer_size,
            else: 1
          )
      })
      |> via_in(:input, target_queue_size: 1, min_demand_factor: 0, auto_demand_size: 1)
      |> child(:sink, options.sink)

    {[spec: spec], options}
  end

  @impl true
  def handle_child_notification(:end_of_turn, :source, _ctx, state) do
    if is_struct(state.sink, Membrane.PortAudio.Sink) do
      # Let the native ring play out before reporting the turn as drained.
      frames = state.sink.ringbuffer_size + state.sink.portaudio_buffer_size
      milliseconds = div(frames * 1000 + state.rate - 1, state.rate)
      Process.send_after(self(), :turn_drained, milliseconds)
    else
      send(state.playback, {:playback_drained, state.id})
    end

    {[], state}
  end

  def handle_child_notification(notification, child, _ctx, state) do
    send(state.playback, {:playback_notification, state.id, child, notification})
    {[], state}
  end

  @impl true
  def handle_info(:turn_drained, _ctx, state) do
    send(state.playback, {:playback_drained, state.id})
    {[], state}
  end
end
