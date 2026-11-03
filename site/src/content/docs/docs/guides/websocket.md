---
title: WebSocket transport
description: Stream PCM and events between a browser and a session.
sidebar:
  order: 10
---

`AudioFlow.WebSocket` connects one browser or network client to one session
over a WebSocket. It sends raw PCM and JSON events. It is a `WebSock` handler,
so it runs in Bandit or Cowboy through `WebSockAdapter`. In a Plug or Phoenix
route:

```elixir
conn
|> WebSockAdapter.upgrade(AudioFlow.WebSocket,
  [session: session_options, vad: {MyDetector, []}],
  max_frame_size: 1_000_000)
|> Plug.Conn.halt()
```

Each connection starts its own session and owns it. When the connection
closes, the session stops. The client never becomes the session owner. The
connection is also the session's `AudioFlow.Output` transport, so it replaces
an `:output` option. The turn worker waits until the connection accepts each
output chunk. Your application must add `websock_adapter` and a server, such
as `bandit`. AudioFlow uses them only for development and tests.

The client sends binary frames of mono s16le PCM at the input rate (16 kHz by
default). Each frame must contain whole samples, and it must not be larger
than `:max_chunk_bytes` (64,000). Text frames are JSON commands:

| Command | Effect |
| --- | --- |
| `{"type": "text", "text": "Hi"}` | Submit a typed message. |
| `{"type": "commit"}` | Submit the collected PCM. With a detector, end the current utterance. |
| `{"type": "cancel"}` | Cancel the active reply. |
| `{"type": "clear_history"}` | Clear saved history while idle. |

Without `:vad`, PCM collects until `commit`. The collected input must not be
larger than `:max_buffer_bytes` (960,000). With `:vad`, PCM goes through
`AudioFlow.VoiceInput`, and `:endpoint_options` sets its endpoint detection.
Confirmed speech cancels the active reply, and an endpoint submits the
utterance. The input rate must then be the detector rate.

The server sends binary frames of mono s16le reply PCM for the current turn.
An `output_format` event with `sample_rate` comes before the first binary
frame, and before each change of rate. JSON events have a `type` field:
`ready`, `speech_started`, `turn_started`, `transcript`, `description`, `text`,
`done`, `cancelled`, `flush`, `history_cleared`, and `error`. Turn events
include a connection-local integer `turn`. When the client receives `flush`,
it must discard its queued playback. After a cancellation, the connection
drops output from the old turn. An invalid client message gets an `error`
event, and the connection stays open.

The browser example uses the Demo adapters. Hold the button to speak, or type
a message:

```sh
mix run --no-halt examples/websocket.exs
```

Then open http://127.0.0.1:4000. The Demo replies are silent PCM. The
transport does not include echo cancellation, encoding, or packet loss
recovery. Use the browser's echo cancellation for speaker playback.
