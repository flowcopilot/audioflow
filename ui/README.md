# AudioFlow UI

A local dashboard for AudioFlow agent graphs, with an MCP endpoint for coding
agents. A graph is an `AudioFlow.Graph`: typed nodes and the edges between
them. The dashboard and the MCP tools use the same graph store, so a change
from a coding agent shows immediately in an open dashboard.

## Editor

The graph page is an editor. Changes save immediately, and the MCP tools
see them.

| Operation | Action |
| --- | --- |
| Pan | Drag the background. |
| Zoom | Use the wheel or pinch. The controls zoom, fit, and reset the view. |
| Move a node | Drag it, or focus it and push the arrow keys. It snaps to a 20 px grid. |
| Connect | Drag from an output handle to an input handle of the same kind. |
| Select | Click a node or an edge, or focus it and push Enter. |
| Delete | Push Delete or Backspace on the focused node or edge. |
| Add a node | Click a node type in the "Add node" panel. |
| Options | Select a node, edit the form, and click "Save options". |

"New graph" on the list page makes an empty graph.

## Run

```sh
cd ui
mix setup
mix phx.server
```

Open <http://localhost:4100>. Set `PORT` to use another port. The server
listens on `127.0.0.1` only.

Graphs are JSON files in the user data directory
(`~/Library/Application Support/audioflow_ui` on macOS). Set
`AUDIOFLOW_UI_DATA` to use another directory. On the first start, the
dashboard adds a demo graph.

## MCP

Connect a coding agent to the endpoint:

```sh
claude mcp add --transport http audioflow http://localhost:4100/mcp
```

| Tool | Operation |
| --- | --- |
| `list_node_types` | Lists node types, their ports, and their options. |
| `list_graphs` | Lists saved graphs and their validation errors. |
| `get_graph` | Returns one graph and its validation errors. |
| `save_graph` | Creates or replaces a graph. An incomplete graph is saved, and its errors are returned. |
| `validate_graph` | Validates a graph and does not save it. |
| `delete_graph` | Deletes a graph. |
| `run_graph` | Runs one text turn and returns the reply, the events, and the timing. |

