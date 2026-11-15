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

The text embedding defaults use attention-masked mean pooling and L2
normalization. These defaults match `sentence-transformers/all-MiniLM-L6-v2`, a
BERT model with 384 output values. Other models can need different pooling,
output attributes, or input prefixes. Set these through the serving options and
the adapter input mapper. The library does not infer a retrieval task or add a
query prefix. Text embedding sequence lengths can truncate long input; set the
length for the chosen model and workload.

CLIP emits normalized vectors in the joint CLIP text-image space. BERT and CLIP
vectors use different spaces; do not compare them directly. The captioning
builder generates a complete caption before returning it. All three builders
accept `:load_options` and `:model_options`. Captioning also accepts
`:generation_options`. Set `:compile` to bound input shapes. Load the models once
and use `Models.child_spec/3` to start their shared servings. The same
`NxAdapter`, `Worker`, and `Router` interfaces apply to these models.

Use `NxAdapter.embedding/1` to emit one list of numbers, or supply an output
mapper that keeps the tensor on the device. `NxAdapter.captions/1` emits caption
strings.

```sh
AUDIOFLOW_ML=1 mix run examples/multimodal.exs embed "Two cats on a couch."
AUDIOFLOW_ML=1 mix run examples/multimodal.exs image-embedding image.png
AUDIOFLOW_ML=1 mix run examples/multimodal.exs describe image.png
```

Image modes need the FFmpeg and ffprobe CLIs. They decode the first frame to RGB.
The models run through Bumblebee, Nx, and EXLA.

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

Image turns emit `{:description, text}` events. All description chunks form one
prompt for the language model, and the reply follows the normal speech path. The
`:description` event keeps the original model text. The terminal metrics include
`first_description_us`. Audio and image turns share one active-turn limit. Both
support cancellation, deadlines, and output limits.
Image-only sessions can omit `:stt`. Submission without the required adapter
returns `{:error, {:unsupported_input, stage}}`.

An image can include an integer `:pts` in nanoseconds. The session adds this
time to the description that goes to the language model and to history.
