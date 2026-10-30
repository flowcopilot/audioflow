defmodule AudioFlow.Video do
  @moduledoc """
  Demand-driven RGB video frames with presentation timestamps in nanoseconds.

  `frames/2` accepts an MP4 path or a raw-video source specification. It closes the reader
  on EOF, early halt, or a consumer exception. The reader also stops when its
  owner exits. Other tracks are discarded. Seekable file input supports MP4
  files with or without fast-start metadata.

  Options: `:interval_ms` (1,000), `:max_frame_bytes` (6,291,456), optional
  `:track_id`, `:width`, and `:height`. `frames/2` also accepts `:timeout_ms`
  (30,000 per read); manual readers pass the timeout to `next_frame/2`. Output
  dimensions must be positive even integers. Scaling preserves aspect ratio
  with padding. Without dimensions, the original frame size is retained.
  Timestamps start at the first decoded frame by default. Set
  `:normalize_timestamps?` to false to keep raw decoder timestamps, which can
  include MP4 composition offsets. Frame intervals are preserved in both modes.

  `start_link/1` and `next_frame/2` provide explicit reader control. Supply
  either `:location` for an MP4 file or `:source` for a Membrane raw-video source.
  Readers allow one pending read. Codec working memory and MP4 indexes are
  separate from the bounded RGB queues. Input is decoded as fast as demand
  permits; playback is not paced against a wall clock.
  """

  def frames(input, options \\ []) do
    {timeout, options} = Keyword.pop(options, :timeout_ms, 30_000)

    if not (is_integer(timeout) and timeout > 0),
      do: raise(ArgumentError, "timeout_ms must be positive")

    options =
      if is_binary(input),
        do: Keyword.put(options, :location, input),
        else: Keyword.put(options, :source, input)

    Stream.resource(
      fn ->
        {:ok, _supervisor, reader} = start_link(options)
        reader
      end,
      fn reader ->
        case next_frame(reader, timeout) do
          {:ok, image} -> {[image], reader}
          :eof -> {:halt, reader}
          {:error, reason} -> raise "Video read failed: #{inspect(reason)}"
        end
      end,
      &close/1
    )
  end

  def start_link(options) do
    options =
      Keyword.validate!(options, [
        :location,
        :source,
        :track_id,
        :width,
        :height,
        interval_ms: 1_000,
        max_frame_bytes: 6_291_456,
        normalize_timestamps?: true
      ])

    if options[:location] == nil == (options[:source] == nil),
      do: raise(ArgumentError, "supply exactly one of :location or :source")

    if not is_boolean(options[:normalize_timestamps?]),
      do: raise(ArgumentError, "normalize_timestamps? must be boolean")

    for key <- [:interval_ms, :max_frame_bytes] do
      if not (is_integer(options[key]) and options[key] > 0),
        do: raise(ArgumentError, "#{key} must be positive")
    end

    for key <- [:width, :height], value = options[key], value != nil do
      if not (is_integer(value) and value > 0 and rem(value, 2) == 0),
        do: raise(ArgumentError, "#{key} must be a positive even integer")
    end

    Membrane.Pipeline.start_link(AudioFlow.VideoReader, Keyword.put(options, :owner, self()))
  end

  def next_frame(reader, timeout \\ 30_000),
    do: Membrane.Pipeline.call(reader, :next_frame, timeout)

  def close(reader), do: Membrane.Pipeline.terminate(reader, force?: true)
end
