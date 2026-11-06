# live_shadcn: card @ 0.1.0 (efea03012dd4)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Card do
  @moduledoc """
  Card.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "jsx/Card/class/0" => "cn-card group/card flex flex-col",
    "jsx/CardAction/class/0" =>
      "cn-card-action col-start-2 row-span-2 row-start-1 self-start justify-self-end",
    "jsx/CardContent/class/0" => "cn-card-content",
    "jsx/CardDescription/class/0" => "cn-card-description",
    "jsx/CardFooter/class/0" => "cn-card-footer flex items-center",
    "jsx/CardHeader/class/0" =>
      "cn-card-header group/card-header @container/card-header grid auto-rows-min items-start has-data-[slot=card-action]:grid-cols-[1fr_auto] has-data-[slot=card-description]:grid-rows-[auto_auto]",
    "jsx/CardTitle/class/0" => "cn-card-title cn-font-heading"
  }
  # live-shadcn: upstream facts end
  Module.get_attribute(__MODULE__, :upstream_facts)

  defp upstream_fact(key), do: Map.fetch!(@upstream_facts, key)

  @doc "The `card` part."
  attr(:size, :string, default: "default", values: ["default", "sm"])
  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card"}
      data-size={@size}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/Card/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-header` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_header(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-header"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardHeader/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-footer` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_footer(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-footer"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardFooter/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-title` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_title(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-title"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardTitle/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-action` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_action(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-action"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardAction/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-description` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_description(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-description"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardDescription/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `card-content` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def card_content(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "card-content"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/CardContent/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
