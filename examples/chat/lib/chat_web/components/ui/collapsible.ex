# live_shadcn: collapsible @ 0.1.0 (f426fb14dbc2)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Collapsible do
  @moduledoc """
  Collapsible. Groups all parts of the collapsible.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.

  | Upstream | Digest |
  |---|---|
  | `shadcn/ui/collapsible.tsx` | `ead4349ff7b0` |
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{}
  # live-shadcn: upstream facts end
  Module.get_attribute(__MODULE__, :upstream_facts)

  alias LiveBase.Disclosure
  alias Phoenix.LiveView.JS

  @doc """
  Groups all parts of the collapsible.

      <.collapsible id="details" title="Show details">
        The panel body.
      </.collapsible>

  The local toggle runs on the client. Set `phx-click` on the trigger to send
  a server event or run a caller JS command after the toggle. `trigger_attrs`
  accepts the same command on the grouped component.
  """
  attr(:id, :string, required: true, doc: "Every id inside the component derives from it.")
  attr(:title, :any, default: nil, doc: "The trigger content when no trigger slot is given.")
  attr(:composed, :boolean, default: false, doc: "Render caller-owned trigger and content parts.")

  attr(:controlled, :boolean, default: false, doc: "Let server assigns own the disclosure state.")
  attr(:open, :boolean,
    default: false,
    doc:
      "Whether the collapsible panel is initially open. To render a controlled collapsible, use the `open` prop instead."
  )

  attr(:disabled, :boolean,
    default: false,
    doc: "Whether the component should ignore user interaction."
  )

  attr(:orientation, :string, default: "vertical", doc: "")
  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:content_class, :any, default: nil, doc: "Appended to the content class string.")
  attr(:trigger_class, :any, default: nil, doc: "Appended to the trigger class string.")
  attr(:trigger_attrs, :map, default: %{}, doc: "Attributes merged onto the trigger button.")

  attr(:wrapper_tag, :string,
    default: nil,
    doc: "An optional element around the trigger and panel."
  )

  attr(:wrapper_attrs, :map, default: %{}, doc: "Attributes for the optional wrapper.")
  attr(:rest, :global)

  slot(:trigger, doc: "Rich trigger content.")
  slot(:inner_block, required: true, doc: "The panel body.")

  def collapsible(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "collapsible"}
      id={@id}
      data-open={flag(@open)}
      data-closed={flag(not @open)}
      class={[@class]}
      phx-mounted={if not @controlled, do: Disclosure.owned_attributes(:item)}
      {Map.drop(@rest, [:"data-slot"])}
    ><%= if @composed do %>{render_slot(@inner_block)}<% else %>
      <.dynamic_tag :if={@wrapper_tag} tag_name={@wrapper_tag} {@wrapper_attrs}>
        <.collapsible_parts {assigns} />
      </.dynamic_tag>
      <.collapsible_parts :if={is_nil(@wrapper_tag)} {assigns} />
      <% end %></div>
    """
  end

  defp collapsible_parts(assigns) do
    ~H"""
    <.collapsible_trigger
      for={@id}
      open={@open}
      controlled={@controlled}
      disabled={@disabled}
      class={@trigger_class}
      {@trigger_attrs}
    >
      {if(@trigger == [], do: @title, else: render_slot(@trigger))}
    </.collapsible_trigger>
    <.collapsible_content
      for={@id}
      open={@open}
      controlled={@controlled}
      class={@content_class}
    >
      {render_slot(@inner_block)}
    </.collapsible_content>
    """
  end

  @doc "The button that opens or closes a composed collapsible."
  attr(:for, :string, required: true, doc: "The id of the collapsible root.")
  attr(:controlled, :boolean, default: false, doc: "Let server assigns own the disclosure state.")
  attr(:open, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ["data-slot", "type"])
  slot(:inner_block, required: true)

  def collapsible_trigger(assigns) do
    ~H"""
    <button
      data-slot={@rest[:"data-slot"] || "collapsible-trigger"}
      id={Disclosure.trigger_id(@for)}
      type={@rest[:type] || "button"}
      aria-expanded={to_string(@open)}
      aria-disabled={to_string(@disabled)}
      aria-controls={Disclosure.panel_id(@for)}
      phx-click={
        interactive(
          @disabled,
          caller_click(
            if(@controlled, do: %JS{}, else: Disclosure.toggle(item: @for, root: @for, multiple: true)),
            @rest[:"phx-click"]
          )
        )
      }
      phx-mounted={if not @controlled, do: Disclosure.owned_attributes(:trigger)}
      data-panel-open={flag(@open)}
      disabled={@disabled}
      class={@class}
      {Map.drop(@rest, [:"data-slot", :type, :"phx-click"])}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc "The panel that a composed collapsible shows or hides."
  attr(:for, :string, required: true, doc: "The id of the collapsible root.")
  attr(:controlled, :boolean, default: false, doc: "Let server assigns own the disclosure state.")
  attr(:open, :boolean, default: false)
  attr(:class, :any, default: nil)
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block, required: true)

  def collapsible_content(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "collapsible-content"}
      id={Disclosure.panel_id(@for)}
      aria-labelledby={Disclosure.trigger_id(@for)}
      hidden={not @open}
      phx-hook={Disclosure.hook()}
      phx-mounted={if not @controlled, do: Disclosure.owned_attributes(:panel)}
      data-lb-height-var="--collapsible-panel-height"
      data-lb-width-var="--collapsible-panel-width"
      data-open={flag(@open)}
      data-closed={flag(not @open)}
      class={@class}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp caller_click(command, nil), do: command
  defp caller_click(command, ""), do: command
  defp caller_click(command, %JS{} = caller), do: JS.concat(command, caller)
  defp caller_click(command, event) when is_binary(event), do: JS.push(command, event)

  # A disabled disclosure ignores interaction. `aria-disabled` and
  # `pointer-events-none` say so to a reader and to a mouse, but a keypress
  # on a focused trigger reaches neither, so the command itself is withheld.
  defp interactive(false, command), do: command
  defp interactive(_disabled, _command), do: nil

  # An HTML attribute with no value, or no attribute at all. Base UI marks
  # state by presence, so `data-open=""` and a missing `data-open` are the
  # two states a shadcn class string distinguishes.
  defp flag(true), do: ""
  defp flag(_state), do: nil
end
