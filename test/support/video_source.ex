if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.Test.VideoSource do
    use Membrane.Source

    def_options(
      owner: [spec: pid()],
      frames: [spec: pos_integer(), default: 30],
      start_pts: [spec: integer(), default: 0]
    )

    def_output_pad(:output, flow_control: :manual, accepted_format: Membrane.RawVideo)

    @impl true
    def handle_init(_ctx, options),
      do:
        {[],
         %{owner: options.owner, count: options.frames, index: 0, start_pts: options.start_pts}}

    @impl true
    def handle_playing(_ctx, state),
      do:
        {[
           stream_format:
             {:output,
              %Membrane.RawVideo{
                width: 64,
                height: 48,
                framerate: {2, 1},
                pixel_format: :RGB,
                aligned: true
              }}
         ], state}

    @impl true
    def handle_demand(:output, _, _, _ctx, %{index: index, count: count} = state)
        when index >= count,
        do: {[end_of_stream: :output], state}

    def handle_demand(:output, _, _, _ctx, state) do
      send(state.owner, {:video_produced, self(), state.index})

      buffer = %Membrane.Buffer{
        payload: :binary.copy(<<state.index, 0, 0>>, 64 * 48),
        pts: state.start_pts + state.index * 500_000_000
      }

      {[buffer: {:output, buffer}, redemand: :output], %{state | index: state.index + 1}}
    end
  end
end
