defmodule OrchardConsole.CoreComponents do
  @moduledoc """
  Minimal core UI components for Orchard Console.

  Provides flash messages and foundational components.
  Extended in Week 2 with cards, tables, badges, and forms.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
  """
  attr(:id, :string, doc: "the optional id of flash container")
  attr(:flash, :map, default: %{}, doc: "the map of flash messages")
  attr(:title, :string, default: nil)
  attr(:kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup")
  attr(:rest, :global, doc: "the arbitrary HTML attributes to add to the flash container")

  slot(:inner_block, doc: "the optional inner block that renders the flash message")

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1",
        @kind == :info &&
          "bg-forest-50 text-forest-700 ring-forest/10 fill-forest-900 dark:bg-forest-900/50 dark:text-forest-300 dark:ring-forest/20",
        @kind == :error &&
          "bg-red-50 text-red-700 ring-red-600/10 fill-red-900 dark:bg-red-900/50 dark:text-red-300 dark:ring-red-600/20"
      ]}
      {@rest}
    >
      <p class="text-sm leading-5 font-medium">
        <span :if={@title} class="mr-1 font-semibold"><%= @title %></span>
        <%= msg %>
      </p>
      <button type="button" class="group absolute top-1 right-1 p-2" aria-label="close">
        <span class="text-lg leading-none opacity-40 group-hover:opacity-70">&times;</span>
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard flash kinds.
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group")

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  ## JS Commands

  defp hide(js, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end
end
