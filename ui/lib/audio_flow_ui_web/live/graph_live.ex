defmodule AudioFlowUIWeb.GraphLive do
  @moduledoc """
  One graph in an editor canvas, its validation errors, and a text run.

  The canvas draws each node at its `"position"`, or in a column by its
  distance from the inputs. Each edit reads the stored graph, changes it with
  `AudioFlowUI.GraphEdits`, and saves it. A save from the MCP endpoint
  redraws the canvas.
  """
  use Phoenix.LiveView
  alias AudioFlowUI.GraphEdits
  alias AudioFlowUIWeb.Components.Canvas
  alias AudioFlowUIWeb.Components.GraphPanels
  alias LiveAiElements.Components.Node

  @node_width 240
  @node_height 128
  @column 320
  @row 180
  @grid 20

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: AudioFlowUI.Graphs.subscribe()

    case AudioFlowUI.Graphs.get(id) do
      {:ok, graph} ->
        {:ok,
         socket
         |> assign(id: id, run: nil, task: nil, text: "", selected: nil, notice: nil)
         |> assign(view: %{"x" => 0, "y" => 0, "width" => 960, "height" => 640})
         |> put_graph(graph)
         |> allow_upload(:pcm, accept: :any, max_entries: 1, max_file_size: 2_000_000)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: "/")}
    end
  end

  @impl true
  def handle_event("run", %{"text" => text}, %{assigns: %{task: nil}} = socket) do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      graph = socket.assigns.graph

      task =
        Task.Supervisor.async_nolink(AudioFlowUI.Tasks, fn ->
          AudioFlowUI.Runs.run_browser_text(graph, text)
        end)

      {:noreply, assign(socket, task: task.ref, text: text, run: :running)}
    end
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

  def handle_event("validate_audio", _, socket), do: {:noreply, socket}

  def handle_event("run_audio", %{"rate" => rate}, %{assigns: %{task: nil}} = socket)
      when rate in ["8000", "16000", "22050", "24000", "44100", "48000"] do
    audio =
      consume_uploaded_entries(socket, :pcm, fn %{path: path}, _ ->
        {:ok, %AudioFlow.Audio{data: File.read!(path), sample_rate: String.to_integer(rate)}}
      end)

    case audio do
      [audio] ->
        graph = socket.assigns.graph

        task =
          Task.Supervisor.async_nolink(AudioFlowUI.Tasks, fn ->
            AudioFlowUI.Runs.run_browser_audio(graph, audio)
          end)

        {:noreply, assign(socket, task: task.ref, run: :running)}

      _ ->
        {:noreply, assign(socket, notice: "Upload mono s16le PCM first")}
    end
  end

  def handle_event("run_audio", _, socket), do: {:noreply, socket}

  def handle_event("move_node", %{"id" => id, "x" => x, "y" => y}, socket),
    do: edit(socket, &GraphEdits.move_node(&1, id, x, y))

  def handle_event("connect", %{"from" => from, "to" => to}, socket),
    do: edit(socket, &GraphEdits.connect(&1, from, to, socket.assigns.types))

  def handle_event("disconnect", %{"from" => from, "to" => to}, socket),
    do: edit(socket, &GraphEdits.disconnect(&1, from, to))

  def handle_event("delete_node", %{"id" => id}, socket),
    do: edit(socket, &GraphEdits.delete_node(&1, id))

  def handle_event("add_node", %{"type" => type}, socket) do
    %{"x" => x, "y" => y, "width" => width, "height" => height} = socket.assigns.view
    snap = &(round(&1 / @grid) * @grid)
    center = {snap.(x + (width - @node_width) / 2), snap.(y + (height - @node_height) / 2)}

    with {:noreply, socket} <-
           edit(socket, &GraphEdits.add_node(&1, type, center, socket.assigns.types)) do
      added = if socket.assigns.notice == nil, do: List.last(socket.assigns.graph["nodes"])
      {:noreply, if(added, do: assign(socket, selected: {:node, added["id"]}), else: socket)}
    end
  end

  def handle_event("set_options", %{"node" => id} = params, socket),
    do:
      edit(
        socket,
        &GraphEdits.set_options(&1, id, params["options"] || %{}, socket.assigns.types)
      )

  def handle_event("rename", %{"name" => name}, socket),
    do: edit(socket, &GraphEdits.rename(&1, name))

  def handle_event("select", params, socket) do
    selected =
      case params do
        %{"node" => id} -> {:node, id}
        %{"from" => from, "to" => to} -> {:edge, from, to}
        _ -> nil
      end

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("viewport", %{"x" => _, "y" => _, "width" => _, "height" => _} = view, socket),
    do: {:noreply, assign(socket, view: Map.take(view, ["x", "y", "width", "height"]))}

  @impl true
  def handle_info({:graph_saved, %{"id" => id} = graph}, %{assigns: %{id: id}} = socket),
    do: {:noreply, put_graph(socket, graph)}

  def handle_info({:graph_deleted, id}, %{assigns: %{id: id}} = socket),
    do: {:noreply, push_navigate(socket, to: "/")}

  def handle_info({ref, result}, %{assigns: %{task: ref}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, task: nil, run: result)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{assigns: %{task: ref}} = socket),
    do: {:noreply, assign(socket, task: nil, run: {:error, {:crashed, reason}})}

  def handle_info(_, socket), do: {:noreply, socket}

  defp edit(socket, change) do
    with {:ok, graph} <- AudioFlowUI.Graphs.get(socket.assigns.id),
         {:ok, graph} <- change.(graph),
         {:ok, graph} <- AudioFlowUI.Graphs.put(graph) do
      {:noreply, socket |> assign(notice: nil) |> put_graph(graph)}
    else
      {:error, :not_found} -> {:noreply, push_navigate(socket, to: "/")}
      {:error, message} -> {:noreply, assign(socket, notice: message)}
    end
  end

  defp put_graph(socket, graph) do
    types = Map.new(AudioFlowUI.node_types(), &{&1["type"], &1})

    nodes =
      for node <- layout(graph) do
        type = types[node.type]
        label = "#{node.id}, #{if type, do: type["title"], else: "unknown type"}"

        Map.merge(node, %{
          input: type && type["input"],
          output: type && type["output"],
          label: label
        })
      end

    edges =
      for %{"from" => from, "to" => to} <- graph["edges"] || [],
          is_binary(from) and is_binary(to),
          do: %{from: from, to: to}

    assign(socket,
      graph: graph,
      types: types,
      nodes: nodes,
      edges: edges,
      selected: selection(socket.assigns[:selected], nodes, edges),
      errors: AudioFlowUI.errors(graph) ++ AudioFlowUI.Prerequisites.errors(graph)
    )
  end

  # The selection is cleared when its node or edge is no longer in the graph.
  defp selection({:node, id} = selected, nodes, _edges),
    do: if(Enum.any?(nodes, &(&1.id == id)), do: selected)

  defp selection({:edge, from, to} = selected, _nodes, edges),
    do: if(%{from: from, to: to} in edges, do: selected)

  defp selection(_, _nodes, _edges), do: nil

  defp selected_node(%{selected: {:node, id}, graph: graph}),
    do: Enum.find(graph["nodes"] || [], &(&1["id"] == id))

  defp selected_node(_assigns), do: nil

  # A node without a position goes in the column of its longest path from an input.
  defp layout(graph) do
    nodes = for %{"id" => id} = node <- graph["nodes"] || [], is_binary(id), do: node
    sources = Enum.group_by(graph["edges"] || [], & &1["to"], & &1["from"])
    depths = Map.new(nodes, &{&1["id"], depth(&1["id"], sources, MapSet.new())})

    nodes
    |> Enum.group_by(&depths[&1["id"]])
    |> Enum.flat_map(fn {depth, column} ->
      column
      |> Enum.with_index()
      |> Enum.map(fn {node, row} ->
        {x, y} = position(node["position"], depth, row)
        %{id: node["id"], type: node["type"], options: options(node["options"]), x: x, y: y}
      end)
    end)
  end

  defp position(%{"x" => x, "y" => y}, _depth, _row) when is_number(x) and is_number(y),
    do: {x, y}

  defp position(_position, depth, row), do: {depth * @column, row * @row}

  defp options(%{} = options), do: Enum.sort(options)
  defp options(_), do: []

  defp depth(id, sources, seen) do
    if MapSet.member?(seen, id) do
      0
    else
      seen = MapSet.put(seen, id)

      sources
      |> Map.get(id, [])
      |> Enum.map(&(depth(&1, sources, seen) + 1))
      |> Enum.max(fn -> 0 end)
    end
  end

  defp option_text(value) when is_binary(value), do: value
  defp option_text(value), do: inspect(value)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        node_width: @node_width,
        node_height: @node_height,
        grid: @grid,
        node: selected_node(assigns)
      )

    ~H"""
    <main class="flex h-dvh">
      <section class="relative flex-1 overflow-hidden">
        <Canvas.canvas
          id="canvas"
          nodes={@nodes}
          edges={@edges}
          selected={@selected}
          node_width={@node_width}
          node_height={@node_height}
          grid={@grid}
          aria-label="Graph canvas"
        >
          <:node :let={node}>
            <Node.node_header>
              <Node.node_title>{node.id}</Node.node_title>
              <Node.node_description>
                {if type = @types[node.type], do: type["title"], else: "Unknown type #{node.type}"}
              </Node.node_description>
            </Node.node_header>
            <Node.node_content class="flex flex-col gap-1 text-xs">
              <span :if={@types[node.type]} class="font-mono text-muted-foreground">
                {node.input || "—"} → {node.output || "—"}
              </span>
              <span :for={{key, value} <- node.options} class="truncate font-mono">
                {key}: {option_text(value)}
              </span>
            </Node.node_content>
          </:node>

          <header class="absolute top-0 left-0 z-10 flex items-center gap-3 p-4">
            <.link navigate="/" class="text-sm text-muted-foreground hover:text-foreground">Graphs</.link>
            <h1 class="sr-only">{@graph["name"]}</h1>
            <form id="rename" phx-submit="rename" class="flex items-center gap-2">
              <label for="graph-name" class="sr-only">Graph name</label>
              <input
                id="graph-name"
                name="name"
                value={@graph["name"]}
                autocomplete="off"
                class="w-64 rounded-md border border-transparent bg-transparent px-2 py-1 font-semibold hover:border-border focus:border-border"
              />
              <button class="rounded-md border px-2 py-1 text-xs hover:bg-secondary">Rename</button>
            </form>
          </header>
        </Canvas.canvas>
        <p
          id="notice"
          role="status"
          class="pointer-events-none absolute top-16 left-4 z-10 text-sm text-destructive"
        >
          {@notice}
        </p>
      </section>

      <aside class="flex w-96 flex-col gap-6 overflow-y-auto border-l p-4">
        <GraphPanels.node_form :if={@node} node={@node} spec={@types[@node["type"]]} />
        <GraphPanels.palette types={Map.values(@types)} />

        <section class="flex flex-col gap-2">
          <h2 class="text-sm font-medium">Validation</h2>
          <p :if={@errors == []} class="text-sm text-muted-foreground">The graph is valid.</p>
          <ul :if={@errors != []} id="errors" class="flex flex-col gap-1 text-sm text-destructive">
            <li :for={error <- @errors}>{error}</li>
          </ul>
        </section>

        <section class="flex flex-col gap-2">
          <h2 class="text-sm font-medium">Run</h2>
          <form id="run" phx-submit="run" class="flex gap-2">
            <input
              name="text"
              value={@text}
              placeholder="Type a message"
              autocomplete="off"
              class="min-w-0 flex-1 rounded-md border bg-transparent px-3 py-1.5 text-sm"
            />
            <button
              disabled={@task != nil or @errors != []}
              class="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground disabled:opacity-50"
            >
              Run
            </button>
          </form>
          <form
            id="run-audio"
            phx-submit="run_audio"
            phx-change="validate_audio"
            class="flex flex-col gap-2"
          >
            <label>
              Committed mono signed 16-bit little-endian PCM (no WAV header, at most 2 MB)
              <.live_file_input upload={@uploads.pcm} />
            </label>
            <label>
              Input sample rate
              <select name="rate">
                <option
                  :for={rate <- [8000, 16000, 22050, 24000, 44100, 48000]}
                  value={rate}
                  selected={rate == 16000}
                >
                  {rate} Hz
                </option>
              </select>
            </label>
            <p :for={error <- upload_errors(@uploads.pcm)}>{inspect(error)}</p>
            <button disabled={@task != nil or @errors != []}>Run PCM utterance</button>
          </form>
          <p class="text-xs">
            Speech output can be played after the turn completes (up to 8 MB of PCM).
          </p>
          <.run_result run={@run} />
        </section>
      </aside>
    </main>
    """
  end

  defp event_text(%{"text" => text}), do: text
  defp event_text(%{"bytes" => bytes, "sample_rate" => rate}), do: "#{bytes} bytes at #{rate} Hz"
  defp event_text(%{"width" => width, "height" => height}), do: "#{width}×#{height} image"
  defp event_text(%{"dimensions" => dimensions}), do: "#{dimensions} dimensions"

  defp run_result(%{run: nil} = assigns), do: ~H""

  defp run_result(%{run: :running} = assigns),
    do: ~H|<p class="text-sm text-muted-foreground">Running…</p>|

  defp run_result(%{run: {:ok, result}} = assigns) do
    assigns = assign(assigns, result: result)

    ~H"""
    <div id="run-result" class="flex flex-col gap-2 text-sm">
      <p :if={@result["error"]} class="text-destructive">{@result["error"]}</p>
      <p>{@result["reply"]}</p>
      <label :for={audio <- @result["audio"] || []}>
        {audio["node"]} output (first 8 MB total PCM) <audio controls src={audio["url"]} />
      </label>
      <ol class="flex flex-col gap-1 font-mono text-xs text-muted-foreground">
        <li :for={event <- @result["events"]}>
          {event["node"]} {event["type"]}: {event_text(event)}
        </li>
      </ol>
      <p class="text-xs text-muted-foreground">
        {@result["status"]} in {div(@result["metrics"]["duration_us"], 1000)} ms
      </p>
    </div>
    """
  end

  defp run_result(%{run: {:error, error}} = assigns) do
    assigns = assign(assigns, error: AudioFlowUI.MCP.message(error))
    ~H|<p id="run-result" class="text-sm text-destructive">{@error}</p>|
  end
end
