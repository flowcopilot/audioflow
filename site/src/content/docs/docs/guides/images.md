---
title: Images and embeddings
description: CLIP and BERT embeddings, BLIP captions, and image turns.
sidebar:
  order: 5
---

## Model builders

| Builder | Model | Output |
| --- | --- | --- |
| `Models.text_embedding/2` | BERT, for example `all-MiniLM-L6-v2` | Normalized vector, 384 values |
| `Models.clip_image_embedding/2` | CLIP vision with projection | Normalized vector, 512 values |
| `Models.image_captioning/2` | BLIP and other caption models | Caption text |

BERT and CLIP vectors use different spaces; do not compare them directly. All
three builders accept `:load_options` and `:model_options`. Captioning also
accepts `:generation_options`. Set `:compile` to bound input shapes.

Use `NxAdapter.embedding/1` to emit one list of numbers, or supply an output
mapper that keeps the tensor on the device. `NxAdapter.captions/1` emits caption
strings.

```sh
AUDIOFLOW_ML=1 mix run examples/multimodal.exs embed "Two cats on a couch."
AUDIOFLOW_ML=1 mix run examples/multimodal.exs image-embedding image.png
AUDIOFLOW_ML=1 mix run examples/multimodal.exs describe image.png
```

Image modes need the FFmpeg and ffprobe CLIs.

## Image turns

A session with a `:vision` adapter accepts an `AudioFlow.Image`:

```elixir
vision = {AudioFlow.NxAdapter,
  serving: MyApp.CaptionModel,
  input: &AudioFlow.NxAdapter.image_input/1,
  output: &AudioFlow.NxAdapter.captions/1}
{:ok, session} = AudioFlow.start_session(
  Keyword.put(session_options, :vision, vision))
{:ok, turn} = AudioFlow.submit(session,
  %AudioFlow.Image{data: rgb_bytes, width: width, height: height})
```

Image data must use packed RGB, with three unsigned 8-bit channels per pixel in
row order. Its byte count must equal `width * height * 3`. The session rejects
images above `:max_image_bytes` (6,291,456 by default).

Image turns emit `{:description, text}` events. The description becomes the
prompt for the language model, and the reply follows the normal speech path.
Image-only sessions can omit `:stt`. Submission without the required adapter
returns `{:error, {:unsupported_input, stage}}`.

An image can include an integer `:pts` in nanoseconds. The session adds this
time to the description that goes to the language model and to history.
