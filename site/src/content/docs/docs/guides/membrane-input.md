---
title: Membrane input
description: Voice detection, endpointing, and resampling for live audio.
sidebar:
  order: 8
---

```sh
AUDIOFLOW_MEDIA=1 mix deps.get
AUDIOFLOW_MEDIA=1 mix compile --warnings-as-errors
```

## PCM sink with voice detection

`AudioFlow.PCMSink` accepts mono `:s16le` raw audio. With its `vad` option, it
submits utterances after endpoint detection:

```elixir
%AudioFlow.PCMSink{
  session: session,
  vad: {AudioFlow.Silero, serving: AudioFlow.VAD},
  endpoint_options: [min_speech_ms: 96, min_silence_ms: 320]
}
```

Start `AudioFlow.VAD` once with `AudioFlow.Silero.serving/2` and
`AudioFlow.Models.child_spec/3`. The Silero source can be a local ONNX file or
`{:hf, "onnx-community/silero-vad", "onnx/model.onnx"}`. Each sink keeps its
own recurrent state; only the weights are shared. Input must be 16 kHz.

## Barge-in

After speech confirmation, the sink cancels the active reply and sends
`{:audio_flow_speech_started, session}` to its parent. A configured output
transport is flushed by the session. After endpoint detection, the sink sends
`{:audio_flow_input, result}`. The parent must handle busy input.

## Without Membrane

`AudioFlow.VoiceInput` supplies the same frame processing without Membrane. It
keeps pre-roll, confirms speech, uses separate start and stop thresholds, and
limits utterance length.

```sh
AUDIOFLOW_ML=1 AUDIOFLOW_PCM=recording.s16le mix run examples/vad.exs
```

## Complete input chain

`AudioFlow.Input.attach/3` adds FFmpeg resampling and the session sink to a
Membrane source chain. It converts mono or stereo input to mono s16le at the
selected rate (16 kHz by default). `AudioFlow.InputPipeline` supplies this
chain as a complete pipeline. The source can be `AudioFlow.PCMFileSource` or
`Membrane.PortAudio.Source`.

:::caution
Echo cancellation is not included. Speaker audio can trigger the detector.
:::
