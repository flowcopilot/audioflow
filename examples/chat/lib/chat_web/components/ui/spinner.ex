# live_shadcn: spinner @ 0.1.0 (9c51174dc24f)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Spinner do
  @moduledoc """
  Spinner.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "jsx/Spinner/class/0" => "size-4 animate-spin"
  }
  # live-shadcn: upstream facts end
  Module.get_attribute(__MODULE__, :upstream_facts)

  defp upstream_fact(key), do: Map.fetch!(@upstream_facts, key)

  @doc "The `spinner` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def spinner(assigns) do
    ~H"""
    <LiveShadcn.Icon.icon
      name="loader-circle"
      data-slot={@rest[:"data-slot"] || "spinner"}
      role="status"
      aria-label="Loading"
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/Spinner/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    />
    """
  end
end
