defmodule AudioFlowUIWeb.GraphLive do
  @moduledoc """
  One graph on a canvas, its validation errors, and a text run.

  The canvas is read-only. It draws each node at its `"position"`, or in a
  column by its distance from the inputs. A save from the MCP endpoint
  redraws the canvas.
  """
  use Phoenix.LiveView
  alias LiveAiElements.Components.Node

  @node_width 240
  @node_height 128
  @column 320
  @row 180

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: AudioFlowUI.Graphs.subscribe()

    case AudioFlowUI.Graphs.get(id) do
      {:ok, graph} ->
        {:ok, socket |> assign(id: id, run: nil, task: nil, text: "") |> put_graph(graph)}

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
          AudioFlowUI.Runs.run_text(graph, text)
        end)

      {:noreply, assign(socket, task: task.ref, text: text, run: :running)}
    end
  end

  def handle_event("run", _params, socket), do: {:noreply, socket}

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

  defp put_graph(socket, graph) do
    types = Map.new(AudioFlowUI.node_types(), &{&1["type"], &1})
    nodes = layout(graph)
    by_id = Map.new(nodes, &{&1.id, &1})

    edges =
      for %{"from" => from, "to" => to} <- graph["edges"] || [],
          Map.has_key?(by_id, from) and Map.has_key?(by_id, to),
          do: %{id: "#{from}->#{to}", path: edge_path(by_id[from], by_id[to])}

    width = Enum.reduce(nodes, 0, &max(&2, &1.x + @node_width)) + 40
    height = Enum.reduce(nodes, 0, &max(&2, &1.y + @node_height)) + 40

    assign(socket,
      graph: graph,
      types: types,
      nodes: nodes,
      edges: edges,
      size: {width, height},
      errors: AudioFlowUI.errors(graph)
    )
  end

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
        {x, y} =
          case node["position"] do
            %{"x" => x, "y" => y} when is_number(x) and is_number(y) -> {x, y}
            _ -> {depth * @column, row * @row}
          end

        %{id: node["id"], type: node["type"], options: options(node["options"]), x: x, y: y}
      end)
    end)
  end

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

  defp edge_path(source, target) do
    {x1, y1} = {source.x + @node_width, source.y + div(@node_height, 2)}
    {x2, y2} = {target.x, target.y + div(@node_height, 2)}
    middle = x1 + (x2 - x1) / 2
    "M#{x1},#{y1} C #{middle},#{y1} #{middle},#{y2} #{x2},#{y2}"
  end

  defp option_text(value) when is_binary(value), do: value
  defp option_text(value), do: inspect(value)

  @impl true
  def render(assigns) do
    {width, height} = assigns.size

    assigns =
      assign(assigns,
        width: width,
        height: height,
        node_width: @node_width,
        node_height: @node_height
      )

    ~H"""
    <main class="flex h-dvh">
      <section class="relative flex-1 overflow-auto">
        <header class="sticky top-0 left-0 z-10 flex items-center gap-3 p-4">
          <.link navigate="/" class="text-sm text-muted-foreground hover:text-foreground">Graphs</.link>
          <h1 class="font-semibold">{@graph["name"]}</h1>
        </header>

        <div class="relative m-8" style={"width: #{@width}px; height: #{@height}px"}>
          <svg class="pointer-events-none absolute inset-0" width={@width} height={@height}>
            <path
              :for={edge <- @edges}
              id={edge.id}
              d={edge.path}
              fill="none"
              class="stroke-ring"
              stroke-width="1.5"
            />
          </svg>

          <Node.node
            :for={node <- @nodes}
            id={"node-#{node.id}"}
            handles={
              %{target: @types[node.type]["input"] != nil, source: @types[node.type]["output"] != nil}
            }
            class="!absolute overflow-hidden"
            style={"left: #{node.x}px; top: #{node.y}px; width: #{@node_width}px; height: #{@node_height}px"}
          >
            <Node.node_header>
              <Node.node_title>{node.id}</Node.node_title>
              <Node.node_description>
                {if type = @types[node.type], do: type["title"], else: "Unknown type #{node.type}"}
              </Node.node_description>
            </Node.node_header>
            <Node.node_content class="flex flex-col gap-1 text-xs">
              <span :if={type = @types[node.type]} class="font-mono text-muted-foreground">
                {type["input"] || "—"} → {type["output"] || "—"}
              </span>
              <span :for={{key, value} <- node.options} class="truncate font-mono">
                {key}: {option_text(value)}
              </span>
            </Node.node_content>
          </Node.node>
        </div>
      </section>

      <aside class="flex w-96 flex-col gap-6 overflow-y-auto border-l p-4">
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
