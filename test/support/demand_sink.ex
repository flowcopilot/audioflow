if System.get_env("AUDIOFLOW_MEDIA") == "1" do
  defmodule AudioFlow.Test.DemandSink do
    @moduledoc false
    use Membrane.Sink
    def_options(owner: [spec: pid()])

    def_input_pad(:input,
      flow_control: :manual,
      demand_unit: :buffers,
      accepted_format: %Membrane.RawAudio{channels: 1, sample_format: :s16le}
    )

    def handle_init(_ctx, options), do: {[], options}

    def handle_playing(_ctx, state) do
      send(state.owner, {:sink_ready, self()})
      {[], state}
    end

    def handle_info({:demand, count}, _ctx, state), do: {[demand: {:input, count}], state}
    def handle_info(:crash, _ctx, _state), do: exit(:device_error)

    def handle_buffer(:input, buffer, _ctx, state) do
      send(state.owner, {:played, self(), buffer})
      {[], state}
    end
  end
end
