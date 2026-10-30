---
title: Video input
description: Read H.264 frames from MP4 files or a camera source.
sidebar:
  order: 6
---

With `AUDIOFLOW_MEDIA=1`, `AudioFlow.Video.frames/2` reads H.264 video from a
local MP4 file. It also accepts a Membrane raw-video source, such as a camera.
It converts selected frames to packed RGB:

```elixir
for frame <- AudioFlow.Video.frames("input.mp4",
      interval_ms: 1_000, width: 384, height: 384) do
  {:ok, turn} = AudioFlow.submit(session, frame)
  # Wait for this turn to finish before you read the next frame.
end
```

## Frame selection

The interval is the minimum time between selected frames. The reader uses
presentation timestamps, not frame counts. By default, time starts at the first
decoded frame. Set `normalize_timestamps?: false` to keep decoder timestamps.

The default track is the H.264 track with the lowest ID. Use `:track_id` to
select another track. Other tracks, including audio, are discarded.

## Limits

The default frame limit is 6,291,456 bytes. Set `:max_frame_bytes` to change it.
Optional `:width` and `:height` must be positive even integers. Scaling keeps the
aspect ratio and adds padding. Decoding follows demand; the reader does not pace
frames against a clock.

## Manual control

`frames/2` closes the reader at the end of the file, on an early halt, or after
a consumer error. For manual control, use `Video.start_link(location: path)` or
`Video.start_link(source: source)`, then `Video.next_frame(reader, timeout_ms)`
and `Video.close(reader)`.

## Example

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_MEDIA=1 mix run examples/video.exs input.mp4 output
```

The example uses shared BLIP, Qwen3, and Kokoro services. History supplies the
previous description for comparison. `AUDIOFLOW_VIDEO_INTERVAL_MS` sets the
interval, and `AUDIOFLOW_VIDEO_FRAMES` sets the frame limit. This is sampled
frame analysis; it does not track objects or motion between frames.
