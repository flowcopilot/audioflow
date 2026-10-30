defmodule AudioFlowUIWeb.Components.GraphPanels do
  @moduledoc "Editor panels of the graph page: the node palette and the options form of a node."
  use Phoenix.Component

  @field "min-w-0 rounded-md border bg-transparent px-3 py-1.5 text-sm"

  attr :types, :list, required: true, doc: "Node type specs from `AudioFlowUI.node_types/0`."

  def palette(assigns) do
    groups =
      assigns.types
      |> Enum.group_by(&{&1["input"], &1["output"]})
      |> Enum.sort_by(fn {{input, output}, _} -> {input != nil, input || "", output || ""} end)

    assigns = assign(assigns, groups: groups)

    ~H"""
    <section id="palette" class="flex flex-col gap-2" aria-labelledby="palette-title">
      <h2 id="palette-title" class="text-sm font-medium">Add node</h2>
      <div :for={{{input, output}, types} <- @groups} class="flex flex-col gap-1">
        <h3 class="font-mono text-xs text-muted-foreground">{input || "—"} → {output || "—"}</h3>
        <div class="flex flex-wrap gap-1">
          <button
            :for={type <- types}
            type="button"
            phx-click="add_node"
            phx-value-type={type["type"]}
            title={type["description"]}
            aria-label={"Add #{type["title"]}"}
            class="rounded-md border px-2 py-1 text-xs hover:bg-secondary"
          >
            {type["title"]}
          </button>
        </div>
      </div>
    </section>
    """
  end

  attr :node, :map, required: true
  attr :spec, :map, default: nil, doc: "The type spec of the node, or `nil` for an unknown type."

  def node_form(assigns) do
    assigns = assign(assigns, field: @field, options: assigns.node["options"] || %{})

    ~H"""
    <section id="node-panel" class="flex flex-col gap-3" aria-labelledby="node-panel-title">
      <div class="flex items-center justify-between gap-2">
        <h2 id="node-panel-title" class="text-sm font-medium">
          {@node["id"]}
          <span class="font-normal text-muted-foreground">
            {if @spec, do: @spec["title"], else: "Unknown type #{@node["type"]}"}
          </span>
        </h2>
        <button
          type="button"
          phx-click="delete_node"
          phx-value-id={@node["id"]}
          class="rounded-md border px-2 py-1 text-xs text-destructive hover:bg-secondary"
        >
          Delete node
        </button>
      </div>

      <p :if={@spec && @spec["options"] == []} class="text-sm text-muted-foreground">
        This node has no options.
      </p>

      <form
        :if={@spec && @spec["options"] != []}
        id="node-options"
        phx-submit="set_options"
        class="flex flex-col gap-3"
      >
        <input type="hidden" name="node" value={@node["id"]} />
        <.option
          :for={option <- @spec["options"]}
          option={option}
          value={Map.get(@options, option["name"])}
          field={@field}
        />
        <button class="self-start rounded-md bg-primary px-3 py-1.5 text-sm text-primary-foreground">
          Save options
        </button>
      </form>
    </section>
    """
  end

  attr :option, :map, required: true
  attr :value, :any, required: true
  attr :field, :string, required: true

  defp option(%{option: %{"type" => "boolean"}} = assigns) do
    ~H"""
    <label class="flex items-center gap-2 text-sm">
      <input type="hidden" name={"options[#{@option["name"]}]"} value="false" />
      <input
        type="checkbox"
        id={"option-#{@option["name"]}"}
        name={"options[#{@option["name"]}]"}
        value="true"
        checked={if is_nil(@value), do: @option["default"] == true, else: @value == true}
      />
      {@option["name"]}
      <.hint option={@option} />
    </label>
    """
  end

  defp option(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <label for={"option-#{@option["name"]}"} class="text-sm">
        {@option["name"]}
        <span :if={@option["required"]} class="text-destructive">(required)</span>
      </label>
      <select
        :if={@option["type"] == "enum"}
        id={"option-#{@option["name"]}"}
        name={"options[#{@option["name"]}]"}
        class={@field}
      >
        <option :if={!@option["required"]} value="">
          {if Map.has_key?(@option, "default"), do: "Default (#{@option["default"]})", else: "None"}
        </option>
        <option
          :for={value <- @option["values"]}
          value={to_string(value)}
          selected={@value != nil and to_string(@value) == to_string(value)}
        >
          {value}
        </option>
      </select>
      <input
        :if={@option["type"] != "enum"}
        id={"option-#{@option["name"]}"}
        name={"options[#{@option["name"]}]"}
        type={if @option["type"] == "integer", do: "number", else: "text"}
        step={@option["type"] == "integer" && "1"}
        value={@value}
        placeholder={@option["default"] && to_string(@option["default"])}
        required={@option["required"] == true}
        autocomplete="off"
        class={@field}
      />
      <.hint option={@option} />
    </div>
    """
  end

  defp hint(assigns) do
    ~H"""
    <span :if={@option["description"]} class="text-xs text-muted-foreground">
      {@option["description"]}
    </span>
    """
  end
end
