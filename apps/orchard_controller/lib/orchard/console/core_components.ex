defmodule OrchardConsole.CoreComponents do
  @moduledoc """
  Core UI components for Orchard Console.

  Provides reusable, brand-aligned building blocks: flash messages,
  logo lockup, icons, cards, tables, badges, buttons, and form primitives.
  All components support dark mode via Tailwind `dark:` variants.

  Brand palette reference: `docs/brand-identity.md`.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Form, as: HtmlForm
  alias Phoenix.LiveView.JS

  # ===========================================================================
  # Flash Messages
  # ===========================================================================

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
          "bg-forest-50 text-forest-700 ring-forest/10 fill-forest-900 dark:bg-emerald-900/50 dark:text-emerald-300 dark:ring-emerald-400/20",
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

  # ===========================================================================
  # Icon
  # ===========================================================================

  # Closed set of Heroicons v2.2.0 outline 24px SVG paths.
  @icon_paths %{
    "hero-squares-2x2" =>
      "M3.75 6A2.25 2.25 0 0 1 6 3.75h2.25A2.25 2.25 0 0 1 10.5 6v2.25a2.25 2.25 0 0 1-2.25 2.25H6a2.25 2.25 0 0 1-2.25-2.25V6ZM3.75 15.75A2.25 2.25 0 0 1 6 13.5h2.25a2.25 2.25 0 0 1 2.25 2.25V18a2.25 2.25 0 0 1-2.25 2.25H6A2.25 2.25 0 0 1 3.75 18v-2.25ZM13.5 6a2.25 2.25 0 0 1 2.25-2.25H18A2.25 2.25 0 0 1 20.25 6v2.25A2.25 2.25 0 0 1 18 10.5h-2.25a2.25 2.25 0 0 1-2.25-2.25V6ZM13.5 15.75a2.25 2.25 0 0 1 2.25-2.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-2.25A2.25 2.25 0 0 1 13.5 18v-2.25Z",
    "hero-command-line" =>
      "m6.75 7.5 3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0 0 21 18V6a2.25 2.25 0 0 0-2.25-2.25H5.25A2.25 2.25 0 0 0 3 6v12a2.25 2.25 0 0 0 2.25 2.25Z",
    "hero-cube-transparent" =>
      "m21 7.5-2.25-1.313M21 7.5v2.25m0-2.25-2.25 1.313M3 7.5l2.25-1.313M3 7.5l2.25 1.313M3 7.5v2.25m9 3 2.25-1.313M12 12.75l-2.25-1.313M12 12.75V15m0 6.75 2.25-1.313M12 21.75V19.5m0 2.25-2.25-1.313m0-16.875L12 2.25l2.25 1.313M21 14.25v2.25l-2.25 1.313m-13.5 0L3 16.5v-2.25",
    "hero-document-text" =>
      "M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z",
    "hero-chevron-double-left" => "m18.75 4.5-7.5 7.5 7.5 7.5m-6-15L5.25 12l7.5 7.5",
    "hero-bars-3" => "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5"
  }

  @doc """
  Renders a Heroicon from a closed set of inline SVGs.

  Uses Heroicons v2.2.0 outline 24px variants. New icons can be added
  to the `@icon_paths` module attribute.

  ## Examples

      <.icon name="hero-squares-2x2" class="h-5 w-5" />
      <.icon name="hero-command-line" class="h-5 w-5 text-navy" />
  """
  attr(:name, :string, required: true, doc: "icon name (e.g., hero-squares-2x2)")
  attr(:class, :string, default: nil)

  def icon(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
      aria-hidden="true"
      class={@class}
    >
      <path stroke-linecap="round" stroke-linejoin="round" d={icon_path(@name)} />
    </svg>
    """
  end

  for {name, _path} <- @icon_paths do
    defp icon_path(unquote(name)), do: unquote(Map.fetch!(@icon_paths, name))
  end

  defp icon_path(name), do: raise(ArgumentError, "unknown icon: #{inspect(name)}")

  # ===========================================================================
  # Logo Lockup
  # ===========================================================================

  @doc """
  Renders the Orchard logo lockup.

  Per `docs/brand-identity.md`: icon left + wordmark right when expanded,
  icon only when collapsed. Wordmark in monospace bold, Navy color.

  ## Variants
    - `:lockup` - icon + "Orchard" wordmark (sidebar expanded)
    - `:icon` - icon only (sidebar collapsed)

  ## Examples

      <.logo />
      <.logo variant={:icon} size={:sm} />
  """
  attr(:variant, :atom, default: :lockup, values: [:lockup, :icon])
  attr(:size, :atom, default: :md, values: [:sm, :md, :lg])
  attr(:class, :string, default: "")

  def logo(assigns) do
    ~H"""
    <div class={["flex items-center gap-2.5 logo-lockup", @class]}>
      <img
        src="/images/icon-192.png"
        alt="Orchard"
        class={["rounded-lg flex-shrink-0", logo_icon_size(@size)]}
      />
      <span
        :if={@variant == :lockup}
        class={[
          "font-mono font-bold tracking-tight text-navy dark:text-sky-400",
          "sidebar-label",
          logo_text_size(@size)
        ]}
      >
        Orchard
      </span>
    </div>
    """
  end

  defp logo_icon_size(:sm), do: "h-6 w-6"
  defp logo_icon_size(:md), do: "h-8 w-8"
  defp logo_icon_size(:lg), do: "h-12 w-12"

  defp logo_text_size(:sm), do: "text-sm"
  defp logo_text_size(:md), do: "text-lg"
  defp logo_text_size(:lg), do: "text-2xl"

  # ===========================================================================
  # Card
  # ===========================================================================

  @doc """
  Renders a card container with optional header and footer.

  Uses slate structural colors per brand identity. Cards are the primary
  container for dashboard widgets and content sections.

  ## Examples

      <.card>
        <p>Card body content</p>
      </.card>

      <.card>
        <:title>System Status</:title>
        <:subtitle>Current infrastructure health</:subtitle>
        <p>Content here</p>
      </.card>
  """
  attr(:class, :string, default: "")
  attr(:padding, :atom, default: :md, values: [:none, :sm, :md, :lg])

  slot(:title)
  slot(:subtitle)
  slot(:actions)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800",
      @class
    ]}>
      <div
        :if={@title != [] || @subtitle != [] || @actions != []}
        class={[
          "border-b border-slate-200 dark:border-slate-700",
          card_padding(@padding)
        ]}
      >
        <div class="flex items-center justify-between gap-4">
          <div>
            <h3
              :if={@title != []}
              class="text-base font-semibold text-slate-900 dark:text-slate-100"
            >
              {render_slot(@title)}
            </h3>
            <p
              :if={@subtitle != []}
              class="mt-1 text-sm text-slate-500 dark:text-slate-400"
            >
              {render_slot(@subtitle)}
            </p>
          </div>
          <div :if={@actions != []} class="flex items-center gap-2 flex-shrink-0">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
      <div class={card_padding(@padding)}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp card_padding(:none), do: ""
  defp card_padding(:sm), do: "px-4 py-3"
  defp card_padding(:md), do: "px-6 py-4"
  defp card_padding(:lg), do: "px-8 py-6"

  # ===========================================================================
  # Badge
  # ===========================================================================

  @doc """
  Renders a semantic status badge.

  Tone mapping follows `docs/brand-identity.md`:
    - `:neutral` - slate (default)
    - `:info` - sky
    - `:success` - forest green
    - `:warning` - amber (not Gold; Gold is reserved for CTAs)
    - `:error` - red
    - `:processing` - violet (AI generation/in-progress)

  ## Examples

      <.badge tone={:success}>Online</.badge>
      <.badge tone={:error}>Failed</.badge>
      <.badge tone={:processing}>Generating</.badge>
  """
  attr(:tone, :atom,
    default: :neutral,
    values: [:neutral, :info, :success, :warning, :error, :processing]
  )

  attr(:size, :atom, default: :sm, values: [:sm, :md])
  attr(:class, :string, default: "")

  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full font-medium ring-1 ring-inset",
      badge_size(@size),
      badge_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_size(:sm), do: "px-2 py-0.5 text-xs"
  defp badge_size(:md), do: "px-2.5 py-1 text-sm"

  defp badge_tone(:neutral),
    do:
      "bg-slate-50 text-slate-600 ring-slate-500/10 dark:bg-slate-800 dark:text-slate-300 dark:ring-slate-500/20"

  defp badge_tone(:info),
    do:
      "bg-sky-50 text-sky-700 ring-sky-600/10 dark:bg-sky-900/30 dark:text-sky-300 dark:ring-sky-500/20"

  defp badge_tone(:success),
    do:
      "bg-forest-50 text-forest-700 ring-forest/10 dark:bg-emerald-900/30 dark:text-emerald-400 dark:ring-emerald-400/30"

  defp badge_tone(:warning),
    do:
      "bg-amber-50 text-amber-700 ring-amber-600/10 dark:bg-amber-900/30 dark:text-amber-300 dark:ring-amber-500/20"

  defp badge_tone(:error),
    do:
      "bg-red-50 text-red-700 ring-red-600/10 dark:bg-red-900/30 dark:text-red-300 dark:ring-red-600/20"

  defp badge_tone(:processing),
    do:
      "bg-violet-50 text-violet-700 ring-violet-600/10 dark:bg-violet-900/30 dark:text-violet-300 dark:ring-violet-500/20"

  # ===========================================================================
  # Table
  # ===========================================================================

  @doc """
  Renders a data table with column slots.

  Monospace font is applied to columns with `mono` attribute set,
  per brand identity rule: "monospace for data, sans-serif for UI."

  ## Examples

      <.table id="models" rows={@models}>
        <:col :let={model} label="Name">{model.name}</:col>
        <:col :let={model} label="State" mono>{model.state}</:col>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "function to generate unique row ID from a row")
  attr(:class, :string, default: "")

  slot :col, required: true do
    attr(:label, :string, required: true)
    attr(:class, :string)
    attr(:header_class, :string)
    attr(:mono, :boolean)
  end

  slot(:action, doc: "actions column")
  slot(:empty, doc: "empty state content")

  def table(assigns) do
    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <table class="w-full text-left text-sm">
        <thead class="border-b border-slate-200 text-slate-500 dark:border-slate-700 dark:text-slate-400">
          <tr>
            <th
              :for={col <- @col}
              class={["px-4 py-3 font-medium text-xs uppercase tracking-wide", col[:header_class]]}
            >
              {col.label}
            </th>
            <th :if={@action != []} class="px-4 py-3 font-medium text-right">
              <span class="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} class="divide-y divide-slate-100 dark:divide-slate-700/50">
          <tr :if={@rows == [] && @empty != []} id={"#{@id}-empty"}>
            <td
              colspan={length(@col) + if(@action != [], do: 1, else: 0)}
              class="px-4 py-8 text-center text-slate-400 dark:text-slate-500"
            >
              {render_slot(@empty)}
            </td>
          </tr>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="group hover:bg-slate-50 dark:hover:bg-slate-800/50"
          >
            <td
              :for={col <- @col}
              class={[
                "px-4 py-3 text-slate-900 dark:text-slate-100",
                col[:mono] && "font-mono text-xs",
                col[:class]
              ]}
            >
              {render_slot(col, row)}
            </td>
            <td :if={@action != []} class="px-4 py-3 text-right">
              <span class="flex items-center justify-end gap-2">
                {render_slot(@action, row)}
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ===========================================================================
  # Button
  # ===========================================================================

  @doc """
  Renders a styled button.

  ## Variants
    - `:primary` - Navy filled (default)
    - `:secondary` - neutral outlined
    - `:ghost` - text/hover only
    - `:danger` - red filled

  ## Examples

      <.button>Save</.button>
      <.button variant={:secondary}>Cancel</.button>
      <.button variant={:danger} phx-click="delete">Delete</.button>
  """
  attr(:type, :string, default: "button")
  attr(:variant, :atom, default: :primary, values: [:primary, :secondary, :ghost, :danger])
  attr(:size, :atom, default: :md, values: [:sm, :md])
  attr(:class, :string, default: "")
  attr(:rest, :global, include: ~w(disabled form name value phx-click phx-disable-with))

  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center font-medium rounded-md transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        button_size(@size),
        button_variant(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_size(:sm), do: "px-3 py-1.5 text-sm gap-1.5"
  defp button_size(:md), do: "px-4 py-2 text-sm gap-2"

  defp button_variant(:primary),
    do:
      "bg-navy text-white hover:bg-navy-700 focus-visible:ring-navy dark:bg-sky-500 dark:hover:bg-sky-400 dark:focus-visible:ring-sky-400"

  defp button_variant(:secondary),
    do:
      "border border-slate-300 bg-white text-slate-700 hover:bg-slate-50 focus-visible:ring-navy dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"

  defp button_variant(:ghost),
    do:
      "text-slate-600 hover:text-slate-900 hover:bg-slate-100 focus-visible:ring-navy dark:text-slate-400 dark:hover:text-slate-100 dark:hover:bg-slate-800"

  defp button_variant(:danger),
    do:
      "bg-red-600 text-white hover:bg-red-700 focus-visible:ring-red-500 dark:bg-red-500 dark:hover:bg-red-400"

  # ===========================================================================
  # Form Primitives
  # ===========================================================================

  @doc """
  Renders a form wrapper with consistent styling.

  ## Examples

      <.simple_form for={@form} phx-submit="save">
        <.input field={@form[:name]} label="Name" />
        <:actions>
          <.button type="submit">Save</.button>
        </:actions>
      </.simple_form>
  """
  attr(:for, :any, required: true, doc: "the form data structure")
  attr(:as, :any, default: nil, doc: "the server-side parameter to collect all input under")
  attr(:class, :string, default: "")

  attr(:rest, :global,
    include:
      ~w(autocomplete name rel action enctype method novalidate target multipart phx-change phx-submit phx-target)
  )

  slot(:inner_block, required: true)
  slot(:actions, doc: "form action buttons")

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} class={["space-y-6", @class]} {@rest}>
      <div class="space-y-4">
        {render_slot(@inner_block, f)}
      </div>
      <div :if={@actions != []} class="flex items-center justify-end gap-3 pt-2">
        {render_slot(@actions, f)}
      </div>
    </.form>
    """
  end

  @doc """
  Renders a form input with label and error messages.

  ## Supported types

  Text-like: `text`, `email`, `password`, `number`, `search`, `tel`, `url`,
  `date`, `time`, `datetime-local`.

  Special: `textarea`, `select`, `checkbox`, `hidden`.

  ## Examples

      <.input field={@form[:email]} type="email" label="Email" />
      <.input field={@form[:role]} type="select" label="Role" options={["Admin", "User"]} />
      <.input field={@form[:bio]} type="textarea" label="Bio" />
  """
  attr(:id, :any, default: nil)
  attr(:name, :any)
  attr(:label, :string, default: nil)
  attr(:value, :any)

  attr(:type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email hidden month number password
         range search select tel text textarea time url week)
  )

  attr(:field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"
  )

  attr(:errors, :list, default: [])
  attr(:checked, :boolean, doc: "the checked flag for checkbox inputs")
  attr(:prompt, :string, default: nil, doc: "the prompt for select inputs")
  attr(:options, :list, doc: "the options to pass to HtmlForm.options_for_select/2")
  attr(:multiple, :boolean, default: false, doc: "the multiple flag for select inputs")
  attr(:class, :string, default: "")

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows size step phx-debounce)
  )

  slot(:inner_block)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn ->
      if assigns.multiple, do: field.name <> "[]", else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        HtmlForm.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-300 cursor-pointer">
      <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        class="h-4 w-4 rounded border-slate-300 text-navy focus:ring-navy dark:border-slate-600 dark:bg-slate-800 dark:checked:bg-sky-500 dark:focus:ring-sky-400"
        {@rest}
      />
      {render_slot(@inner_block) || @label}
    </label>
    <.field_errors errors={@errors} />
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        multiple={@multiple}
        class={[
          "mt-1 block w-full rounded-md border-slate-300 bg-white text-slate-900 text-sm",
          "focus:border-navy focus:ring-navy",
          "dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100",
          "dark:focus:border-sky-400 dark:focus:ring-sky-400",
          @errors != [] && "border-red-300 dark:border-red-500",
          @class
        ]}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {HtmlForm.options_for_select(@options, @value)}
      </select>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-1 block w-full rounded-md border-slate-300 bg-white text-slate-900 text-sm",
          "focus:border-navy focus:ring-navy",
          "dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100",
          "dark:focus:border-sky-400 dark:focus:ring-sky-400",
          @errors != [] && "border-red-300 dark:border-red-500",
          @class
        ]}
        {@rest}
      ><%= HtmlForm.normalize_value("textarea", @value) %></textarea>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  # Default: text-like inputs (text, email, password, number, search, etc.)
  def input(assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={HtmlForm.normalize_value(@type, @value)}
        class={[
          "mt-1 block w-full rounded-md border-slate-300 bg-white text-slate-900 text-sm",
          "focus:border-navy focus:ring-navy",
          "dark:border-slate-600 dark:bg-slate-800 dark:text-slate-100",
          "dark:focus:border-sky-400 dark:focus:ring-sky-400",
          @errors != [] && "border-red-300 dark:border-red-500",
          @class
        ]}
        {@rest}
      />
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr(:for, :string, default: nil)
  slot(:inner_block, required: true)

  def label(assigns) do
    ~H"""
    <label for={@for} class="block text-sm font-medium text-slate-700 dark:text-slate-300">
      {render_slot(@inner_block)}
    </label>
    """
  end

  defp field_errors(%{errors: []} = assigns), do: ~H""

  defp field_errors(assigns) do
    ~H"""
    <div class="mt-1 space-y-1">
      <p :for={error <- @errors} class="text-xs text-red-600 dark:text-red-400">
        {error}
      </p>
    </div>
    """
  end

  # ===========================================================================
  # Sidebar Navigation
  # ===========================================================================

  @nav_items [
    %{
      key: :overview,
      label: "Overview",
      icon: "hero-squares-2x2",
      path: "/console",
      enabled: true
    },
    %{
      key: :playground,
      label: "Playground",
      icon: "hero-command-line",
      path: "/console/playground",
      enabled: true
    },
    %{key: :models, label: "Models", icon: "hero-cube-transparent", path: nil, enabled: false},
    %{key: :requests, label: "Requests", icon: "hero-document-text", path: nil, enabled: false}
  ]

  @doc """
  Renders the console sidebar navigation.

  Enabled items render as links; disabled items render as non-interactive
  spans with `aria-disabled="true"` and a tooltip hint.

  ## Examples

      <.sidebar_nav active={:overview} />
  """
  attr(:active, :atom, default: :overview)

  def sidebar_nav(assigns) do
    assigns = assign(assigns, :nav_items, @nav_items)

    ~H"""
    <nav class="flex-1 px-3 py-4 space-y-1" aria-label="Console navigation">
      <div :for={item <- @nav_items}>
        <.link
          :if={item.enabled}
          navigate={item.path}
          title={item.label}
          aria-current={item.key == @active && "page"}
          class={[
            "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
            nav_item_classes(item.key, @active, true)
          ]}
        >
          <.icon name={item.icon} class="h-5 w-5 flex-shrink-0" />
          <span class="sidebar-label truncate">{item.label}</span>
        </.link>
        <span
          :if={!item.enabled}
          aria-disabled={item.key != @active && "true"}
          aria-current={item.key == @active && "page"}
          title={if(item.key != @active, do: "#{item.label} \u2014 coming soon")}
          class={[
            "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium cursor-default",
            nav_item_classes(item.key, @active, false)
          ]}
        >
          <.icon name={item.icon} class="h-5 w-5 flex-shrink-0" />
          <span class="sidebar-label truncate">{item.label}</span>
        </span>
      </div>
    </nav>
    """
  end

  defp nav_item_classes(key, active, _interactive?) when key == active do
    "bg-navy/10 text-navy dark:bg-sky-500/10 dark:text-sky-400"
  end

  defp nav_item_classes(_key, _active, true = _interactive?) do
    "text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-800 dark:hover:text-slate-100"
  end

  defp nav_item_classes(_key, _active, false = _interactive?) do
    "text-slate-400 dark:text-slate-600"
  end

  # ===========================================================================
  # Shell Helpers
  # ===========================================================================

  @doc """
  Returns JS commands to toggle the sidebar collapse state.

  Toggles the `sidebar-collapsed` class on `#console-shell`, which
  triggers CSS transitions for sidebar width, label visibility, and
  toggle icon rotation.
  """
  def toggle_sidebar do
    JS.toggle_class("sidebar-collapsed", to: "#console-shell")
  end

  # ===========================================================================
  # JS Commands
  # ===========================================================================

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

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
