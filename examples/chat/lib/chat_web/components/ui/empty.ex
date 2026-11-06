# live_shadcn: empty @ 0.1.0 (74738014de7c)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Empty do
  @moduledoc """
  Empty.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "cva/emptyMediaVariants/base" =>
      "cn-empty-media flex shrink-0 items-center justify-center [&_svg]:pointer-events-none [&_svg]:shrink-0",
    "cva/emptyMediaVariants/default/variant" => "default",
    "cva/emptyMediaVariants/variant/variant/default" => "cn-empty-media-default",
    "cva/emptyMediaVariants/variant/variant/icon" => "cn-empty-media-icon",
    "jsx/Empty/class/0" =>
      "cn-empty flex w-full min-w-0 flex-1 flex-col items-center justify-center text-center text-balance",
    "jsx/EmptyContent/class/0" =>
      "cn-empty-content flex w-full max-w-sm min-w-0 flex-col items-center text-balance",
    "jsx/EmptyDescription/class/0" =>
      "cn-empty-description text-muted-foreground [&>a]:underline [&>a]:underline-offset-4 [&>a:hover]:text-primary",
    "jsx/EmptyHeader/class/0" => "cn-empty-header flex max-w-sm flex-col items-center",
    "jsx/EmptyTitle/class/0" => "cn-empty-title cn-font-heading"
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

  @doc "The `empty` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/Empty/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `empty-header` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty_header(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty-header"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/EmptyHeader/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `empty-title` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty_title(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty-title"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/EmptyTitle/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `empty-description` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty_description(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty-description"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/EmptyDescription/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `empty-content` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty_content(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty-content"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/EmptyContent/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `empty-icon` part."
  attr(:variant, :string,
    default: @upstream_facts["cva/emptyMediaVariants/default/variant"],
    values:
      @variant_classes |> get_in(["emptyMediaVariants", "variant"]) |> Map.keys() |> Enum.sort()
  )

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def empty_media(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "empty-icon"}
      data-variant={@variant}
      class={
        LiveShadcn.Cn.merge([
          upstream_fact("cva/emptyMediaVariants/base"),
          variant_class("emptyMediaVariants", "variant", @variant),
          @class
        ])
      }
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp variant_class(table, group, value),
    do: get_in(@variant_classes, [table, group, value])
end
