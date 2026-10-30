defmodule AudioFlow.Input do
  @moduledoc "Membrane input chain with FFmpeg resampling and voice detection."
  import Membrane.ChildrenSpec

  @doc "Append a mono s16le resampler and session sink to an input source chain."
  def attach(source, session, options \\ []) do
    alias Membrane.FFmpeg.SWResample.Converter
    rate = Keyword.get(options, :sample_rate, 16_000)
    unless is_integer(rate) and rate > 0, do: raise(ArgumentError, "sample_rate must be positive")
    vad = Keyword.fetch!(options, :vad)

    unless match?({module, options} when is_atom(module) and is_list(options), vad),
      do: raise(ArgumentError, "streaming input requires a voice detector tuple")

    source
    |> child(:audio_flow_resampler, %Converter{
      output_stream_format: %Converter.OutputFormat{
        sample_rate: rate,
        channels: 1,
        sample_format: :s16le
      }
    })
    |> child(:audio_flow_input, %AudioFlow.PCMSink{
      session: session,
      vad: vad,
      endpoint_options: Keyword.get(options, :endpoint_options, [])
    })
  end
end
