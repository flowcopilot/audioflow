# live_shadcn: field @ 0.1.0 (77e9bfdcb2f8)
# Generated from the shadcn registry. Regenerate upstream, never here.
# `mix ui.sync` reports what changed upstream and skips files you edited.

defmodule ChatWeb.Components.UI.Field do
  @moduledoc """
  Field. Groups all parts of the field.

  Reviewed from upstream. The marked upstream fact block is synchronized.
  The HEEx body is maintained as a LiveView port.
  """

  use Phoenix.Component

  # live-shadcn: upstream facts start
  @upstream_facts %{
    "cva/fieldVariants/base" => "cn-field group/field flex w-full",
    "cva/fieldVariants/default/orientation" => "vertical",
    "cva/fieldVariants/variant/orientation/horizontal" =>
      "cn-field-orientation-horizontal flex-row items-center has-[>[data-slot=field-content]]:items-start *:data-[slot=field-label]:flex-auto has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px",
    "cva/fieldVariants/variant/orientation/responsive" =>
      "cn-field-orientation-responsive flex-col *:w-full @md/field-group:flex-row @md/field-group:items-center @md/field-group:*:w-auto @md/field-group:has-[>[data-slot=field-content]]:items-start @md/field-group:*:data-[slot=field-label]:flex-auto [&>.sr-only]:w-auto @md/field-group:has-[>[data-slot=field-content]]:[&>[role=checkbox],[role=radio]]:mt-px",
    "cva/fieldVariants/variant/orientation/vertical" =>
      "cn-field-orientation-vertical flex-col *:w-full [&>.sr-only]:w-auto",
    "jsx/FieldContent/class/0" =>
      "cn-field-content group/field-content flex flex-1 flex-col leading-snug",
    "jsx/FieldError/class/0" => "ml-4 flex list-disc flex-col gap-1",
    "jsx/FieldError/class/1" => "cn-field-error font-normal",
    "jsx/FieldGroup/class/0" =>
      "cn-field-group group/field-group @container/field-group flex w-full flex-col",
    "jsx/FieldLegend/class/0" => "cn-field-legend",
    "jsx/FieldSeparator/class/0" => "cn-field-separator relative",
    "jsx/FieldSeparator/class/1" => "absolute inset-0 top-1/2",
    "jsx/FieldSeparator/class/2" =>
      "cn-field-separator-content relative mx-auto block w-fit bg-background",
    "jsx/FieldSet/class/0" => "cn-field-set flex flex-col",
    "jsx/FieldTitle/class/0" => "cn-field-title flex w-fit items-center",
    "port/class/0" =>
      "cn-field-description leading-normal font-normal group-has-data-horizontal/field:text-balance last:mt-0 nth-last-2:-mt-1 [&>a]:underline [&>a]:underline-offset-4 [&>a:hover]:text-primary",
    "port/class/1" =>
      "cn-field-label group/field-label peer/field-label flex w-fit has-[>[data-slot=field]]:w-full has-[>[data-slot=field]]:flex-col"
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

  @doc "The `field` part."
  attr(:orientation, :string,
    default: @upstream_facts["cva/fieldVariants/default/orientation"],
    values:
      @variant_classes |> get_in(["fieldVariants", "orientation"]) |> Map.keys() |> Enum.sort()
  )

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "field"}
      role="group"
      data-orientation={@orientation}
      class={
        LiveShadcn.Cn.merge([
          upstream_fact("cva/fieldVariants/base"),
          variant_class("fieldVariants", "orientation", @orientation),
          @class
        ])
      }
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `field-label` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot", "for"])
  slot(:inner_block)

  def field_label(assigns) do
    ~H"""
    <LiveShadcn.UI.Label.label
      data-slot={@rest[:"data-slot"] || "field-label"}
      class={LiveShadcn.Cn.merge([upstream_fact("port/class/1"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </LiveShadcn.UI.Label.label>
    """
  end

  @doc "The `field-description` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_description(assigns) do
    ~H"""
    <p
      data-slot={@rest[:"data-slot"] || "field-description"}
      class={[
        upstream_fact("port/class/0"),
        (@class || "")
      ]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc "The `field-error` part."
  attr(:content, :string, default: nil)
  attr(:errors, :list, default: [])
  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_error(assigns) do
    messages =
      assigns.errors
      |> Enum.map(&error_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assigns =
      assigns
      |> assign(:messages, messages)
      |> assign(:render?, assigns.inner_block != [] or assigns.content != nil or messages != [])

    ~H"""
    <div
      :if={@render?}
      data-slot={@rest[:"data-slot"] || "field-error"}
      role="alert"
      class={[upstream_fact("jsx/FieldError/class/1"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        <%= if @content || length(@messages) == 1 do %>
          {@content || List.first(@messages)}
        <% else %>
          <ul class={upstream_fact("jsx/FieldError/class/0")}>
            <li :for={message <- @messages}>{message}</li>
          </ul>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_error), do: nil

  @doc "The `field-group` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_group(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "field-group"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/FieldGroup/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `field-legend` part."
  attr(:variant, :string, default: "legend", values: ["legend", "label"])
  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_legend(assigns) do
    ~H"""
    <legend
      data-slot={@rest[:"data-slot"] || "field-legend"}
      data-variant={@variant}
      class={[upstream_fact("jsx/FieldLegend/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </legend>
    """
  end

  @doc "The `field-separator` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_separator(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "field-separator"}
      data-content={@inner_block != []}
      class={[upstream_fact("jsx/FieldSeparator/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      <LiveShadcn.UI.Separator.separator class={upstream_fact("jsx/FieldSeparator/class/1")} />
      <span
        :if={@inner_block != []}
        data-slot="field-separator-content"
        class={upstream_fact("jsx/FieldSeparator/class/2")}
      >
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc "The `field-set` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_set(assigns) do
    ~H"""
    <fieldset
      data-slot={@rest[:"data-slot"] || "field-set"}
      class={[upstream_fact("jsx/FieldSet/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  @doc "The `field-content` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_content(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "field-content"}
      class={[upstream_fact("jsx/FieldContent/class/0"), (@class || "")]}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc "The `field-label` part."

  attr(:class, :any, default: nil, doc: "Appended to the class string upstream renders.")
  attr(:rest, :global, include: ["data-slot"])
  slot(:inner_block)

  def field_title(assigns) do
    ~H"""
    <div
      data-slot={@rest[:"data-slot"] || "field-label"}
      class={LiveShadcn.Cn.merge([upstream_fact("jsx/FieldTitle/class/0"), @class])}
      {Map.drop(@rest, [:"data-slot"])}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp variant_class(table, group, value),
    do: get_in(@variant_classes, [table, group, value])
end
