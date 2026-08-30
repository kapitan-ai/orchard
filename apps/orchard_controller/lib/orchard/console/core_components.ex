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
    "hero-magnifying-glass" =>
      "m21 21-4.35-4.35m0 0A7.5 7.5 0 1 0 6.15 6.15a7.5 7.5 0 0 0 10.5 10.5Z",
    "hero-arrow-left" => "M10.5 19.5 3 12m0 0 7.5-7.5M3 12h18",
    "hero-chevron-double-left" => "m18.75 4.5-7.5 7.5 7.5 7.5m-6-15L5.25 12l7.5 7.5",
    "hero-bars-3" => "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5",
    "hero-arrow-path" =>
      "M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99",
    "hero-inbox" =>
      "M2.25 13.5h3.86a2.25 2.25 0 0 1 2.012 1.244l.256.512a2.25 2.25 0 0 0 2.013 1.244h3.218a2.25 2.25 0 0 0 2.013-1.244l.256-.512a2.25 2.25 0 0 1 2.013-1.244h3.859m-19.5.338V18a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18v-4.162c0-.224-.034-.447-.1-.661L19.24 5.338a2.25 2.25 0 0 0-2.15-1.588H6.911a2.25 2.25 0 0 0-2.15 1.588L2.35 13.177a2.25 2.25 0 0 0-.1.661Z",
    "hero-exclamation-triangle" =>
      "M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z",
    "hero-server-stack" =>
      "M5.25 14.25h13.5m-13.5 0a3 3 0 0 1-3-3m3 3a3 3 0 1 0 0 6h13.5a3 3 0 1 0 0-6m-16.5-3a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3m-19.5 0a4.5 4.5 0 0 1 .9-2.7L5.737 5.1a3.375 3.375 0 0 1 2.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 0 1 .9 2.7m0 0a3 3 0 0 1-3 3m0 3h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008ZM6.75 14.25h.008v.008H6.75v-.008Z",
    "hero-check" => "m4.5 12.75 6 6 9-13.5",
    "hero-key" =>
      "M15.75 5.25a3 3 0 0 1 3 3m3 0a6 6 0 0 1-7.029 5.912c-.563-.097-1.159.026-1.563.43L10.5 17.25H8.25v2.25H6v2.25H2.25v-2.818c0-.597.237-1.17.659-1.591l6.499-6.499c.404-.404.527-1 .43-1.563A6 6 0 1 1 21.75 8.25Z",
    "hero-computer-desktop" =>
      "M9 17.25v1.007a3 3 0 0 1-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0 1 15 18.257V17.25m6-12V15a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 15V5.25m18 0A2.25 2.25 0 0 0 18.75 3H5.25A2.25 2.25 0 0 0 3 5.25m18 0V12a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 12V5.25",
    "hero-sun" =>
      "M12 3v2.25m6.364.386-1.591 1.591M21 12h-2.25m-.386 6.364-1.591-1.591M12 18.75V21m-4.773-4.227-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0Z",
    "hero-moon" =>
      "M21.752 15.002A9.718 9.718 0 0 1 18 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 0 0 3 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 0 0 9.002-5.998Z"
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

  Per `docs/brand-identity.md`: foreground Grove Focal mark plus wordmark
  when expanded, mark only when collapsed. The mark intentionally has no plate
  or background so it reads on light and dark surfaces.

  ## Variants
    - `:lockup` - mark + "Orchard" wordmark (sidebar expanded)
    - `:icon` - mark only (sidebar collapsed)
    - `:login` - stacked mark + wordmark + brand bar
    - `:voltage` - stacked login/marketing lockup with enlarged Gold focal dot

  ## States
    - `:idle` - static
    - `:heartbeat` - gold focal dot breathes
    - `:cascade` - rows light bottom-to-top
    - `:harvest` - one-shot success burst

  ## Examples

      <.logo />
      <.logo variant={:icon} size={:sm} />
      <.logo state={:cascade} />
  """
  attr(:variant, :atom, default: :lockup, values: [:lockup, :icon, :login, :voltage])
  attr(:size, :atom, default: :md, values: [:sm, :md, :lg])

  attr(:state, :atom,
    default: :idle,
    values: [:idle, :heartbeat, :cascade, :harvest]
  )

  attr(:class, :string, default: "")

  def logo(assigns) do
    ~H"""
    <div
      class={[
        "orchard-logo logo-lockup",
        "orchard-logo--#{@variant}",
        @class
      ]}
      role="img"
      aria-label="Orchard"
    >
      <.orchard_mark
        size={@size}
        state={@state}
        focal_radius={if @variant == :voltage, do: 7, else: 6}
      />
      <span
        :if={@variant in [:lockup, :login, :voltage]}
        class={[
          "orchard-wordmark sidebar-label",
          logo_text_size(@size)
        ]}
      >
        Orchard
      </span>
      <div :if={@variant in [:login, :voltage]} class="orchard-brand-bar" aria-hidden="true">
        <span></span><span></span><span></span><span></span>
      </div>
    </div>
    """
  end

  attr(:size, :atom, required: true)
  attr(:state, :atom, required: true)
  attr(:focal_radius, :integer, default: 6)

  defp orchard_mark(assigns) do
    ~H"""
    <svg
      class={["orchard-mark flex-shrink-0", logo_icon_size(@size)]}
      data-state={@state}
      viewBox="0 0 64 64"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      focusable="false"
    >
      <g class="orchard-row orchard-row-top">
        <circle cx="12" cy="12" r="3.6" fill="#1B5E20" class="orchard-dot" />
        <circle cx="32" cy="12" r={@focal_radius} fill="#FDD835" class="orchard-dot orchard-dot--gold" />
        <circle cx="52" cy="12" r="3.6" fill="#1B5E20" class="orchard-dot" />
      </g>
      <g class="orchard-row orchard-row-mid">
        <circle cx="12" cy="32" r="3.6" fill="#1B5E20" class="orchard-dot" />
        <circle cx="32" cy="32" r="3.6" fill="#1B5E20" class="orchard-dot" />
        <circle cx="52" cy="32" r="3.6" fill="#1B5E20" class="orchard-dot" />
      </g>
      <g class="orchard-row orchard-row-bot">
        <circle cx="12" cy="52" r="3.6" fill="#1B5E20" class="orchard-dot" />
        <circle cx="32" cy="52" r="3.6" fill="#1B5E20" class="orchard-dot" />
        <circle cx="52" cy="52" r="3.6" fill="#1B5E20" class="orchard-dot" />
      </g>
    </svg>
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
  attr(:variant, :atom, default: :default, values: [:default, :primary, :secondary, :rail])
  attr(:class, :string, default: "")
  attr(:padding, :atom, default: :md, values: [:none, :sm, :md, :lg])

  attr(:header_class, :string,
    default: "",
    doc: "Additional classes applied to the header wrapper."
  )

  attr(:max_height, :string,
    default: nil,
    doc:
      "Tailwind height constraint classes (e.g. `xl:max-h-[calc(100vh-12rem)]`). " <>
        "When set, the card root becomes a flex column with `overflow-hidden`, " <>
        "the header stays in a non-scrolling `shrink-0` region, and the body becomes " <>
        "the sole scroll container (`overflow-y-auto`). This means dropdowns, popovers, " <>
        "or tooltips inside the body will be clipped by the card boundary. " <>
        "A blank string is treated as unset (no constraint applied)."
  )

  slot(:title)
  slot(:subtitle)
  slot(:actions)
  slot(:inner_block, required: true)

  def card(assigns) do
    constrained? = is_binary(assigns.max_height) and String.trim(assigns.max_height) != ""

    assigns =
      assigns
      |> assign(:constrained?, constrained?)
      |> assign(:root_class, card_root_class(assigns.variant))
      |> assign(:title_class, card_title_class(assigns.variant))
      |> assign(:subtitle_class, card_subtitle_class(assigns.variant))

    ~H"""
    <div class={[
      @root_class,
      @constrained? && "flex flex-col overflow-hidden",
      @constrained? && @max_height,
      @class
    ]}>
      <div
        :if={@title != [] || @subtitle != [] || @actions != []}
        class={[
          "border-b border-slate-200 dark:border-slate-700",
          @constrained? && "shrink-0",
          card_padding(@padding),
          @header_class
        ]}
      >
        <div class="flex items-center justify-between gap-4">
          <div>
            <h3
              :if={@title != []}
              class={@title_class}
            >
              {render_slot(@title)}
            </h3>
            <p
              :if={@subtitle != []}
              class={@subtitle_class}
            >
              {render_slot(@subtitle)}
            </p>
          </div>
          <div :if={@actions != []} class="flex items-center gap-2 flex-shrink-0">
            {render_slot(@actions)}
          </div>
        </div>
      </div>
      <div class={[
        card_padding(@padding),
        @constrained? && "flex-1 min-h-0 overflow-y-auto"
      ]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp card_root_class(:default),
    do: "rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800"

  defp card_root_class(:primary),
    do:
      "rounded-lg border border-slate-200 bg-white shadow-sm ring-1 ring-navy/10 dark:border-slate-700 dark:bg-slate-800 dark:ring-sky-400/20"

  defp card_root_class(:secondary),
    do:
      "rounded-lg border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-900/40"

  defp card_root_class(:rail),
    do:
      "rounded-lg border border-slate-200 bg-slate-100/70 dark:border-slate-700 dark:bg-slate-900/50"

  defp card_title_class(:primary), do: "text-base font-semibold text-navy dark:text-sky-400"
  defp card_title_class(:rail), do: "text-sm font-semibold text-slate-900 dark:text-slate-100"

  defp card_title_class(_variant),
    do: "text-base font-semibold text-slate-900 dark:text-slate-100"

  defp card_subtitle_class(:rail), do: "mt-1 text-xs text-slate-500 dark:text-slate-400"
  defp card_subtitle_class(_variant), do: "mt-1 text-sm text-slate-500 dark:text-slate-400"

  defp card_padding(:none), do: ""
  defp card_padding(:sm), do: "px-4 py-3"
  defp card_padding(:md), do: "px-6 py-4"
  defp card_padding(:lg), do: "px-8 py-6"

  # ===========================================================================
  # Disclosure
  # ===========================================================================

  @doc """
  Renders a disclosure section with a summary row and expandable body.

  Preserves the current RequestLive disclosure styling so it can be reused
  by future console surfaces such as Overview quickstart.
  """
  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:default_open, :boolean, default: false)
  attr(:summary_id, :string, default: nil)

  slot(:summary,
    doc:
      "Optional inline-only content rendered below the title inside `<summary>`. " <>
        "Content is placed in a `<span>`, so callers must use phrasing elements only " <>
        "(text, `<span>`, `<strong>`, etc.) — not block containers like `<div>`, `<ul>`, or `<table>`."
  )

  slot(:inner_block, required: true)

  def disclosure_section(assigns) do
    ~H"""
    <div id={@id}>
      <details
        class="rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800"
        {if @default_open, do: [{:open, true}], else: []}
      >
        <summary
          id={@summary_id}
          class="cursor-pointer select-none px-4 py-3 text-base font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-700/50 rounded-lg"
        >
          {@title}
          <span :if={@summary != []} class="mt-1 block text-sm font-normal text-slate-500 dark:text-slate-400">
            {render_slot(@summary)}
          </span>
        </summary>
        <div class="border-t border-slate-200 px-4 py-4 dark:border-slate-700">
          {render_slot(@inner_block)}
        </div>
      </details>
    </div>
    """
  end

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

  Accepts an optional `row_class` callback for per-row styling (e.g. highlighting
  active rows). The callback receives a row and returns a class string or nil.

  When `row_click` is provided, rows are keyboard-accessible: they receive
  `tabindex="0"` for focusability and `phx-keydown` + `phx-key="Enter"` to
  trigger the same JS command as a pointer click.

  `row_click` and the `:action` slot are mutually exclusive. Passing both
  raises `ArgumentError` — use one interaction model per table.

  ## Examples

      <.table id="models" rows={@models} row_class={&row_highlight/1}>
        <:col :let={model} label="Name">{model.name}</:col>
        <:col :let={model} label="State" mono>{model.state}</:col>
      </.table>
  """
  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:row_id, :any, default: nil, doc: "function to generate unique row ID from a row")

  attr(:row_class, :any,
    default: nil,
    doc: "function (row -> class string | nil) for per-row styling"
  )

  attr(:row_click, :any,
    default: nil,
    doc: "function (row -> Phoenix.LiveView.JS command) for row click activation"
  )

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
    if assigns.row_click && assigns.action != [] do
      raise ArgumentError,
            "table/1 does not support row_click and :action slot together. " <>
              "Use row_click for whole-row activation OR :action for per-row controls, not both."
    end

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
          <%!-- Compute row JS once per row, reuse for both click and keydown --%>
          <% row_js = fn row -> @row_click && @row_click.(row) end %>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class={[
              "group hover:bg-slate-50 dark:hover:bg-slate-800/50",
              @row_click && "cursor-pointer focus-visible:outline-none focus-visible:bg-sky-50 focus-visible:dark:bg-sky-900/30",
              @row_class && @row_class.(row)
            ]}
            tabindex={@row_click && "0"}
            phx-click={row_js.(row)}
            phx-keydown={row_js.(row)}
            phx-key={@row_click && "Enter"}
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
  # Metric and Detail Primitives
  # ===========================================================================

  @doc """
  Renders a metric tile for summary counts and performance indicators.

  Use `density={:comfortable}` for dashboard/detail-page metrics and
  `density={:compact}` for summary strips above dense tables.
  """
  attr(:id, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  attr(:tone, :atom,
    default: :neutral,
    values: [:neutral, :info, :success, :warning, :error]
  )

  attr(:density, :atom, default: :comfortable, values: [:compact, :comfortable])
  attr(:class, :string, default: nil)

  def metric_tile(%{density: :comfortable} = assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg px-4 py-3",
        comfortable_metric_tone_class(@tone),
        @class
      ]}
    >
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </p>
      <p class="mt-1 text-2xl font-mono text-slate-900 dark:text-slate-100">
        {@value}
      </p>
    </div>
    """
  end

  def metric_tile(%{density: :compact} = assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg border px-3 py-2 text-center",
        compact_metric_tone_class(@tone),
        @class
      ]}
    >
      <p class="text-lg font-semibold font-mono text-slate-900 dark:text-slate-100">
        {@value}
      </p>
      <p class="text-xs text-slate-500 dark:text-slate-400">
        {@label}
      </p>
    </div>
    """
  end

  @doc """
  Renders a thin metric grid wrapper.
  """
  attr(:id, :string, default: nil)
  attr(:gap_class, :string, default: "gap-3")
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def metric_grid(assigns) do
    ~H"""
    <div id={@id} class={["grid", @gap_class, @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders one detail field as a `<dt>` / `<dd>` pair wrapped for grid placement.
  """
  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:mono, :boolean, default: false)
  attr(:break_all, :boolean, default: false)
  attr(:class, :string, default: nil)
  attr(:value_class, :string, default: nil)
  attr(:title, :string, default: nil)
  slot(:inner_block, required: true)

  def detail_field(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </dt>
      <dd class={[
        "mt-1 text-sm text-slate-900 dark:text-slate-100",
        @mono && "font-mono",
        @break_all && "break-all",
        @value_class
      ]} title={@title}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  @doc """
  Renders a thin detail grid wrapper as a `<dl>`.
  """
  attr(:id, :string, default: nil)
  attr(:gap_class, :string, default: "gap-x-6 gap-y-4")
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def detail_grid(assigns) do
    ~H"""
    <dl id={@id} class={["grid", @gap_class, @class]}>
      {render_slot(@inner_block)}
    </dl>
    """
  end

  defp comfortable_metric_tone_class(:neutral),
    do: "bg-slate-50 dark:bg-slate-900/60"

  defp comfortable_metric_tone_class(:info),
    do: "bg-sky-50/50 ring-1 ring-sky-200/60 dark:bg-sky-900/20 dark:ring-sky-700/30"

  defp comfortable_metric_tone_class(:success),
    do:
      "bg-forest-50/50 ring-1 ring-forest-300/60 dark:bg-emerald-900/20 dark:ring-emerald-700/30"

  defp comfortable_metric_tone_class(:warning),
    do: "bg-amber-50/50 ring-1 ring-amber-200/60 dark:bg-amber-900/20 dark:ring-amber-700/30"

  defp comfortable_metric_tone_class(:error),
    do: "bg-red-50/50 ring-1 ring-red-200/60 dark:bg-red-900/20 dark:ring-red-700/30"

  defp compact_metric_tone_class(:neutral),
    do: "border-slate-200 dark:border-slate-700"

  defp compact_metric_tone_class(:info),
    do: "border-sky-200 dark:border-sky-800"

  defp compact_metric_tone_class(:success),
    do: "border-forest-300 dark:border-emerald-800"

  defp compact_metric_tone_class(:warning),
    do: "border-amber-200 dark:border-amber-800"

  defp compact_metric_tone_class(:error),
    do: "border-red-200 dark:border-red-800"

  # ===========================================================================
  # State Message
  # ===========================================================================

  @doc """
  Renders a consistent loading, empty, or error state message.

  Supports two layouts:
  - `:panel` — full-width card for page-level states (loading/error pages)
  - `:compact` — inline bordered box for in-card or table-empty states

  ## Examples

      <.state_message id="loading" kind={:loading} layout={:panel} title="Loading…" />
      <.state_message id="empty" kind={:empty} layout={:compact} title="No items.">
        <:action>Hint text here</:action>
      </.state_message>
  """
  attr(:id, :string, required: true)
  attr(:kind, :atom, required: true, values: [:loading, :empty, :error])
  attr(:layout, :atom, default: :panel, values: [:panel, :compact])
  attr(:title, :string, default: nil)
  attr(:body, :string, default: nil)

  slot(:action, doc: "optional action content below body")

  def state_message(%{layout: :panel} = assigns) do
    ~H"""
    <div id={@id}>
      <.card>
        <div class="flex items-start gap-4 px-2 py-4">
          <div class={state_icon_badge_class(@kind)}>
            <.icon name={state_icon(@kind)} class={state_icon_class(@kind)} />
          </div>
          <div class="min-w-0 flex-1">
            <p :if={@title} class={["text-sm font-medium", state_title_class(@kind)]}>
              {@title}
            </p>
            <p :if={@body} class="mt-1 text-sm text-slate-500 dark:text-slate-400">
              {@body}
            </p>
            <div :if={@action != []} class="mt-2">
              {render_slot(@action)}
            </div>
          </div>
        </div>
      </.card>
    </div>
    """
  end

  def state_message(%{layout: :compact} = assigns) do
    ~H"""
    <div id={@id} class={["mx-auto max-w-sm rounded-lg border p-3", state_compact_class(@kind)]}>
      <div class="flex items-start gap-2.5">
        <.icon name={state_icon(@kind)} class={state_icon_class(@kind)} />
        <div class="min-w-0 flex-1">
          <p :if={@title} class={["text-sm", state_title_class(@kind)]}>
            {@title}
          </p>
          <p :if={@body} class={["text-xs", if(@title, do: "mt-0.5 text-slate-500 dark:text-slate-400", else: state_title_class(@kind))]}>
            {@body}
          </p>
          <div :if={@action != []} class="mt-1.5 text-xs">
            {render_slot(@action)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp state_icon(:loading), do: "hero-arrow-path"
  defp state_icon(:empty), do: "hero-inbox"
  defp state_icon(:error), do: "hero-exclamation-triangle"

  defp state_icon_class(:loading), do: "h-5 w-5 animate-spin"
  defp state_icon_class(_kind), do: "h-5 w-5"

  defp state_icon_badge_class(:loading),
    do:
      "flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-sky-50 text-sky-600 dark:bg-sky-900/30 dark:text-sky-400"

  defp state_icon_badge_class(:empty),
    do:
      "flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-slate-100 text-slate-400 dark:bg-slate-800 dark:text-slate-500"

  defp state_icon_badge_class(:error),
    do:
      "flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-red-50 text-red-600 dark:bg-red-900/30 dark:text-red-400"

  defp state_compact_class(:loading),
    do: "border-sky-200 bg-sky-50/50 dark:border-sky-800 dark:bg-sky-900/20"

  defp state_compact_class(:empty),
    do: "border-slate-200 bg-slate-50/50 dark:border-slate-700 dark:bg-slate-800/30"

  defp state_compact_class(:error),
    do: "border-red-200 bg-red-50/50 dark:border-red-800 dark:bg-red-900/20"

  defp state_title_class(:loading), do: "text-sky-700 dark:text-sky-300"
  defp state_title_class(:empty), do: "text-slate-600 dark:text-slate-400"
  defp state_title_class(:error), do: "text-red-700 dark:text-red-300"

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
  # Theme Toggle
  # ===========================================================================

  @doc """
  Renders the Console theme preference control.

  The ThemeToggle JavaScript hook reads and writes the `data-theme-mode`
  preference on `<html>`, persists it in a Console-scoped cookie, and updates
  the resolved `data-theme` immediately without a server round-trip.

  This is a single-instance sidebar-footer control; do not render multiple
  copies on one page because the hook uses the stable `theme-toggle` DOM id.
  """
  attr(:class, :string, default: "")

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      phx-hook="ThemeToggle"
      role="radiogroup"
      aria-label="Color theme"
      class={[
        "inline-flex rounded-md bg-slate-100 p-0.5 ring-1 ring-slate-200",
        "dark:bg-slate-800 dark:ring-slate-700",
        @class
      ]}
    >
      <button
        type="button"
        role="radio"
        aria-label="Use system theme"
        aria-checked="false"
        data-theme-mode="system"
        tabindex="0"
        class={theme_segment_class()}
      >
        <.icon name="hero-computer-desktop" class="h-4 w-4 flex-shrink-0" />
        <span class="sidebar-label">System</span>
      </button>
      <button
        type="button"
        role="radio"
        aria-label="Use light theme"
        aria-checked="false"
        data-theme-mode="light"
        tabindex="-1"
        class={theme_segment_class()}
      >
        <.icon name="hero-sun" class="h-4 w-4 flex-shrink-0" />
        <span class="sidebar-label">Light</span>
      </button>
      <button
        type="button"
        role="radio"
        aria-label="Use dark theme"
        aria-checked="false"
        data-theme-mode="dark"
        tabindex="-1"
        class={theme_segment_class()}
      >
        <.icon name="hero-moon" class="h-4 w-4 flex-shrink-0" />
        <span class="sidebar-label">Dark</span>
      </button>
    </div>
    """
  end

  defp theme_segment_class do
    Enum.join(
      [
        "inline-flex min-w-0 items-center justify-center gap-1.5 rounded-md px-2 py-1.5 text-xs font-medium",
        "transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40",
        "focus-visible:ring-offset-2 focus-visible:ring-offset-slate-100",
        "text-slate-500 hover:bg-white/60 hover:text-slate-900",
        "aria-checked:bg-white aria-checked:text-slate-900 aria-checked:shadow-sm",
        "dark:text-slate-400 dark:hover:bg-slate-700/60 dark:hover:text-slate-100",
        "dark:focus-visible:ring-sky-400/40 dark:focus-visible:ring-offset-slate-800",
        "dark:aria-checked:bg-slate-700 dark:aria-checked:text-slate-50"
      ],
      " "
    )
  end

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

  @input_well_shared_classes Enum.join(
                               [
                                 "border bg-slate-50 text-slate-900 shadow-inner",
                                 "placeholder:text-slate-400",
                                 "focus-visible:outline-none",
                                 "focus-visible:ring-2",
                                 "focus-visible:ring-offset-2 focus-visible:ring-offset-white",
                                 "disabled:cursor-not-allowed disabled:bg-slate-100 disabled:text-slate-400",
                                 "read-only:bg-slate-100 read-only:text-slate-500",
                                 "dark:bg-slate-900/60 dark:text-slate-100",
                                 "dark:placeholder:text-slate-500",
                                 "dark:focus-visible:ring-offset-slate-900",
                                 "dark:disabled:bg-slate-800/40 dark:disabled:text-slate-500",
                                 "dark:read-only:bg-slate-800/40 dark:read-only:text-slate-400"
                               ],
                               " "
                             )

  @input_well_classes Enum.join(
                        ["mt-1 block w-full rounded-md text-sm", @input_well_shared_classes],
                        " "
                      )

  @input_well_lg_classes Enum.join(
                           [
                             "mt-1 block w-full rounded-md",
                             "text-base px-3 py-2",
                             @input_well_shared_classes
                           ],
                           " "
                         )

  @input_neutral_state_classes Enum.join(
                                 [
                                   "border-slate-300 hover:border-slate-400 focus-visible:border-navy focus-visible:ring-navy/40",
                                   "dark:border-slate-700 dark:hover:border-slate-600 dark:focus-visible:border-sky-400 dark:focus-visible:ring-sky-400/40"
                                 ],
                                 " "
                               )

  @input_error_classes Enum.join(
                         [
                           "border-red-500 ring-1 ring-red-500/30",
                           "focus-visible:border-red-500 focus-visible:ring-red-500/40",
                           "dark:border-red-400 dark:ring-red-400/30",
                           "dark:focus-visible:border-red-400 dark:focus-visible:ring-red-400/40"
                         ],
                         " "
                       )

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
  attr(:size, :atom, default: :md, values: [:md, :lg])

  attr(:rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
         multiple pattern placeholder readonly required rows step phx-debounce)
  )

  slot(:inner_block)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    field_errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    errors =
      field_errors
      |> Enum.concat(assigns.errors || [])
      |> Enum.map(&normalize_input_error/1)

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, errors)
    |> assign_new(:name, fn ->
      if assigns.multiple, do: field.name <> "[]", else: field.name
    end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assigns
      |> assign_new(:checked, fn ->
        HtmlForm.normalize_value("checkbox", assigns[:value])
      end)
      |> assign_input_aria()

    ~H"""
    <label class="flex items-center gap-2 text-sm text-slate-700 dark:text-slate-300 cursor-pointer">
      <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        aria-invalid={@aria_invalid}
        aria-describedby={@aria_describedby}
        class="h-4 w-4 rounded border-slate-300 text-navy focus-visible:ring-navy dark:border-slate-600 dark:bg-slate-800 dark:checked:bg-sky-500 dark:focus-visible:ring-sky-400"
        {@rest}
      />
      {render_slot(@inner_block) || @label}
    </label>
    <.field_errors id={input_error_id(@id)} errors={@errors} />
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_input_aria(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        multiple={@multiple}
        aria-invalid={@aria_invalid}
        aria-describedby={@aria_describedby}
        class={[
          input_well_classes(@size),
          @errors == [] && input_neutral_state_classes(),
          @errors != [] && input_error_classes(),
          @class
        ]}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {HtmlForm.options_for_select(@options, @value)}
      </select>
      <.field_errors id={input_error_id(@id)} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_input_aria(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        aria-invalid={@aria_invalid}
        aria-describedby={@aria_describedby}
        class={[
          input_well_classes(@size),
          @errors == [] && input_neutral_state_classes(),
          @errors != [] && input_error_classes(),
          @class
        ]}
        {@rest}
      ><%= HtmlForm.normalize_value("textarea", @value) %></textarea>
      <.field_errors id={input_error_id(@id)} errors={@errors} />
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
    assigns = assign_input_aria(assigns)

    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={HtmlForm.normalize_value(@type, @value)}
        aria-invalid={@aria_invalid}
        aria-describedby={@aria_describedby}
        class={[
          input_well_classes(@size),
          @errors == [] && input_neutral_state_classes(),
          @errors != [] && input_error_classes(),
          @class
        ]}
        {@rest}
      />
      <.field_errors id={input_error_id(@id)} errors={@errors} />
    </div>
    """
  end

  defp input_well_classes(:md), do: @input_well_classes
  defp input_well_classes(:lg), do: @input_well_lg_classes

  defp input_neutral_state_classes, do: @input_neutral_state_classes

  defp input_error_classes, do: @input_error_classes

  defp normalize_input_error(error) when is_binary(error), do: error

  defp normalize_input_error({message, options}), do: translate_error({message, options})

  defp normalize_input_error(error), do: to_string(error)

  defp assign_input_aria(assigns) do
    rest = assigns[:rest] || %{}
    errors = assigns[:errors] || []
    existing_aria_invalid = rest[:"aria-invalid"] || rest["aria-invalid"]

    assigns
    |> assign(:aria_invalid, if(errors != [], do: "true", else: existing_aria_invalid))
    |> assign(:aria_describedby, input_describedby(rest, errors, assigns[:id]))
    |> assign(
      :rest,
      Map.drop(rest, [:"aria-describedby", "aria-describedby", :"aria-invalid", "aria-invalid"])
    )
  end

  defp input_describedby(rest, errors, id) do
    existing = rest[:"aria-describedby"] || rest["aria-describedby"]
    error_id = if errors == [], do: nil, else: input_error_id(id)

    [existing, error_id]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      describedby -> describedby
    end
  end

  defp input_error_id(nil), do: nil
  defp input_error_id(""), do: nil
  defp input_error_id(id), do: "#{id}-errors"

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
    <div id={@id} class="mt-1 space-y-1">
      <p :for={error <- @errors} class="text-xs text-red-600 dark:text-red-400">
        {error}
      </p>
    </div>
    """
  end

  # ===========================================================================
  # Sidebar Navigation
  # ===========================================================================

  @sidebar_nav_item_classes Enum.join(
                              [
                                "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium",
                                "transition-colors",
                                "focus-visible:outline-none",
                                "focus-visible:ring-2 focus-visible:ring-navy/40",
                                "focus-visible:ring-offset-2 focus-visible:ring-offset-slate-100",
                                "dark:focus-visible:ring-sky-400/40",
                                "dark:focus-visible:ring-offset-slate-800"
                              ],
                              " "
                            )

  defp sidebar_nav_item_classes, do: @sidebar_nav_item_classes

  @nav_items [
    %{
      key: :overview,
      label: "Overview",
      icon: "hero-squares-2x2",
      path: "/console",
      enabled: true
    },
    %{
      key: :nodes,
      label: "Nodes",
      icon: "hero-server-stack",
      path: "/console/nodes",
      enabled: true
    },
    %{
      key: :playground,
      label: "Playground",
      icon: "hero-command-line",
      path: "/console/playground",
      enabled: true
    },
    %{
      key: :models,
      label: "Models",
      icon: "hero-cube-transparent",
      path: "/console/models",
      enabled: true
    },
    %{
      key: :model_hub,
      label: "Model Hub",
      icon: "hero-magnifying-glass",
      path: "/console/model-hub",
      enabled: true
    },
    %{
      key: :tenants,
      label: "Organizations",
      icon: "hero-key",
      path: "/console/tenants",
      enabled: true
    },
    %{
      key: :requests,
      label: "Requests",
      icon: "hero-document-text",
      path: "/console/requests",
      enabled: true
    },
    %{
      key: :settings,
      label: "Settings",
      icon: "hero-computer-desktop",
      path: "/console/settings",
      enabled: true
    }
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
            sidebar_nav_item_classes(),
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
            sidebar_nav_item_classes(),
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
    "bg-navy/10 text-navy ring-1 ring-inset ring-navy/15 dark:bg-sky-400/10 dark:text-sky-400 dark:ring-sky-400/20"
  end

  defp nav_item_classes(_key, _active, true = _interactive?) do
    "text-slate-600 hover:bg-white hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700/60 dark:hover:text-slate-100"
  end

  defp nav_item_classes(_key, _active, false = _interactive?) do
    "text-slate-400 cursor-default dark:text-slate-600"
  end

  # ===========================================================================
  # Local Time
  # ===========================================================================

  @doc """
  Renders a timestamp as a `<time>` element with client-side local time formatting.

  The server renders a UTC fallback text inside the element. The `LocalTime` JS hook
  reformats it to the browser's local timezone on mount and LiveView patch.

  Supported input types for `value`:
  - `DateTime` — used directly
  - `NaiveDateTime` — interpreted as UTC
  - ISO 8601 binary string — parsed; invalid strings rendered as-is without the hook
  - `nil` — renders the placeholder text (default `"—"`)

  ## Format options

  - `:datetime_minute` — `2026-03-31 12:34 UTC` (default)
  - `:datetime_second` — `2026-03-31 12:34:56 UTC`
  - `:time_second` — `12:34:56 UTC`
  - `:date` — `2026-03-31`

  ## Examples

      <.local_time value={@request.inserted_at} />
      <.local_time value={@node.last_heartbeat_at} format={:datetime_second} />
      <.local_time value={@last_updated_at} format={:time_second} />
      <.local_time value={nil} placeholder="N/A" />
  """
  attr(:value, :any, required: true, doc: "DateTime, NaiveDateTime, ISO 8601 string, or nil")

  attr(:format, :atom,
    default: :datetime_minute,
    values: [:datetime_minute, :datetime_second, :time_second, :date],
    doc: "display format tier"
  )

  attr(:placeholder, :string, default: "—", doc: "text shown when value is nil")
  attr(:id, :string, default: nil)
  attr(:class, :string, default: "")

  def local_time(assigns) do
    assigns =
      assigns
      |> assign(:normalized, normalize_local_time(assigns.value, assigns.placeholder))
      |> then(fn a ->
        if a.id, do: a, else: assign(a, :id, "lt-#{System.unique_integer([:positive])}")
      end)

    case assigns.normalized do
      {:interactive, dt} ->
        iso = DateTime.to_iso8601(dt)
        text = format_utc_fallback(dt, assigns.format)

        assigns =
          assigns
          |> assign(:iso, iso)
          |> assign(:text, text)

        ~H"""
        <time
          id={@id}
          class={@class}
          datetime={@iso}
          title={@iso}
          phx-hook="LocalTime"
          data-local-time-format={@format}
        ><%= @text %></time>
        """

      {:static, text} ->
        assigns = assign(assigns, :text, text)

        ~H"""
        <time id={@id} class={@class}><%= @text %></time>
        """
    end
  end

  defp normalize_local_time(nil, placeholder), do: {:static, placeholder}
  defp normalize_local_time("", placeholder), do: {:static, placeholder}

  defp normalize_local_time(%DateTime{} = dt, _placeholder) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> then(&{:interactive, &1})
  end

  defp normalize_local_time(%NaiveDateTime{} = ndt, _placeholder) do
    ndt
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive!("Etc/UTC")
    |> then(&{:interactive, &1})
  end

  defp normalize_local_time(value, _placeholder) when is_binary(value) do
    with {:error, _} <- parse_iso_datetime(value),
         {:error, _} <- parse_iso_naive(value) do
      {:static, value}
    else
      {:ok, dt} -> {:interactive, DateTime.truncate(dt, :second)}
    end
  end

  defp normalize_local_time(_, placeholder), do: {:static, placeholder}

  defp parse_iso_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} = err -> err
    end
  end

  defp parse_iso_naive(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
      {:error, _} = err -> err
    end
  end

  @local_time_formats %{
    datetime_minute: "%Y-%m-%d %H:%M UTC",
    datetime_second: "%Y-%m-%d %H:%M:%S UTC",
    time_second: "%H:%M:%S UTC",
    date: "%Y-%m-%d"
  }

  defp format_utc_fallback(dt, format) do
    Calendar.strftime(dt, Map.fetch!(@local_time_formats, format))
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
