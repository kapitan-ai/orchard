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
            ~w(hero-squares-2x2 hero-command-line hero-cube-transparent hero-document-text hero-chevron-double-left hero-bars-3) do
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

    test "renders textarea" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" />|)

      assert html =~ "Bio"
      assert html =~ "<textarea"
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
    test "renders all four nav items" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "Overview"
      assert html =~ "Playground"
      assert html =~ "Models"
      assert html =~ "Requests"
    end

    test "marks active item with aria-current" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ ~s(aria-current="page")
    end

    test "marks disabled items with aria-disabled" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      # Playground, Models, Requests are disabled
      assert html =~ ~s(aria-disabled="true")
    end

    test "active item uses navy accent" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "text-navy"
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
end
