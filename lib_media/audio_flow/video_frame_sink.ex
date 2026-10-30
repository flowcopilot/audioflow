defmodule AudioFlow.VideoFrameSink do
  @moduledoc false
  use Membrane.Sink

  def_options(
    interval_ns: [spec: pos_integer()],
    max_frame_bytes: [spec: pos_integer()],
    normalize_timestamps?: [spec: boolean(), default: true]
  )

  def_input_pad(:input,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: %Membrane.RawVideo{pixel_format: :RGB, aligned: true}
  )

  @impl true
  def handle_init(_ctx, options),
    do:
      {[],
       %{
         options: options,
         format: nil,
         next_pts: nil,
         origin: nil,
         waiting?: false,
         playing?: false,
         eof?: false,
         error: nil
       }}

  @impl true
  def handle_playing(_ctx, state) do
    actions = if state.waiting?, do: [demand: {:input, 1}], else: []
    {actions, %{state | playing?: true}}
  end

  @impl true
  def handle_parent_notification(:next_frame, _ctx, state) do
    cond do
      state.error != nil -> {[notify_parent: {:frame_error, state.error}], state}
      state.eof? -> {[notify_parent: :frames_done], state}
      state.playing? -> {[demand: {:input, 1}], %{state | waiting?: true}}
      true -> {[], %{state | waiting?: true}}
    end
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    if format.width * format.height * 3 > state.options.max_frame_bytes,
      do: fail(state, :frame_too_large),
      else: {[], %{state | format: format}}
  end

  @impl true
  def handle_buffer(:input, _buffer, _ctx, %{error: error} = state) when error != nil,
    do: {[], state}

  def handle_buffer(:input, buffer, _ctx, state) do
    state =
      if state.origin == nil and is_integer(buffer.pts),
        do: %{state | origin: buffer.pts},
        else: state

    pts =
      if is_integer(buffer.pts) and state.options.normalize_timestamps?,
        do: buffer.pts - state.origin,
        else: buffer.pts

    cond do
      not is_integer(pts) ->
        fail(state, :missing_frame_timestamp)

      state.next_pts != nil and pts < state.next_pts ->
        {[demand: {:input, 1}], state}

      true ->
        image = %AudioFlow.Image{
          data: buffer.payload,
          width: state.format.width,
          height: state.format.height,
          pts: pts
        }

        if AudioFlow.Image.valid?(image) do
          {[notify_parent: {:frame, image}],
           %{state | waiting?: false, next_pts: pts + state.options.interval_ns}}
        else
          fail(state, :invalid_rgb_frame)
        end
    end
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state),
    do: {[notify_parent: :frames_done], %{state | eof?: true, waiting?: false}}

  defp fail(state, reason),
    do: {[notify_parent: {:frame_error, reason}], %{state | error: reason, waiting?: false}}
end