[Sake](https://github.com/hattoriai/sake) serves the endpoint. It refuses
requests from browser pages, which prevents DNS rebinding. Without a token,
all local processes can call the endpoint. To require a token, set
`AUDIOFLOW_UI_TOKEN`, then give the token to the client:

```sh
claude mcp add --transport http audioflow http://localhost:4100/mcp \
  --header "Authorization: Bearer $AUDIOFLOW_UI_TOKEN"
```

## Node types

The default catalog has the input nodes, `audio.resample`, the demo STT,
LLM, and TTS nodes, `llm.req_llm` for ReqLLM models and endpoints, and the
deprecated `llm.chat_http` chat-completions node.

To add the native model nodes, build with `AUDIOFLOW_ML=1`:

```sh
AUDIOFLOW_ML=1 mix setup
AUDIOFLOW_ML=1 mix phx.server
```

| Type | Models |
| --- | --- |
| `whisper.stt` | Whisper tiny, base, small, medium (and `.en`), large v3, large v3 turbo |
| `qwen3.llm` | Qwen3 0.6B, 1.7B, 4B, 8B. Accepts history. |
| `bumblebee.llm` | Any text generation repository that Bumblebee supports |
| `kokoro.tts` | Kokoro 82M, 28 American and British English voices. Needs `espeak-ng`. |
| `vits.tts` | MMS VITS English |
| `blip.vision` | BLIP image captions, base and large |
| `clip.embedding` | CLIP image vectors, ViT-B/32 and ViT-L/14 |
| `text.embedding` | MiniLM-L6 and MPNet sentence vectors |

A model loads on the first turn that uses it, and all sessions share it.
The first turn can take minutes to download and compile. Set the graph
setting `timeout_ms` to allow for this. Models run with EXLA on the CPU.
Kokoro speaks at 24 kHz and Whisper needs 16 kHz, so put an
`audio.resample` node between them. The graph keeps the
name of the API key variable (`api_key_env`), not the key.
To add node types, write an `AudioFlow.Graph.Node` module and set the list:

```elixir
config :audio_flow_ui, :nodes, [
  AudioFlow.Graph.Nodes.Input,
  AudioFlow.Graph.Nodes.Demo,
  AudioFlow.Graph.Nodes.ChatHTTP,
  MyApp.WhisperNodes
]
```

A graph runs as one `AudioFlow.Session`. It needs an input node and no
cycles, and each node needs a path from an input node. A node can have
several sources and targets. A join node, such as STT or an LLM, runs once on
the output of all its sources. A stream node, such as TTS, runs for each
value, so speech starts before the reply is complete. The validation tells
which node or edge is not correct.

## Runnable examples

Open **Runnable examples** from the graph list (/examples). The workflow button
uses real Conversation and Jido handoff APIs with deterministic adapters:
a failed turn rolls back to triage, then a successful turn commits billing.
Evaluation runs up to ten text turns in one session and compares exact replies.
Start with "Hello => You said: Hello." on Synthetic echo. A wrong expectation
returns passed: false. Saved graphs select their last text-output node and
respect graph history settings. MCP offers evaluate_conversation with id/script.
These checks do not grade audio or classify intents with a model.

Remote speech nodes are deepgram.stt, elevenlabs.tts and cartesia.tts. Create a
starter, select its node, and save model, language code and voice options.
Cartesia also requires an explicit API version; see [contracts](../docs/providers.md).
Set only the selected provider's DEEPGRAM_API_KEY, ELEVENLABS_API_KEY or
CARTESIA_API_KEY in the **server environment**, using your secret manager.
Never paste credentials into graphs, scripts or browser/MCP payloads. Speech
nodes accept neither raw keys nor arbitrary environment-variable names or URLs.
A missing key disables dashboard runs and returns an MCP prerequisite error.
Key presence is not evidence of account/model access.

STT graphs accept committed mono signed 16-bit little-endian PCM uploads,
without WAV headers, up to 2 MB. Select the file's actual sample rate.
For example, prepare a local file with:

```sh
ffmpeg -i speech.wav -ac 1 -ar 16000 -f s16le speech.pcm
```

The runner displays transcripts and PCM byte counts, with per-node WAV playback
after completion (first 8 MB total PCM; no mixing or resampling). Use the [chat app](../examples/chat/README.md) for interactive voice.
Deepgram receives an already committed utterance, not continuous mic ingress.
OpenAI Realtime and Gemini Live emit mixed transcript/text/audio and cannot
occupy single-output graph nodes. Use their dedicated Session examples in
[providers.md](../docs/providers.md).

### RAG

The starter is text → MiniLM embedding → rag.retrieve → synthetic document echo.
It reports missing native nodes and missing retrieval profiles, never fabricated
documents. For a complete local setup install PostgreSQL with pgvector, create
a dedicated database owned by your user, then run from ui/:

```sh
AUDIOFLOW_ML=1 mix setup
PGDATABASE=audioflow AUDIOFLOW_ML=1 mix run --no-start --no-halt examples/rag.exs
```

The script uses Postgrex's server-side PGHOST, PGPORT, PGUSER, PGPASSWORD and
PGDATABASE variables (default host localhost). It provisions the vector extension
and a 384-dimensional table, computes a real MiniLM embedding for one document,
upserts it into the ui-starter collection and configures the trusted starter
retrieval profile. The user needs extension/table permissions. First inference
downloads/compiles weights. The local script does not configure remote database
TLS; use a trusted Postgrex SSL connection for remote deployments. Document and
query embeddings must use the same model/dimensions. Replace demo.llm with
llm.req_llm for generated answers; until then replies echo retrieved JSON.
No database or native inference verification is implied by synthetic tests.

### Recording

Set AUDIOFLOW_UI_RECORDINGS to a dedicated private server directory to enable
the evaluation recording checkbox. Recording is off by default. Completed
evaluation output events pass through AudioFlow.Recording; input and PCM are not
stored. Email addresses in complete streams become [email] before disk writes.
This regex does not cover other PII. Live results remain unredacted. Failed or
incomplete evaluations write no artifacts. Streams are bounded; retention is
24 hours and at most 100 artifacts, enforced on store access. For idle cleanup,
call AudioFlow.Recording.Store.cleanup/1 periodically.

Results show artifact IDs, not paths. Read/delete from a trusted server console:

```elixir
{:ok, store} = AudioFlow.Recording.Store.new(System.fetch_env!("AUDIOFLOW_UI_RECORDINGS"),
  max_age_ms: 86_400_000, max_records: 100)
{:ok, record} = AudioFlow.Recording.Store.read(store, artifact_id)
:ok = AudioFlow.Recording.Store.delete(store, artifact_id)
```

Deletion does not erase backups. Browsers cannot choose storage paths or disable
redaction for persisted output.

### Standalone transports

Discover the [official Pipecat SDK client](../examples/rtvi-client/README.md)
(typed input/audio output), [telephony loopback](../examples/telephony-loopback.exs),
and [network/avatar examples](../examples/network/README.md), including encoded
WebRTC peer loopback and finite LiveAvatar LITE publishing. Follow their setup
instructions for encoder, peer and provider prerequisites. Encoded WebRTC does
not yet bridge PCM Sessions. Protocol fixtures are distinct from actual peer
negotiation; neither establishes provider inference quality.

### Verification

```sh
# ui/
mix test
mix assets.setup
mix assets.build
# repository root
mix test test/graph_test.exs test/conversation_test.exs test/conversation_evaluation_test.exs test/recording_test.exs test/remote_providers_test.exs test/rag_test.exs
```

UI tests cover text/PCM graph runs, LiveView upload, MCP compatibility/evaluation,
comparison failures, absent key/database configuration, key-free serialization,
redacted artifacts and workflow rollback/commit. Provider protocol tests use
local HTTP/WebSocket fixtures. Browser/device testing, live provider accounts,
native inference and actual WebRTC peer negotiation require separate validation.

For a trusted proxy or local fixture, server configuration may set
:audio_flow, :speech_provider_endpoints to a map from speech node type to URL.
This is application configuration only, never a browser graph option. Use
HTTPS/WSS outside local tests: credentials are sent to that configured endpoint.
