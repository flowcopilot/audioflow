# live_shadcn: alert @ 0.1.0 (5f2d5d144da3)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Alert do
  @moduledoc """
  Alert.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "cva/alertVariants/base" => "cn-alert group/alert relative w-full",
    "cva/alertVariants/default/variant" => "default",
    "cva/alertVariants/variant/variant/default" => "cn-alert-variant-default",
    "cva/alertVariants/variant/variant/destructive" => "cn-alert-variant-destructive",
    "jsx/AlertAction/class/0" => "cn-alert-action",
    "jsx/AlertDescription/class/0" =>
      "cn-alert-description [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground",
    "jsx/AlertTitle/class/0" =>
      "cn-alert-title [&_a]:underline [&_a]:underline-offset-3 [&_a]:hover:text-foreground"
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

  @doc "The `alert` part."
  attr(:variant, :string,
    default: @upstream_facts["cva/alertVariants/default/variant"],
    values: @variant_classes |> get_in(["alertVariants", "variant"]) |> Map.keys() |> Enum.sort()
  )

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def alert(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "alert"}
      role="alert"
      class={
        LiveShadcn.Cn.merge([
          upstream_fact("cva/alertVariants/base"),
          variant_class("alertVariants", "variant", @variant),
          @class
        ])
      }
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `alert-title` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def alert_title(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "alert-title"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/AlertTitle/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `alert-description` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def alert_description(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "alert-description"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/AlertDescription/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `alert-action` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def alert_action(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "alert-action"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/AlertAction/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp variant_class(table, group, value),
    do: get_in(@variant_classes, [table, group, value])
end
