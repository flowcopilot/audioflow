# live_shadcn: item @ 0.1.0 (6302cede25e4)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Item do
  @moduledoc """
  Item.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "cva/itemMediaVariants/base" =>
      "cn-item-media flex shrink-0 items-center justify-center [&_svg]:pointer-events-none",
    "cva/itemMediaVariants/default/variant" => "default",
    "cva/itemMediaVariants/variant/variant/default" => "cn-item-media-variant-default",
    "cva/itemMediaVariants/variant/variant/icon" => "cn-item-media-variant-icon",
    "cva/itemMediaVariants/variant/variant/image" => "cn-item-media-variant-image",
    "cva/itemVariants/base" =>
      "cn-item group/item flex w-full flex-wrap items-center transition-colors duration-100 outline-none focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 [a]:transition-colors",
    "cva/itemVariants/default/size" => "default",
    "cva/itemVariants/default/variant" => "default",
    "cva/itemVariants/variant/size/default" => "cn-item-size-default",
    "cva/itemVariants/variant/size/sm" => "cn-item-size-sm",
    "cva/itemVariants/variant/size/xs" => "cn-item-size-xs",
    "cva/itemVariants/variant/variant/default" => "cn-item-variant-default",
    "cva/itemVariants/variant/variant/muted" => "cn-item-variant-muted",
    "cva/itemVariants/variant/variant/outline" => "cn-item-variant-outline",
    "jsx/ItemActions/class/0" => "cn-item-actions flex items-center",
    "jsx/ItemContent/class/0" =>
      "cn-item-content flex flex-1 flex-col [&+[data-slot=item-content]]:flex-none",
    "jsx/ItemDescription/class/0" =>
      "cn-item-description line-clamp-2 font-normal [&>a]:underline [&>a]:underline-offset-4 [&>a:hover]:text-primary",
    "jsx/ItemFooter/class/0" => "cn-item-footer flex basis-full items-center justify-between",
    "jsx/ItemGroup/class/0" => "cn-item-group group/item-group flex w-full flex-col",
    "jsx/ItemHeader/class/0" => "cn-item-header flex basis-full items-center justify-between",
    "jsx/ItemSeparator/class/0" => "cn-item-separator",
    "jsx/ItemTitle/class/0" => "cn-item-title line-clamp-1 flex w-fit items-center"
  }
  # live-shadcn: upstream facts end
  Module.get_attribute(__MODULE__, :upstream_facts)

  defp upstream_fact(key), do: Map.fetch!(@upstream_facts, key)

  @variant_classes (for {"cva/" <> path, value} <- @upstream_facts,
                       [table, "variant", group, choice] <- [String.split(path, "/")],
                       reduce: %{} do
    variants ->
      put_in(
        variants,
        [
          Access.key(table, %{}),
          Access.key(group, %{}),
          Access.key(choice, nil)
        ],
        value
      )
  end)

  @doc "The `item` part."
  attr(:size, :string,
    default: @upstream_facts["cva/itemVariants/default/size"],
    values: @variant_classes |> get_in(["itemVariants", "size"]) |> Map.keys() |> Enum.sort()
  )

  attr(:variant, :string,
    default: @upstream_facts["cva/itemVariants/default/variant"],
    values: @variant_classes |> get_in(["itemVariants", "variant"]) |> Map.keys() |> Enum.sort()
  )

  attr(:as, :string, default: "div", values: ["a", "div"])
  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot", "href", "rel", "target"])
  slot(:inner_block)

  def item(assigns) do
    ~H"""
    <.dynamic_tag
      tag_name={@as}
      data-slot={@rest[:"data-slot"] || "item"}
      data-size={@size}
      data-variant={@variant}
      class={
        LiveShadcn.Cn.merge([
          upstream_fact("cva/itemVariants/base"),
          variant_class("itemVariants", "variant", @variant),
          variant_class("itemVariants", "size", @size),
          @class
        ])
      }
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  @doc "The `item-media` part."
  attr(:variant, :string,
    default: @upstream_facts["cva/itemMediaVariants/default/variant"],
    values:
      @variant_classes |> get_in(["itemMediaVariants", "variant"]) |> Map.keys() |> Enum.sort()
  )

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_media(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-media"}
      data-variant={@variant}
      class={
        LiveShadcn.Cn.merge([
          upstream_fact("cva/itemMediaVariants/base"),
          variant_class("itemMediaVariants", "variant", @variant),
          @class
        ])
      }
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-content` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_content(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-content"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/ItemContent/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-actions` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_actions(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-actions"}
      class={[upstream_fact("jsx/ItemActions/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-group` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_group(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-group"}
      role="list"
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/ItemGroup/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-separator` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_separator(assigns) do
    ~H"""
    <LiveShadcn.UI.Separator.separator
      data-slot={@rest[:"data-slot"] || "item-separator"}
      orientation="horizontal"
      class={[upstream_fact("jsx/ItemSeparator/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </LiveShadcn.UI.Separator.separator>
    """
  end

  @doc "The `item-title` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_title(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-title"}
      class={item_title_class(@class)}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-description` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_description(assigns) do
    ~H"""
    <p
      data-slot={@rest[:"data-slot"] || "item-description"}
      class={[
        upstream_fact("jsx/ItemDescription/class/0"),
        (@class || "")
      ]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "The `item-header` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_header(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-header"}
      class={[upstream_fact("jsx/ItemHeader/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `item-footer` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def item_footer(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "item-footer"}
      class={[upstream_fact("jsx/ItemFooter/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp variant_class(table, group, value),
    do: get_in(@variant_classes, [table, group, value])

  defp item_title_class(nil), do: upstream_fact("jsx/ItemTitle/class/0")

  defp item_title_class(class),
    do: LiveShadcn.Cn.merge([upstream_fact("jsx/ItemTitle/class/0"), class])
end
