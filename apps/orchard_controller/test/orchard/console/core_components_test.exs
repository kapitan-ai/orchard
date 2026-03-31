defmodule OrchardConsole.CoreComponentsTest do
  use Orchard.ConnCase, async: true

  alias Phoenix.HTML.Safe
  import Phoenix.Component
  import OrchardConsole.CoreComponents

  # Render a HEEx template to an HTML string for assertion.
  defp render_heex(template) do
    template
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # ===========================================================================
  # Flash
  # ===========================================================================

  describe "flash/1" do
    test "renders info flash with forest light and emerald dark tokens" do
      assigns = %{}

      html =
        render_heex(~H|<.flash kind={:info} flash={%{"info" => "Test message"}} />|)

      assert html =~ "Test message"
      # Light mode: forest tokens
      assert html =~ "bg-forest-50"
      assert html =~ "text-forest-700"
      # Dark mode: emerald tokens per brand-identity.md
      assert html =~ "dark:text-emerald-300"
      assert html =~ "dark:bg-emerald-900/50"
      # Must NOT have dark forest tokens
      refute html =~ "dark:text-forest"
      refute html =~ "dark:bg-forest"
    end

    test "renders error flash with red tokens" do
      assigns = %{}

      html =
        render_heex(~H|<.flash kind={:error} flash={%{"error" => "Error occurred"}} />|)

      assert html =~ "Error occurred"
      assert html =~ "bg-red-50"
      assert html =~ "dark:text-red-300"
    end
  end

  # ===========================================================================
  # Icon
  # ===========================================================================

  describe "icon/1" do
    test "renders SVG with known icon name" do
      assigns = %{}
      html = render_heex(~H|<.icon name="hero-squares-2x2" class="h-5 w-5" />|)

      assert html =~ "<svg"
      assert html =~ "h-5 w-5"
      assert html =~ "aria-hidden=\"true\""
      assert html =~ "<path"
    end

    test "renders all registered icons without error" do
      for name <-
            ~w(hero-squares-2x2 hero-command-line hero-cube-transparent hero-document-text hero-magnifying-glass hero-chevron-double-left hero-bars-3 hero-arrow-left hero-arrow-path hero-inbox hero-exclamation-triangle hero-key) do
        assigns = %{name: name}
        html = render_heex(~H|<.icon name={@name} />|)
        assert html =~ "<svg", "icon #{name} should render an SVG"
      end
    end

    test "raises on unknown icon name" do
      assert_raise ArgumentError, ~r/unknown icon/, fn ->
        assigns = %{}
        render_heex(~H|<.icon name="hero-nonexistent" />|)
      end
    end
  end

  # ===========================================================================
  # Logo
  # ===========================================================================

  describe "logo/1" do
    test "renders lockup variant with icon and wordmark" do
      assigns = %{}
      html = render_heex(~H|<.logo />|)

      assert html =~ "icon-192.png"
      assert html =~ "Orchard"
      assert html =~ "font-mono"
      assert html =~ "font-bold"
    end

    test "renders icon-only variant without wordmark" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:icon} />|)

      assert html =~ "icon-192.png"
      refute html =~ ">Orchard<"
    end

    test "applies size classes" do
      assigns = %{}

      sm = render_heex(~H|<.logo size={:sm} variant={:icon} />|)
      assert sm =~ "h-6 w-6"

      lg = render_heex(~H|<.logo size={:lg} variant={:icon} />|)
      assert lg =~ "h-12 w-12"
    end
  end

  # ===========================================================================
  # Card
  # ===========================================================================

  describe "card/1" do
    test "renders body content" do
      assigns = %{}
      html = render_heex(~H|<.card>Body content</.card>|)

      assert html =~ "Body content"
      assert html =~ "rounded-lg"
      assert html =~ "border-slate-200"
    end

    test "renders header with title and subtitle" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card>
          <:title>Test Title</:title>
          <:subtitle>Test Subtitle</:subtitle>
          Body
        </.card>
        """)

      assert html =~ "Test Title"
      assert html =~ "Test Subtitle"
      assert html =~ "Body"
    end

    test "renders actions slot" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card>
          <:title>Title</:title>
          <:actions><button>Action</button></:actions>
          Body
        </.card>
        """)

      assert html =~ "Action"
    end

    test "omits header when no title/subtitle/actions" do
      assigns = %{}
      html = render_heex(~H|<.card>Just body</.card>|)

      # No border-b divider when there's no header
      refute html =~ "border-b"
    end

    test "default card does not include scroll/flex classes" do
      assigns = %{}
      html = render_heex(~H|<.card>Normal card</.card>|)

      refute html =~ "flex flex-col overflow-hidden"
      refute html =~ "overflow-y-auto"
      refute html =~ "min-h-0"
    end

    test "max_height card renders constrained flex layout with scrollable body" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card max_height="xl:max-h-[calc(100vh-12rem)]">
          <:title>Constrained</:title>
          <:subtitle>With scroll</:subtitle>
          Scrollable body
        </.card>
        """)

      # Root has flex column + overflow hidden + max-height
      assert html =~ "flex flex-col overflow-hidden"
      assert html =~ "xl:max-h-[calc(100vh-12rem)]"
      # Header has shrink-0
      assert html =~ "shrink-0"
      # Body has scroll classes
      assert html =~ "flex-1"
      assert html =~ "min-h-0"
      assert html =~ "overflow-y-auto"
      assert html =~ "Scrollable body"
    end

    test "max_height card without header still scrolls body" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card max_height="max-h-96">
          Headerless scrollable
        </.card>
        """)

      assert html =~ "flex flex-col overflow-hidden"
      assert html =~ "max-h-96"
      assert html =~ "overflow-y-auto"
      refute html =~ "shrink-0"
    end

    test "blank max_height is treated as unset" do
      assigns = %{}
      html = render_heex(~H|<.card max_height="  ">Normal</.card>|)

      refute html =~ "flex flex-col overflow-hidden"
      refute html =~ "overflow-y-auto"
    end
  end

  # ===========================================================================
  # Disclosure
  # ===========================================================================

  describe "disclosure_section/1" do
    test "renders wrapper, summary, and body content" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="test-disclosure" title="Debug Details">
          <p>Section body</p>
        </.disclosure_section>
        """)

      assert html =~ ~s(id="test-disclosure")
      assert html =~ "<details"
      assert html =~ "<summary"
      assert html =~ "Debug Details"
      assert html =~ "Section body"
    end

    test "applies open attribute when default_open is true" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="open-disclosure" title="Open" default_open={true}>
          <p>Body</p>
        </.disclosure_section>
        """)

      assert html =~ ~r/<details[^>]*\bopen\b/
    end

    test "omits open attribute when default_open is false" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="closed-disclosure" title="Closed" default_open={false}>
          <p>Body</p>
        </.disclosure_section>
        """)

      refute html =~ "<details open"
    end

    test "applies summary_id when provided" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section
          id="summary-id-disclosure"
          title="With Summary ID"
          summary_id="summary-anchor"
        >
          <p>Body</p>
        </.disclosure_section>
        """)

      assert html =~ ~s(<summary id="summary-anchor")
    end

    test "omits summary id when summary_id is nil" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="no-summary-id" title="Without Summary ID">
          <p>Body</p>
        </.disclosure_section>
        """)

      refute html =~ ~s(<summary id="")
      refute html =~ ~s(<summary id=)
    end

    test "renders summary slot content below the title" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="summary-slot-test" title="Repository files">
          <:summary>14 files — 17.2 GB total</:summary>
          <p>File table here</p>
        </.disclosure_section>
        """)

      assert html =~ "Repository files"
      assert html =~ "14 files"
      assert html =~ "17.2 GB total"
      assert html =~ "File table here"
    end

    test "omits summary span when summary slot is not provided" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.disclosure_section id="no-summary-slot" title="Debug Details">
          <p>Body</p>
        </.disclosure_section>
        """)

      assert html =~ "Debug Details"
      refute html =~ "mt-1 block text-sm font-normal"
    end
  end

  # ===========================================================================
  # Badge
  # ===========================================================================

  describe "badge/1" do
    test "renders content with default neutral tone" do
      assigns = %{}
      html = render_heex(~H|<.badge>Status</.badge>|)

      assert html =~ "Status"
      assert html =~ "slate"
    end

    test "renders success tone with forest light and emerald dark colors" do
      assigns = %{}
      html = render_heex(~H|<.badge tone={:success}>Online</.badge>|)

      assert html =~ "Online"
      # Light mode: forest tokens
      assert html =~ "bg-forest-50"
      assert html =~ "text-forest-700"
      # Dark mode: emerald tokens per brand-identity.md mapping
      assert html =~ "dark:text-emerald-400"
      # Must NOT have dark forest tokens
      refute html =~ "dark:text-forest"
    end

    test "renders error tone with red colors" do
      assigns = %{}
      html = render_heex(~H|<.badge tone={:error}>Failed</.badge>|)

      assert html =~ "Failed"
      assert html =~ "red"
    end

    test "renders processing tone with violet colors" do
      assigns = %{}
      html = render_heex(~H|<.badge tone={:processing}>Generating</.badge>|)

      assert html =~ "Generating"
      assert html =~ "violet"
    end

    test "renders warning tone with amber colors" do
      assigns = %{}
      html = render_heex(~H|<.badge tone={:warning}>Degraded</.badge>|)

      assert html =~ "Degraded"
      assert html =~ "amber"
    end

    test "renders info tone with sky colors" do
      assigns = %{}
      html = render_heex(~H|<.badge tone={:info}>Notice</.badge>|)

      assert html =~ "Notice"
      assert html =~ "sky"
    end

    test "supports md size" do
      assigns = %{}
      html = render_heex(~H|<.badge size={:md}>Large</.badge>|)

      assert html =~ "px-2.5"
    end
  end

  # ===========================================================================
  # Table
  # ===========================================================================

  describe "table/1" do
    test "renders rows with column slots" do
      assigns = %{
        rows: [
          %{name: "GPT-4", state: "active"},
          %{name: "Llama-3", state: "loading"}
        ]
      }

      html =
        render_heex(~H"""
        <.table id="test-table" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:col :let={row} label="State" mono>{row.state}</:col>
        </.table>
        """)

      assert html =~ "Name"
      assert html =~ "State"
      assert html =~ "GPT-4"
      assert html =~ "Llama-3"
      assert html =~ "active"
      assert html =~ "font-mono"
    end

    test "renders empty state when rows are empty" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.table id="empty-test" rows={[]}>
          <:col label="Name" />
          <:empty>No results found.</:empty>
        </.table>
        """)

      assert html =~ "No results found."
    end

    test "renders column headers with uppercase tracking" do
      assigns = %{rows: []}

      html =
        render_heex(~H"""
        <.table id="header-test" rows={@rows}>
          <:col label="Model Name" />
        </.table>
        """)

      assert html =~ "uppercase"
      assert html =~ "Model Name"
    end

    test "applies row_class callback to matching rows" do
      assigns = %{
        rows: [
          %{name: "Active", highlighted: true},
          %{name: "Inactive", highlighted: false}
        ]
      }

      row_class = fn
        %{highlighted: true} -> "bg-green-50"
        _ -> nil
      end

      assigns = Map.put(assigns, :row_class, row_class)

      html =
        render_heex(~H"""
        <.table id="rc-test" rows={@rows} row_class={@row_class}>
          <:col :let={row} label="Name">{row.name}</:col>
        </.table>
        """)

      # Highlighted row gets custom class
      assert html =~ "bg-green-50"
      # Both rows still get the default group/hover classes
      assert html =~ "group"
      assert html =~ "hover:bg-slate-50"
    end

    test "row_class nil leaves default classes intact" do
      assigns = %{rows: [%{name: "Plain"}]}

      html =
        render_heex(~H"""
        <.table id="no-rc" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
        </.table>
        """)

      assert html =~ "group"
      assert html =~ "hover:bg-slate-50"
      refute html =~ "bg-green"
    end
  end

  # ===========================================================================
  # State Message
  # ===========================================================================

  describe "state_message/1" do
    test "renders panel layout with card structure" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="test-panel" kind={:loading} layout={:panel} title="Loading…" body="Please wait.">
          <:action>Retry</:action>
        </.state_message>
        """)

      assert html =~ ~s(id="test-panel")
      assert html =~ "Loading…"
      assert html =~ "Please wait."
      assert html =~ "Retry"
    end

    test "renders compact layout with bordered box" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="test-compact" kind={:empty} layout={:compact} title="No items." />
        """)

      assert html =~ ~s(id="test-compact")
      assert html =~ "No items."
      assert html =~ "mx-auto"
      assert html =~ "rounded-lg"
    end

    test "loading kind renders spinner icon" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="spin" kind={:loading} layout={:panel} title="Loading" />
        """)

      assert html =~ "animate-spin"
      assert html =~ "bg-sky-50"
    end

    test "error kind renders red tones" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="err" kind={:error} layout={:compact} title="Failed" />
        """)

      assert html =~ "border-red-200"
      assert html =~ "text-red-700"
    end

    test "empty kind renders neutral tones" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="mt" kind={:empty} layout={:compact} title="Nothing here" />
        """)

      assert html =~ "border-slate-200"
      assert html =~ "text-slate-600"
    end

    test "body-only compact renders body with title class when no title" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.state_message id="body-only" kind={:empty} layout={:compact} body="Some descriptive text." />
        """)

      assert html =~ "Some descriptive text."
      assert html =~ "text-slate-600"
    end
  end

  # ===========================================================================
  # Button
  # ===========================================================================

  describe "button/1" do
    test "renders primary variant by default" do
      assigns = %{}
      html = render_heex(~H|<.button>Save</.button>|)

      assert html =~ "Save"
      assert html =~ "bg-navy"
      assert html =~ "type=\"button\""
    end

    test "renders secondary variant" do
      assigns = %{}
      html = render_heex(~H|<.button variant={:secondary}>Cancel</.button>|)

      assert html =~ "Cancel"
      assert html =~ "border-slate-300"
    end

    test "renders ghost variant" do
      assigns = %{}
      html = render_heex(~H|<.button variant={:ghost}>More</.button>|)

      assert html =~ "More"
      refute html =~ "bg-navy"
    end

    test "renders danger variant" do
      assigns = %{}
      html = render_heex(~H|<.button variant={:danger}>Delete</.button>|)

      assert html =~ "Delete"
      assert html =~ "bg-red"
    end

    test "renders sm size" do
      assigns = %{}
      html = render_heex(~H|<.button size={:sm}>Small</.button>|)

      assert html =~ "py-1.5"
    end
  end

  # ===========================================================================
  # Input
  # ===========================================================================

  describe "input/1" do
    test "renders text input with label" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="text" name="user[name]" label="Name" value="" id="name" />|)

      assert html =~ "Name"
      assert html =~ ~s(type="text")
      assert html =~ ~s(name="user[name]")
    end

    test "text input has visible borders, shadow, and focus-visible ring" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="text" name="user[name]" label="Name" value="" id="name" />|)

      assert html =~ "border-slate-400"
      assert html =~ "shadow-sm"
      assert html =~ "dark:border-slate-500"
      assert html =~ "focus-visible:border-navy"
      assert html =~ "focus-visible:ring-navy"
      refute html =~ "border-slate-300"
      refute html =~ "focus:border-navy"
    end

    test "renders select input with options" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="select" name="role" label="Role" options={["Admin", "User"]} value="" id="role" />|
        )

      assert html =~ "Role"
      assert html =~ "<select"
      assert html =~ "Admin"
      assert html =~ "User"
    end

    test "select input has visible borders, shadow, and focus-visible ring" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="select" name="role" label="Role" options={["Admin", "User"]} value="" id="role" />|
        )

      assert html =~ "border-slate-400"
      assert html =~ "shadow-sm"
      assert html =~ "dark:border-slate-500"
      assert html =~ "focus-visible:border-navy"
      assert html =~ "focus-visible:ring-navy"
      refute html =~ "border-slate-300"
      refute html =~ "focus:border-navy"
    end

    test "renders textarea" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" />|)

      assert html =~ "Bio"
      assert html =~ "<textarea"
    end

    test "textarea has visible borders, shadow, and focus-visible ring" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" />|)

      assert html =~ "border-slate-400"
      assert html =~ "shadow-sm"
      assert html =~ "dark:border-slate-500"
      assert html =~ "focus-visible:border-navy"
      assert html =~ "focus-visible:ring-navy"
      refute html =~ "border-slate-300"
      refute html =~ "focus:border-navy"
    end

    test "renders checkbox" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="checkbox" name="agree" label="I agree" value="false" id="agree" />|
        )

      assert html =~ "I agree"
      assert html =~ ~s(type="checkbox")
    end

    test "checkbox uses focus-visible ring, not focus ring" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="checkbox" name="agree" label="Agree" value="false" id="agree-fv" />|
        )

      assert html =~ "focus-visible:ring-navy"
      assert html =~ "dark:focus-visible:ring-sky-400"
      refute html =~ "focus:ring-navy"
      refute html =~ "dark:focus:ring-sky-400"
    end

    test "renders hidden input" do
      assigns = %{}
      html = render_heex(~H|<.input type="hidden" name="token" value="abc123" id="token" />|)

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(value="abc123")
    end
  end

  # ===========================================================================
  # Sidebar Navigation
  # ===========================================================================

  describe "sidebar_nav/1" do
    test "renders all six nav items" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "Overview"
      assert html =~ "Playground"
      assert html =~ "Models"
      assert html =~ "Model Hub"
      assert html =~ "Tenants"
      assert html =~ "Requests"
    end

    test "marks active item with aria-current" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ ~s(aria-current="page")
    end

    test "renders Playground as enabled link" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "/console/playground"
      refute html =~ "Playground \u2014 coming soon"
    end

    test "all nav items are enabled" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      refute html =~ ~s(aria-disabled="true")
      refute html =~ "coming soon"
      assert html =~ "/console/requests"
      assert html =~ "/console/models"
      assert html =~ "/console/model-hub"
      assert html =~ "/console/tenants"
    end

    test "active item uses navy accent" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "text-navy"
    end

    test "Playground shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:playground} />|)

      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
    end

    test "Model Hub renders as enabled link and shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:model_hub} />|)

      assert html =~ "/console/model-hub"
      refute html =~ "Model Hub \u2014 coming soon"
      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
    end

    test "Requests shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:requests} />|)

      assert html =~ "/console/requests"
      refute html =~ "coming soon"
      assert html =~ ~s(aria-current="page")
      assert html =~ "text-navy"
    end

    test "enabled links have hover classes" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:playground} />|)

      # Overview (inactive enabled) should have hover classes
      assert html =~ "hover:bg-slate-100"
    end
  end

  # ===========================================================================
  # Toggle Sidebar
  # ===========================================================================

  describe "toggle_sidebar/0" do
    test "returns JS commands targeting console shell" do
      js = toggle_sidebar()
      assert %Phoenix.LiveView.JS{} = js
    end
  end

  # ===========================================================================
  # Local Time
  # ===========================================================================

  describe "local_time/1" do
    test "DateTime renders interactive <time> with hook attrs" do
      assigns = %{dt: ~U[2026-03-31 12:34:56.789Z]}

      html = render_heex(~H|<.local_time value={@dt} />|)

      assert html =~ "<time"
      assert html =~ ~s(datetime="2026-03-31T12:34:56Z")
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="datetime_minute")
      assert html =~ "2026-03-31 12:34 UTC"
      # title attr preserves full UTC ISO for tooltip
      assert html =~ ~s(title="2026-03-31T12:34:56Z")
    end

    test "DateTime truncates microseconds" do
      assigns = %{dt: ~U[2026-03-31 12:34:56.123456Z]}

      html = render_heex(~H|<.local_time value={@dt} format={:datetime_second} />|)

      assert html =~ ~s(datetime="2026-03-31T12:34:56Z")
      assert html =~ "2026-03-31 12:34:56 UTC"
      refute html =~ "123456"
    end

    test "non-UTC DateTime is shifted to UTC before rendering" do
      # Construct a +02:00 DateTime (14:00 local = 12:00 UTC)
      dt = %DateTime{
        year: 2026, month: 3, day: 31,
        hour: 14, minute: 0, second: 0, microsecond: {0, 6},
        time_zone: "Etc/GMT-2", zone_abbr: "+02",
        utc_offset: 7200, std_offset: 0,
        calendar: Calendar.ISO
      }

      assigns = %{dt: dt}

      html = render_heex(~H|<.local_time value={@dt} />|)

      # datetime and title should be the UTC instant
      assert html =~ ~s(datetime="2026-03-31T12:00:00Z")
      assert html =~ ~s(title="2026-03-31T12:00:00Z")
      # Fallback text is UTC wall-clock, not original +02:00 wall-clock
      assert html =~ "2026-03-31 12:00 UTC"
      refute html =~ "14:00"
    end

    test "NaiveDateTime renders as UTC with Z suffix" do
      assigns = %{ndt: ~N[2026-03-31 08:15:00]}

      html = render_heex(~H|<.local_time value={@ndt} />|)

      assert html =~ "<time"
      assert html =~ ~s(datetime="2026-03-31T08:15:00Z")
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ "2026-03-31 08:15 UTC"
    end

    test "valid ISO string with offset renders interactive" do
      assigns = %{iso: "2026-03-31T14:00:00+02:00"}

      html = render_heex(~H|<.local_time value={@iso} />|)

      assert html =~ "<time"
      assert html =~ ~s(phx-hook="LocalTime")
      # Normalized to UTC: 14:00 +02:00 = 12:00 UTC
      assert html =~ ~s(datetime="2026-03-31T12:00:00Z")
      assert html =~ "2026-03-31 12:00 UTC"
    end

    test "valid ISO string without timezone treated as UTC" do
      assigns = %{iso: "2026-03-31T09:30:00"}

      html = render_heex(~H|<.local_time value={@iso} />|)

      assert html =~ ~s(datetime="2026-03-31T09:30:00Z")
      assert html =~ ~s(phx-hook="LocalTime")
    end

    test "nil renders placeholder without hook" do
      assigns = %{}

      html = render_heex(~H|<.local_time value={nil} />|)

      assert html =~ "<time"
      assert html =~ "\u2014"
      refute html =~ "phx-hook"
      refute html =~ "datetime="
    end

    test "nil with custom placeholder" do
      assigns = %{}

      html = render_heex(~H|<.local_time value={nil} placeholder="N/A" />|)

      assert html =~ "N/A"
      refute html =~ "phx-hook"
    end

    test "invalid string renders raw text without hook" do
      assigns = %{val: "not-a-date"}

      html = render_heex(~H|<.local_time value={@val} />|)

      assert html =~ "<time"
      assert html =~ "not-a-date"
      refute html =~ "phx-hook"
      refute html =~ "datetime="
    end

    test "empty string renders placeholder without hook" do
      assigns = %{val: ""}

      html = render_heex(~H|<.local_time value={@val} />|)

      assert html =~ "\u2014"
      refute html =~ "phx-hook"
    end

    test "format :datetime_minute renders minute precision" do
      assigns = %{dt: ~U[2026-03-31 12:34:56Z]}

      html = render_heex(~H|<.local_time value={@dt} format={:datetime_minute} />|)

      assert html =~ ~s(data-local-time-format="datetime_minute")
      assert html =~ "2026-03-31 12:34 UTC"
      refute html =~ "2026-03-31 12:34:56"
    end

    test "format :datetime_second renders second precision" do
      assigns = %{dt: ~U[2026-03-31 12:34:56Z]}

      html = render_heex(~H|<.local_time value={@dt} format={:datetime_second} />|)

      assert html =~ ~s(data-local-time-format="datetime_second")
      assert html =~ "2026-03-31 12:34:56 UTC"
    end

    test "format :time_second renders time only" do
      assigns = %{dt: ~U[2026-03-31 12:34:56Z]}

      html = render_heex(~H|<.local_time value={@dt} format={:time_second} />|)

      assert html =~ ~s(data-local-time-format="time_second")
      # Fallback text is time-only; date appears in datetime/title attrs but not display text
      assert html =~ ">12:34:56 UTC</time>"
    end

    test "format :date renders date only" do
      assigns = %{dt: ~U[2026-03-31 12:34:56Z]}

      html = render_heex(~H|<.local_time value={@dt} format={:date} />|)

      assert html =~ ~s(data-local-time-format="date")
      # Fallback text is date-only; time appears in datetime/title attrs but not display text
      assert html =~ ">2026-03-31</time>"
    end

    test "id and class attrs are passed through" do
      assigns = %{dt: ~U[2026-03-31 12:00:00Z]}

      html = render_heex(~H|<.local_time value={@dt} id="my-time" class="text-sm" />|)

      assert html =~ ~s(id="my-time")
      assert html =~ ~s(class="text-sm")
    end
  end
end
