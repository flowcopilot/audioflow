# AudioFlow UI

A local dashboard for AudioFlow agent graphs, with an MCP endpoint for coding
agents. A graph is an `AudioFlow.Graph`: typed nodes and the edges between
them. The dashboard and the MCP tools use the same graph store, so a change
from a coding agent shows immediately in an open dashboard.

The canvas is read-only now. To change a graph, use the MCP tools.

## Run

```sh
cd ui
mix setup
mix phx.server
```

Open http://localhost:4100. Set `PORT` to use another port. The server
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

The default catalog has the input nodes, the demo STT, LLM, and TTS nodes,
and `llm.chat_http` for a chat-completions endpoint. The graph keeps the
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

A graph runs as one `AudioFlow.Session`. Thus it must have the session shape:
input, then STT or vision, then one LLM, then one TTS. The validation tells
which node or edge is not correct.
