defmodule AudioFlow.PCMFileSource do
  @moduledoc "Demand-driven raw PCM file source. The caller supplies the actual stream format."
  use Membrane.Source

  def_options(
    location: [spec: String.t()],
    stream_format: [spec: Membrane.RawAudio.t()],
    chunk_bytes: [spec: pos_integer(), default: 4096]
  )

  def_output_pad(:output, flow_control: :manual, accepted_format: Membrane.RawAudio)

  @impl true
  def handle_init(ctx, options) do
    frame_bytes = Membrane.RawAudio.frame_size(options.stream_format)

    unless options.chunk_bytes > 0 and rem(options.chunk_bytes, frame_bytes) == 0,
      do: raise(ArgumentError, "chunk_bytes must contain complete PCM frames")

    file = File.open!(options.location, [:read, :binary])
    Membrane.ResourceGuard.register(ctx.resource_guard, fn -> File.close(file) end)
    {[], %{file: file, options: options, frame_bytes: frame_bytes, position: 0}}
  end

  @impl true
  def handle_playing(_ctx, state),
    do: {[stream_format: {:output, state.options.stream_format}], state}

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, state) do
    case IO.binread(state.file, state.options.chunk_bytes) do
      :eof ->
        {[end_of_stream: :output], state}

      {:error, reason} ->
        raise "PCM read failed: #{inspect(reason)}"

      data ->
        unless rem(byte_size(data), state.frame_bytes) == 0,
          do: raise(ArgumentError, "file ends with an incomplete PCM frame")

        bytes_per_second = state.frame_bytes * state.options.stream_format.sample_rate
        pts = div(state.position * 1_000_000_000, bytes_per_second)
        buffer = %Membrane.Buffer{payload: data, pts: pts}

        {[buffer: {:output, buffer}, redemand: :output],
         %{state | position: state.position + byte_size(data)}}
    end
  end
end
