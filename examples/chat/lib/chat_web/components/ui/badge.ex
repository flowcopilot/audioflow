# live_shadcn: badge @ 0.1.0 (97ad001d2caf)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Badge do
  @moduledoc """
  Badge.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "cva/badgeVariants/base" =>
      "cn-badge group/badge inline-flex w-fit shrink-0 items-center justify-center overflow-hidden whitespace-nowrap focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 aria-invalid:border-destructive aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 [&>svg]:pointer-events-none",
    "cva/badgeVariants/default/variant" => "default",
    "cva/badgeVariants/variant/variant/default" => "cn-badge-variant-default",
    "cva/badgeVariants/variant/variant/destructive" => "cn-badge-variant-destructive",
    "cva/badgeVariants/variant/variant/ghost" => "cn-badge-variant-ghost",
    "cva/badgeVariants/variant/variant/link" => "cn-badge-variant-link",
    "cva/badgeVariants/variant/variant/outline" => "cn-badge-variant-outline",
    "cva/badgeVariants/variant/variant/secondary" => "cn-badge-variant-secondary"
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

  @doc "The `badge` part."
  attr(:variant, :string,
    default: @upstream_facts["cva/badgeVariants/default/variant"],
    values: @variant_classes |> get_in(["badgeVariants", "variant"]) |> Map.keys() |> Enum.sort()
  )

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:href, :string, default: nil, doc: "Renders the badge as a link when set.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def badge(assigns) do
    assigns =
      assign(assigns, :classes, [
        variant_class("badgeVariants", "variant", assigns.variant),
        upstream_fact("cva/badgeVariants/base"),
        assigns.class
      ])

    ~H"""
    <a
      :if={@href}
      href={@href}
      data-slot={@rest[:"data-slot"] || "badge"}
      data-variant={@variant}
      class={@classes}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </a>
    <span
      :if={!@href}
      data-slot={@rest[:"data-slot"] || "badge"}
      data-variant={@variant}
      class={@classes}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp variant_class(table, group, value),
    do: get_in(@variant_classes, [table, group, value])
end
