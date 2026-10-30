defmodule AudioFlow.PCMSource do
  @moduledoc "Demand-driven PCM output from an AudioFlow.Playback queue."
  use Membrane.Source

  def_options(
    playback: [spec: pid()],
    key: [spec: AudioFlow.Output.key()],
    sample_rate: [spec: pos_integer()],
    alignment_samples: [spec: pos_integer(), default: 1]
  )

  def_output_pad(:output,
    flow_control: :manual,
    accepted_format: %Membrane.RawAudio{channels: 1, sample_format: :s16le}
  )

  @impl true
  def handle_init(_ctx, options),
    do: {[], %{options: options, request: nil, position: 0, samples_sent: 0}}

  @impl true
  def handle_playing(_ctx, state) do
    format = %Membrane.RawAudio{
      channels: 1,
      sample_format: :s16le,
      sample_rate: state.options.sample_rate
    }

    {[stream_format: {:output, format}], state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, %{request: nil} = state) do
    request = make_ref()
    send(state.options.playback, {:take_pcm, state.options.key, self(), request})
    {[], %{state | request: request}}
  end

  def handle_demand(:output, _size, _unit, _ctx, state), do: {[], state}

  @impl true
  def handle_info({:pcm, request, %AudioFlow.Audio{} = audio}, _ctx, %{request: request} = state) do
    samples = state.samples_sent + div(byte_size(audio.data), 2)
    position = div(samples * 1_000_000_000, audio.sample_rate)
    buffer = %Membrane.Buffer{payload: audio.data, pts: state.position}

    {[buffer: {:output, buffer}, redemand: :output],
     %{state | request: nil, position: position, samples_sent: samples}}
  end

  def handle_info({:pcm, request, :end_of_stream}, _ctx, %{request: request} = state) do
    # PortAudio's callback only consumes complete device buffers.
    remainder = rem(state.samples_sent, state.options.alignment_samples)
    padding = if remainder == 0, do: 0, else: state.options.alignment_samples - remainder

    actions =
      if padding == 0,
        do: [],
        else: [
          buffer:
            {:output,
             %Membrane.Buffer{payload: :binary.copy(<<0, 0>>, padding), pts: state.position}}
        ]

    {actions ++ [end_of_stream: :output], %{state | request: nil}}
  end

  def handle_info(_message, _ctx, state), do: {[], state}
end
