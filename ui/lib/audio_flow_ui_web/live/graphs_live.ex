defmodule AudioFlowUIWeb.GraphsLive do
  @moduledoc "The saved graphs. The list follows changes from the MCP endpoint."
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: AudioFlowUI.Graphs.subscribe()
    {:ok, assign(socket, graphs: graphs(), mcp_url: AudioFlowUIWeb.Endpoint.url() <> "/mcp")}
  end

  @impl true
  def handle_event("new_graph", _params, socket) do
    taken = for graph <- AudioFlowUI.Graphs.list(), do: graph["id"]
    id = AudioFlowUI.GraphEdits.unique("graph", taken)
    {:ok, _} = AudioFlowUI.Graphs.put(%{"id" => id, "name" => "Untitled graph"})
    {:noreply, push_navigate(socket, to: "/graphs/#{id}")}
  end

  @impl true
  def handle_info({event, _}, socket) when event in [:graph_saved, :graph_deleted],
    do: {:noreply, assign(socket, graphs: graphs())}

  defp graphs,
    do: for(graph <- AudioFlowUI.Graphs.list(), do: {graph, AudioFlowUI.errors(graph)})

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto flex max-w-3xl flex-col gap-6 p-8">
      <header class="flex flex-col gap-1">
        <div class="flex items-center justify-between gap-4">
          <h1 class="text-xl font-semibold">Agent graphs</h1>
          <button
            type="button"
            phx-click="new_graph"
            class="rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground"
          >
            New graph
          </button>
        </div>
        <p class="text-sm text-muted-foreground">
          Coding agents can edit these graphs through MCP:
          <code class="rounded bg-muted px-1 py-0.5 font-mono text-xs">
            claude mcp add --transport http audioflow {@mcp_url}
          </code>
        </p>
      </header>

      <p :if={@graphs == []} class="text-sm text-muted-foreground">
        No graphs. Make one with New graph, or ask a coding agent to use the <code>save_graph</code>
        tool.
      </p>

      <ul class="flex flex-col gap-2">
        <li :for={{graph, errors} <- @graphs}>
          <.link
            navigate={"/graphs/#{graph["id"]}"}
            class="flex items-center justify-between rounded-md border bg-card p-4 hover:bg-secondary"
          >
            <span class="flex flex-col">
              <span class="font-medium">{graph["name"]}</span>
              <span class="font-mono text-xs text-muted-foreground">
                {graph["id"]} · {length(graph["nodes"] || [])} nodes
              </span>
            </span>
            <span class={[
              "rounded-full border px-2 py-0.5 text-xs",
              if(errors == [], do: "text-foreground", else: "border-destructive text-destructive")
            ]}>
              {if errors == [], do: "Valid", else: "#{length(errors)} errors"}
            </span>
          </.link>
        </li>
      </ul>
    </main>
    """
  end
end
