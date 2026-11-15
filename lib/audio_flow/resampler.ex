defmodule AudioFlow.Resampler do
  @moduledoc """
  Converts mono s16le PCM to another sample rate with FFmpeg's libswresample,
  through `Membrane.FFmpeg.SWResample.Converter.Native`.

  `convert/2` converts complete audio. For a stream, keep the state from
  `new/2`, call `push/2` for each chunk and `flush/1` at the end. The converter
  holds a few milliseconds of audio until the flush, so the chunks of a stream
  join to the same samples as one conversion of the whole input.

  The state is a native handle. Use it from one process, and do not push to it
  after a flush.
  """
  alias AudioFlow.Audio
  alias Membrane.FFmpeg.SWResample.Converter.Native

  @format Membrane.RawAudio.SampleFormat.serialize(:s16le)

  def convert(%Audio{sample_rate: rate} = audio, rate), do: audio

  def convert(%Audio{} = audio, rate) when is_integer(rate) and rate > 0 do
    unless Audio.valid?(audio), do: raise(ArgumentError, "expected mono s16le PCM")
    state = new(audio.sample_rate, rate)
    data = push(state, audio.data) <> flush(state)
    # The flush can round the length up by one sample.
    size = div(div(byte_size(audio.data), 2) * rate, audio.sample_rate) * 2
    %Audio{data: binary_part(data, 0, min(size, byte_size(data))), sample_rate: rate}
  end

  @doc "Starts a stream conversion between two sample rates."
  def new(from, to) when is_integer(from) and from > 0 and is_integer(to) and to > 0 do
    {:ok, state} = Native.create(@format, from, 1, @format, to, 1)
    state
  end

  @doc "Converts the next chunk. The output can be shorter than the input duration."
  # The native converter reads an empty chunk as a flush.
  def push(_state, <<>>), do: <<>>

  def push(state, data) when rem(byte_size(data), 2) == 0 do
    {:ok, output} = Native.convert(data, state)
    output
  end

  @doc "Returns the audio that the converter still holds."
  def flush(state) do
    {:ok, output} = Native.convert(<<>>, state)
    output
  end
end
