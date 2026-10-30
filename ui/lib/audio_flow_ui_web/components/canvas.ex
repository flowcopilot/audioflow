defmodule AudioFlowUIWeb.Components.Canvas do
  @moduledoc """
  A node graph editor canvas: pan, zoom, node drag, connect, select, and delete.

  The component knows nodes, edges, and port kinds only. It draws each node at
  `x`, `y` with a target handle for `input` and a source handle for `output`
  (a kind string, or `nil` for no port), and draws edges between them. The
  `:node` slot renders the node body.

  The view state (pan and zoom) and a drag in progress stay in the client. A
  server render does not reset them. The hook sends these events:

    * `"move_node"` - `%{"id", "x", "y"}`, once, when a drag ends. The
      position snaps to the grid.
    * `"connect"` - `%{"from", "to"}`, when a source handle is dropped on a
      target handle of the same kind (or the reverse).
    * `"disconnect"` - `%{"from", "to"}`, Delete on the selected edge.
    * `"delete_node"` - `%{"id"}`, Delete on the selected node.
    * `"select"` - `%{"node" => id}`, `%{"from", "to"}` for an edge, or `%{}`.
    * `"viewport"` - `%{"x", "y", "width", "height"}`, the visible area in
      canvas coordinates, after the view changes.

  Keyboard: Tab focuses nodes and edges, Enter or Space selects, the arrow
  keys move the focused node by one grid step, and Delete or Backspace
  deletes the focused element.
  """
  use Phoenix.Component
  alias LiveAiElements.Components.{Controls, Edge, Node}
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true

  attr :nodes, :list,
    required: true,
    doc: "Maps with `:id`, `:x`, `:y`, `:input`, `:output`, and an optional `:label`."

  attr :edges, :list, required: true, doc: "Maps with `:from` and `:to`."

  attr :selected, :any,
    default: nil,
    doc: "`{:node, id}`, `{:edge, from, to}`, or `nil`."

  attr :node_width, :integer, default: 240
  attr :node_height, :integer, default: 128
  attr :grid, :integer, default: 20
  attr :min_zoom, :float, default: 0.25
  attr :max_zoom, :float, default: 2.0
  attr :target, :any, default: nil, doc: "The `phx-target` for the events."
  attr :class, :any, default: nil
  attr :rest, :global

  slot :node, required: true, doc: "The node body. It receives the node map."
  slot :inner_block, doc: "Overlays, such as panels, above the canvas."

  def canvas(assigns) do
    by_id = Map.new(assigns.nodes, &{&1.id, &1})

    edges =
      for edge <- assigns.edges, by_id[edge.from] && by_id[edge.to] do
        Map.put(edge, :path, edge_path(by_id[edge.from], by_id[edge.to], assigns))
      end

    assigns = assign(assigns, edges: edges)

    ~H"""
    <div
      id={@id}
      phx-hook=".Canvas"
      data-grid={@grid}
      data-node-width={@node_width}
      data-node-height={@node_height}
      data-min-zoom={@min_zoom}
      data-max-zoom={@max_zoom}
      data-target={@target}
      tabindex="-1"
      class={[
        "relative size-full touch-none overflow-hidden select-none outline-none",
        "data-[panning]:cursor-grabbing",
        @class
      ]}
      {@rest}
    >
      <div
        data-canvas-grid
        aria-hidden="true"
        phx-mounted={JS.ignore_attributes(["style"])}
        class="pointer-events-none absolute inset-0 bg-[radial-gradient(var(--color-border)_1px,transparent_1px)]"
        style={"background-size: #{@grid}px #{@grid}px"}
      />
      <div
        data-canvas-viewport
        phx-mounted={JS.ignore_attributes(["style"])}
        class="absolute top-0 left-0 origin-top-left"
      >
        <svg
          class="pointer-events-none absolute top-0 left-0 overflow-visible"
          width="1"
          height="1"
          aria-label="Edges"
        >
          <g
            :for={edge <- @edges}
            id={"#{@id}-edge-#{edge.from}-#{edge.to}"}
            data-edge
            data-from={edge.from}
            data-to={edge.to}
            tabindex="0"
            role="button"
            aria-roledescription="edge"
            aria-label={"Edge from #{edge.from} to #{edge.to}"}
            aria-pressed={to_string(@selected == {:edge, edge.from, edge.to})}
            aria-keyshortcuts="Delete"
            class="group cursor-pointer outline-none"
          >
            <path
              d={edge.path}
              fill="none"
              stroke="transparent"
              stroke-width="14"
              class="pointer-events-auto"
            />
            <path
              d={edge.path}
              fill="none"
              stroke-width="1.5"
              class="stroke-ring group-focus-visible:stroke-primary group-aria-pressed:stroke-primary group-aria-pressed:[stroke-width:3]"
            />
          </g>
        </svg>

        <svg
          id={"#{@id}-temporary"}
          phx-update="ignore"
          class="pointer-events-none absolute top-0 left-0 overflow-visible"
          width="1"
          height="1"
          aria-hidden="true"
        >
          <g data-canvas-temporary style="display: none">
            <Edge.edge_temporary id={"#{@id}-temporary-edge"} edge_path="M0,0" />
          </g>
        </svg>

        <Node.node
          :for={node <- @nodes}
          id={"#{@id}-node-#{node.id}"}
          data-node-id={node.id}
          data-x={node.x}
          data-y={node.y}
          tabindex="0"
          role="button"
          aria-roledescription="node"
          aria-label={node[:label] || node.id}
          aria-pressed={to_string(@selected == {:node, node.id})}
          aria-keyshortcuts="Delete ArrowUp ArrowDown ArrowLeft ArrowRight"
          class={[
            "!absolute cursor-grab outline-none",
            "focus-visible:ring-2 focus-visible:ring-ring aria-pressed:ring-2 aria-pressed:ring-primary"
          ]}
          style={"left: #{node.x}px; top: #{node.y}px; width: #{@node_width}px; height: #{@node_height}px"}
        >
          <div class="size-full overflow-hidden rounded-md">
            {render_slot(@node, node)}
          </div>
          <span
            :if={node.input}
            data-handle="target"
            data-kind={node.input}
            data-node={node.id}
            title={"#{node.input} input"}
            aria-hidden="true"
            class={handle_class("-left-2")}
          />
          <span
            :if={node.output}
            data-handle="source"
            data-kind={node.output}
            data-node={node.id}
            title={"#{node.output} output"}
            aria-hidden="true"
            class={handle_class("-right-2")}
          />
        </Node.node>
      </div>

      <Controls.controls data-canvas-controls class="absolute bottom-4 left-4 z-10 flex flex-col">
        <button
          :for={
            {action, label, text} <- [
              {"zoom-in", "Zoom in", "+"},
              {"zoom-out", "Zoom out", "−"},
              {"fit", "Fit view", "⤢"},
              {"reset", "Reset view", "1:1"}
            ]
          }
          type="button"
          data-canvas-action={action}
          aria-label={label}
          title={label}
          class="size-8 text-sm"
        >
          <span aria-hidden="true">{text}</span>
        </button>
      </Controls.controls>

      {render_slot(@inner_block)}

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Canvas">
        const svgPath = (x1, y1, x2, y2) => {
          const middle = x1 + (x2 - x1) / 2;
          return `M${x1},${y1} C ${middle},${y1} ${middle},${y2} ${x2},${y2}`;
        };

        export default {
          mounted() {
            const data = this.el.dataset;
            this.grid = Number(data.grid);
            this.nodeWidth = Number(data.nodeWidth);
            this.nodeHeight = Number(data.nodeHeight);
            this.minZoom = Number(data.minZoom);
            this.maxZoom = Number(data.maxZoom);
            this.view = { x: 40, y: 80, k: 1 };
            this.drag = null;
            this.pointers = new Map();
            // Positions sent with move_node, kept until the server render has them.
            this.pending = new Map();

            this.listeners = [
              [this.el, "pointerdown", (e) => this.onPointerDown(e)],
              [this.el, "pointermove", (e) => this.onPointerMove(e)],
              [this.el, "pointerup", (e) => this.onPointerUp(e, true)],
              [this.el, "pointercancel", (e) => this.onPointerUp(e, false)],
              [this.el, "wheel", (e) => this.onWheel(e), { passive: false }],
              [this.el, "keydown", (e) => this.onKeyDown(e)],
              [this.el, "click", (e) => this.onClick(e)],
            ];
            this.listeners.forEach(([el, name, fn, options]) => el.addEventListener(name, fn, options));
            this.resizeObserver = new ResizeObserver(() => this.sendViewport());
            this.resizeObserver.observe(this.el);

            this.fit();
          },

          updated() {
            this.apply();
          },

          destroyed() {
            this.listeners.forEach(([el, name, fn, options]) => el.removeEventListener(name, fn, options));
            this.resizeObserver.disconnect();
            clearTimeout(this.viewportTimer);
          },

          push(event, payload) {
            const target = this.el.dataset.target;
            return target ? this.pushEventTo(target, event, payload) : this.pushEvent(event, payload);
          },

          // Re-applies the client state after a server render.
          apply() {
            const { x, y, k } = this.view;
            this.el.querySelector("[data-canvas-viewport]").style.transform =
              `translate(${x}px, ${y}px) scale(${k})`;
            const grid = this.el.querySelector("[data-canvas-grid]");
            grid.style.backgroundSize = `${this.grid * k}px ${this.grid * k}px`;
            grid.style.backgroundPosition = `${x}px ${y}px`;

            for (const [id, position] of this.pending) {
              const node = this.node(id);
              if (!node || (Number(node.dataset.x) === position.x && Number(node.dataset.y) === position.y)) {
                this.pending.delete(id);
              }
            }

            const moved = new Map(this.pending);
            if (this.drag?.type === "node" && this.drag.position) {
              moved.set(this.drag.id, this.drag.position);
            }
            for (const [id, position] of moved) this.placeNode(id, position);

            if (this.drag?.type === "connect") this.markHandles(this.drag);
          },

          node(id) {
            return [...this.el.querySelectorAll("[data-node-id]")].find((el) => el.dataset.nodeId === id);
          },

          position(id) {
            const node = this.node(id);
            if (!node) return null;
            return this.pending.get(id) ||
              (this.drag?.id === id && this.drag.position) ||
              { x: Number(node.dataset.x), y: Number(node.dataset.y) };
          },

          placeNode(id, { x, y }) {
            const node = this.node(id);
            if (!node) return;
            node.style.left = `${x}px`;
            node.style.top = `${y}px`;
            for (const edge of this.el.querySelectorAll("[data-edge]")) {
              if (edge.dataset.from !== id && edge.dataset.to !== id) continue;
              const from = this.position(edge.dataset.from);
              const to = this.position(edge.dataset.to);
              if (!from || !to) continue;
              const d = svgPath(
                from.x + this.nodeWidth, from.y + this.nodeHeight / 2,
                to.x, to.y + this.nodeHeight / 2,
              );
              edge.querySelectorAll("path").forEach((path) => path.setAttribute("d", d));
            }
          },

          // A client point in canvas coordinates.
          toCanvas(clientX, clientY) {
            const rect = this.el.getBoundingClientRect();
            return {
              x: (clientX - rect.left - this.view.x) / this.view.k,
              y: (clientY - rect.top - this.view.y) / this.view.k,
            };
          },

          snap(value) {
            return Math.round(value / this.grid) * this.grid;
          },

          setView(view) {
            this.view = view;
            this.apply();
            this.sendViewport();
          },

          zoomAt(clientX, clientY, k) {
            k = Math.min(this.maxZoom, Math.max(this.minZoom, k));
            const rect = this.el.getBoundingClientRect();
            const px = clientX - rect.left;
            const py = clientY - rect.top;
            const ratio = k / this.view.k;
            this.setView({ x: px - (px - this.view.x) * ratio, y: py - (py - this.view.y) * ratio, k });
          },

          zoomCenter(factor) {
            const rect = this.el.getBoundingClientRect();
            this.zoomAt(rect.left + rect.width / 2, rect.top + rect.height / 2, this.view.k * factor);
          },

          fit() {
            const nodes = [...this.el.querySelectorAll("[data-node-id]")].map((el) => this.position(el.dataset.nodeId));
            if (nodes.length === 0) return this.setView({ x: 40, y: 80, k: 1 });
            const minX = Math.min(...nodes.map((n) => n.x));
            const minY = Math.min(...nodes.map((n) => n.y));
            const width = Math.max(...nodes.map((n) => n.x)) + this.nodeWidth - minX;
            const height = Math.max(...nodes.map((n) => n.y)) + this.nodeHeight - minY;
            const rect = this.el.getBoundingClientRect();
            const padding = 64;
            const k = Math.min(
              this.maxZoom, 1,
              Math.max(this.minZoom, Math.min((rect.width - 2 * padding) / width, (rect.height - 2 * padding) / height)),
            );
            this.setView({
              x: (rect.width - width * k) / 2 - minX * k,
              y: (rect.height - height * k) / 2 - minY * k,
              k,
            });
          },

          sendViewport() {
            clearTimeout(this.viewportTimer);
            this.viewportTimer = setTimeout(() => {
              const rect = this.el.getBoundingClientRect();
              const { x, y, k } = this.view;
              this.push("viewport", {
                x: Math.round(-x / k), y: Math.round(-y / k),
                width: Math.round(rect.width / k), height: Math.round(rect.height / k),
              });
            }, 250);
          },

          select(el) {
            this.el.querySelectorAll("[aria-pressed='true']").forEach((other) => {
              if (other !== el) other.setAttribute("aria-pressed", "false");
            });
            if (!el) return this.push("select", {});
            el.setAttribute("aria-pressed", "true");
            el.focus({ preventScroll: true });
            if (el.dataset.nodeId) return this.push("select", { node: el.dataset.nodeId });
            this.push("select", { from: el.dataset.from, to: el.dataset.to });
          },

          onClick(e) {
            const action = e.target.closest("[data-canvas-action]")?.dataset.canvasAction;
            if (action === "zoom-in") this.zoomCenter(1.2);
            if (action === "zoom-out") this.zoomCenter(1 / 1.2);
            if (action === "fit") this.fit();
            if (action === "reset") this.setView({ x: 40, y: 80, k: 1 });
          },

          onPointerDown(e) {
            // Controls and overlays from the inner block keep their own pointer behavior.
            const viewport = this.el.querySelector("[data-canvas-viewport]");
            if (e.target !== this.el && !viewport.contains(e.target)) return;
            if (e.pointerType === "mouse" && e.button !== 0 && e.button !== 1) return;
            this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
            this.el.setPointerCapture(e.pointerId);

            if (this.pointers.size === 2) {
              this.cancelDrag();
              const [a, b] = [...this.pointers.values()];
              this.drag = { type: "pinch", distance: Math.hypot(a.x - b.x, a.y - b.y), k: this.view.k };
              return;
            }

            const handle = e.target.closest("[data-handle]");
            const node = e.target.closest("[data-node-id]");
            const edge = e.target.closest("[data-edge]");

            if (handle && e.button === 0) {
              const start = this.position(handle.dataset.node);
              const side = handle.dataset.handle;
              this.drag = {
                type: "connect",
                node: handle.dataset.node,
                kind: handle.dataset.kind,
                side,
                anchor: {
                  x: start.x + (side === "source" ? this.nodeWidth : 0),
                  y: start.y + this.nodeHeight / 2,
                },
              };
              this.markHandles(this.drag);
              this.drawTemporary(this.toCanvas(e.clientX, e.clientY));
            } else if (node && e.button === 0) {
              if (node.getAttribute("aria-pressed") !== "true") this.select(node);
              else node.focus({ preventScroll: true });
              const start = this.position(node.dataset.nodeId);
              this.drag = { type: "node", id: node.dataset.nodeId, start, clientX: e.clientX, clientY: e.clientY, moved: false };
            } else if (edge && e.button === 0) {
              this.select(edge);
            } else {
              this.drag = { type: "pan", clientX: e.clientX, clientY: e.clientY, view: { ...this.view }, moved: false };
              this.el.toggleAttribute("data-panning", true);
            }
          },

          onPointerMove(e) {
            if (!this.pointers.has(e.pointerId)) return;
            this.pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
            const drag = this.drag;
            if (!drag) return;

            if (drag.type === "pinch") {
              const [a, b] = [...this.pointers.values()];
              const distance = Math.hypot(a.x - b.x, a.y - b.y);
              this.zoomAt((a.x + b.x) / 2, (a.y + b.y) / 2, drag.k * (distance / drag.distance));
            } else if (drag.type === "pan") {
              const dx = e.clientX - drag.clientX;
              const dy = e.clientY - drag.clientY;
              if (Math.hypot(dx, dy) > 3) drag.moved = true;
              this.setView({ ...drag.view, x: drag.view.x + dx, y: drag.view.y + dy });
            } else if (drag.type === "node") {
              const dx = (e.clientX - drag.clientX) / this.view.k;
              const dy = (e.clientY - drag.clientY) / this.view.k;
              if (!drag.moved && Math.hypot(dx, dy) * this.view.k < 3) return;
              drag.moved = true;
              drag.position = { x: this.snap(drag.start.x + dx), y: this.snap(drag.start.y + dy) };
              this.placeNode(drag.id, drag.position);
            } else if (drag.type === "connect") {
              this.drawTemporary(this.toCanvas(e.clientX, e.clientY));
            }
          },

          onPointerUp(e, commit) {
            if (!this.pointers.delete(e.pointerId)) return;
            if (this.el.hasPointerCapture(e.pointerId)) this.el.releasePointerCapture(e.pointerId);
            const drag = this.drag;
            if (!drag || (drag.type === "pinch" && this.pointers.size > 0)) return;
            this.drag = null;
            this.el.removeAttribute("data-panning");

            if (drag.type === "node" && drag.moved && commit) {
              const position = drag.position;
              const changed = position.x !== drag.start.x || position.y !== drag.start.y;
              if (!changed) return;
              this.pending.set(drag.id, position);
              this.placeNode(drag.id, position);
              this.push("move_node", { id: drag.id, ...position })
                .catch(() => {})
                .finally(() => {
                  // The server render has the new position, or the server refused it.
                  if (this.pending.get(drag.id) === position) this.pending.delete(drag.id);
                  this.apply();
                });
            } else if (drag.type === "node" && drag.moved) {
              this.placeNode(drag.id, drag.start);
            } else if (drag.type === "pan" && !drag.moved && commit) {
              if (this.el.querySelector("[aria-pressed='true']")) this.select(null);
              this.el.focus({ preventScroll: true });
            } else if (drag.type === "connect") {
              const target = commit && this.dropTarget(e.clientX, e.clientY, drag);
              this.clearHandles();
              this.el.querySelector("[data-canvas-temporary]").style.display = "none";
              if (target) {
                const [from, to] = drag.side === "source" ? [drag.node, target] : [target, drag.node];
                this.push("connect", { from, to });
              }
            }
          },

          cancelDrag() {
            const drag = this.drag;
            this.drag = null;
            if (drag?.type === "node" && drag.moved) this.placeNode(drag.id, drag.start);
            if (drag?.type === "connect") {
              this.clearHandles();
              this.el.querySelector("[data-canvas-temporary]").style.display = "none";
            }
          },

          // A handle that accepts a drag from `drag`: the other side, the same kind, another node.
          accepts(handle, drag) {
            return handle.dataset.handle !== drag.side &&
              handle.dataset.kind === drag.kind &&
              handle.dataset.node !== drag.node;
          },

          markHandles(drag) {
            for (const handle of this.el.querySelectorAll("[data-handle]")) {
              const other = handle.dataset.handle !== drag.side;
              handle.toggleAttribute("data-accept", other && this.accepts(handle, drag));
              handle.toggleAttribute("data-reject", other && !this.accepts(handle, drag));
            }
          },

          clearHandles() {
            for (const handle of this.el.querySelectorAll("[data-handle]")) {
              handle.removeAttribute("data-accept");
              handle.removeAttribute("data-reject");
            }
          },

          // The node id under the pointer that accepts the connection, or null.
          // A drop on the node body counts as a drop on its handle.
          dropTarget(clientX, clientY, drag) {
            const hit = document.elementFromPoint(clientX, clientY);
            const handle = hit?.closest("[data-handle]") ||
              hit?.closest("[data-node-id]")?.querySelector(`[data-handle="${drag.side === "source" ? "target" : "source"}"]`);
            return handle && this.accepts(handle, drag) ? handle.dataset.node : null;
          },

          drawTemporary(point) {
            const group = this.el.querySelector("[data-canvas-temporary]");
            const { x, y } = this.drag.anchor;
            const d = this.drag.side === "source" ? svgPath(x, y, point.x, point.y) : svgPath(point.x, point.y, x, y);
            group.querySelector("path").setAttribute("d", d);
            group.style.display = "";
          },

          onWheel(e) {
            e.preventDefault();
            const delta = e.deltaY * (e.deltaMode === 1 ? 16 : 1);
            // A trackpad pinch arrives as a wheel event with ctrlKey.
            const factor = Math.exp(-delta * (e.ctrlKey ? 0.01 : 0.0015));
            this.zoomAt(e.clientX, e.clientY, this.view.k * factor);
          },

          onKeyDown(e) {
            const node = e.target.closest("[data-node-id]");
            const edge = e.target.closest("[data-edge]");
            const element = node || edge;
            if (!element || e.target !== element) return;

            if (e.key === "Delete" || e.key === "Backspace") {
              e.preventDefault();
              if (node) this.push("delete_node", { id: node.dataset.nodeId });
              else this.push("disconnect", { from: edge.dataset.from, to: edge.dataset.to });
              this.el.focus({ preventScroll: true });
            } else if (e.key === "Enter" || e.key === " ") {
              e.preventDefault();
              this.select(element);
            } else if (node && e.key.startsWith("Arrow")) {
              e.preventDefault();
              const step = this.grid * (e.shiftKey ? 5 : 1);
              const [dx, dy] = {
                ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step],
              }[e.key];
              const id = node.dataset.nodeId;
              const start = this.position(id);
              const position = { x: this.snap(start.x + dx), y: this.snap(start.y + dy) };
              this.pending.set(id, position);
              this.placeNode(id, position);
              this.push("move_node", { id, ...position }).catch(() => {}).finally(() => {
                if (this.pending.get(id) === position) this.pending.delete(id);
                this.apply();
              });
            }
          },
        };
      </script>
    </div>
    """
  end

  defp handle_class(side) do
    [
      "absolute top-1/2 z-10 size-4 -translate-y-1/2 cursor-crosshair rounded-full border-2 border-primary bg-background",
      "transition-transform data-[accept]:scale-150 data-[accept]:bg-primary data-[reject]:opacity-25",
      side
    ]
  end

  defp edge_path(source, target, assigns) do
    middle_y = div(assigns.node_height, 2)
    {x1, y1} = {source.x + assigns.node_width, source.y + middle_y}
    {x2, y2} = {target.x, target.y + middle_y}
    middle = x1 + (x2 - x1) / 2
    "M#{x1},#{y1} C #{middle},#{y1} #{middle},#{y2} #{x2},#{y2}"
  end
end
