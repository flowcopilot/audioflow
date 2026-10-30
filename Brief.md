Exactly. With Nx + Axon + Bumblebee + EXLA, we could build a Pipecat alternative where not just orchestration but also much of the ML inference runs natively within the Elixir ecosystem.

And there's a particularly interesting new development: Transmuter, announced on October 26, 2026, which enables running ONNX models through Nx without implementing each architecture manually.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://forum.elixirforum.com\&sz=32)

Elixir Programming Language Forum

## The expanded architecture

## What could run locally?

| Stage              | Candidate implementation             | Feasibility             |
| ------------------ | ------------------------------------ | ----------------------- |
| VAD                | Silero VAD through ONNX/Nx           | Needs validation        |
| Speech recognition | Whisper via Bumblebee                | Supported               |
| LLM                | Qwen3, Gemma, SmolLM3                | Supported architectures |
| Speech synthesis   | Kokoro, VITS via Transmuter          | Emerging                |
| Embeddings         | BERT, NomicBERT                      | Supported               |
| Vision             | CLIP, SigLIP, vision-language models | Supported or emerging   |

Bumblebee already implements Whisper and several text-generation architectures. Transmuter expands possible coverage to models including Kokoro, SpeechT5, and VITS.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+1

Importantly, model support doesn't guarantee real-time streaming performance. Low-latency incremental STT, TTS generation, and cancellation would need benchmarking.

## The architectural decision I'd make

I'd treat `Nx.Serving` as the shared inference infrastructure, rather than loading a separate model for every conversation.

For example:

```text
children = [
  {Nx.Serving,
   name: MyApp.Whisper,
   serving: whisper_serving,
   batch_size: 4},

  {Nx.Serving,
   name: MyApp.LLM,
   serving: llm_serving}
]
```

These are illustrative child specifications; the servings themselves must be initialized first.

That would allow multiple voice sessions to share model weights and GPU resources, with batching where appropriate.

For low-latency conversations, we'd need to be especially careful with batching delays, inference queues, and streaming output.

## One more interesting opportunity

This could become more than a Pipecat clone.

With Membrane, Nx, and OTP, we'd have the foundations for an Elixir-native multimodal agent runtime supporting:

- Voice-to-voice conversations
- Video and image understanding
- Local and cloud inference
- Multiple concurrent agents
- Dynamic model routing
- Distributed inference workers
- Supervised, long-lived conversation sessions

I'd keep the model inference interface independent of the underlying engine, so that Nx, ONNX, llama.cpp, and remote inference APIs could all be used interchangeably.

The biggest research question is whether we can achieve competitive speech-to-speech latency with an Nx-native inference pipeline. If we can, the combination of BEAM concurrency and integrated media processing becomes particularly compelling.

I'd start by benchmarking Membrane → Whisper/Nx → Qwen3/Nx → Kokoro/Nx → Membrane, comparing time-to-first-transcript, time-to-first-audio, interruption latency, and maximum concurrent sessions against Pipecat.
