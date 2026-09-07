defmodule OrchardConsole.CoreComponentsTest do
  use Orchard.ConnCase, async: true

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.JS
  import Phoenix.Component
  import OrchardConsole.CoreComponents

  # Render a HEEx template to an HTML string for assertion.
  defp render_heex(template) do
    template
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp assert_has_tokens(html, tokens) do
    for token <- tokens do
      assert html =~ token
    end
  end

  @comfortable_metric_tone_contracts %{
    neutral: ["bg-slate-50", "dark:bg-slate-900/60"],
    info: [
      "bg-sky-50/50",
      "ring-1",
      "ring-sky-200/60",
      "dark:bg-sky-900/20",
      "dark:ring-sky-700/30"
    ],
    success: [
      "bg-forest-50/50",
      "ring-1",
      "ring-forest-300/60",
      "dark:bg-emerald-900/20",
      "dark:ring-emerald-700/30"
    ],
    warning: [
      "bg-amber-50/50",
      "ring-1",
      "ring-amber-200/60",
      "dark:bg-amber-900/20",
      "dark:ring-amber-700/30"
    ],
    error: [
      "bg-red-50/50",
      "ring-1",
      "ring-red-200/60",
      "dark:bg-red-900/20",
      "dark:ring-red-700/30"
    ]
  }

  @compact_metric_tone_contracts %{
    neutral: ["border-slate-200", "dark:border-slate-700"],
    info: ["border-sky-200", "dark:border-sky-800"],
    success: ["border-forest-300", "dark:border-emerald-800"],
    warning: ["border-amber-200", "dark:border-amber-800"],
    error: ["border-red-200", "dark:border-red-800"]
  }

  defp assert_medium_input_well_tokens(html) do
    assert_has_tokens(html, [
      "text-sm",
      "border-slate-300",
      "bg-slate-50",
      "shadow-inner",
      "focus-visible:ring-navy/40",
      "dark:bg-slate-900/60"
    ])

    refute html =~ "shadow-sm"
    refute html =~ "dark:border-slate-500"
    refute html =~ "focus:border-navy"
  end

  defp assert_large_input_well_tokens(html) do
    assert_has_tokens(html, ["text-base", "px-3", "py-2"])

    refute html =~ "text-sm"
  end

  defp assert_input_error_tokens(html, type) do
    assert_has_tokens(html, [
      "border-red-500",
      "ring-1",
      "ring-red-500/30",
      "focus-visible:border-red-500",
      "focus-visible:ring-red-500/40",
      "dark:border-red-400",
      "dark:ring-red-400/30",
      "dark:focus-visible:border-red-400",
      "dark:focus-visible:ring-red-400/40"
    ])

    refute html =~ "border-slate-300",
           "#{type} error state must not emit neutral light border"

    refute html =~ "hover:border-slate-400",
           "#{type} error state must not emit neutral light hover border"

    refute html =~ "focus-visible:border-navy",
           "#{type} error state must not emit neutral light focus border"

    refute html =~ "focus-visible:ring-navy/40",
           "#{type} error state must not emit neutral light focus ring"

    refute html =~ "dark:border-slate-700",
           "#{type} error state must not emit neutral dark border"

    refute html =~ "dark:hover:border-slate-600",
           "#{type} error state must not emit neutral dark hover border"

    refute html =~ "dark:focus-visible:border-sky-400",
           "#{type} error state must not emit neutral dark focus border"

    refute html =~ "dark:focus-visible:ring-sky-400/40",
           "#{type} error state must not emit neutral dark focus ring"
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
    test "renders lockup variant with foreground Grove mark and wordmark" do
      assigns = %{}
      html = render_heex(~H|<.logo />|)

      assert html =~ ~s(role="img")
      assert html =~ ~s(aria-label="Orchard")
      assert html =~ "orchard-logo"
      assert html =~ "orchard-mark"
      assert html =~ ~s(aria-hidden="true")
      assert html =~ ~s(focusable="false")
      assert html =~ "orchard-wordmark"
      assert html =~ "orchard-dot--gold"
      assert html =~ "Orchard"
      refute html =~ "icon-192.png"
      refute html =~ "<img"
    end

    test "renders icon-only variant without wordmark" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:icon} />|)

      assert html =~ "orchard-mark"
      refute html =~ "orchard-wordmark"
      refute html =~ ">Orchard<"
    end

    test "renders login variant with brand bar" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:login} />|)

      assert html =~ "orchard-brand-bar"
      assert html =~ "orchard-wordmark"
      assert html |> String.split("<span></span>") |> length() == 5
    end

    test "inline mark emits direct fill fallbacks" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:icon} />|)

      assert html =~ ~s(fill="#1B5E20")
      assert html =~ ~s(fill="#FDD835")
    end

    test "renders voltage variant with enlarged Gold focal dot" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:voltage} />|)

      assert html =~ "orchard-logo--voltage"
      assert html =~ "orchard-mark"
      assert html =~ "orchard-wordmark"
      assert html =~ "orchard-brand-bar"
      assert html =~ ~s(r="7")
      refute html =~ ~r/cx="32"[^>]*cy="12"[^>]*r="6"/
    end

    test "canonical login variant keeps r=6 focal dot" do
      assigns = %{}
      html = render_heex(~H|<.logo variant={:login} />|)

      assert html =~ ~r/cx="32"[^>]*cy="12"[^>]*r="6"/
      refute html =~ ~s(r="7")
    end

    test "applies animation state to the SVG mark" do
      for state <- [:idle, :heartbeat, :cascade, :harvest] do
        assigns = %{state: state}
        html = render_heex(~H|<.logo state={@state} />|)
        assert html =~ ~s(data-state="#{state}")
      end
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

    test "default variant preserves the existing card surface tokens" do
      assigns = %{}
      html = render_heex(~H|<.card>Default card</.card>|)

      assert_has_tokens(html, [
        "rounded-lg",
        "border border-slate-200",
        "bg-white",
        "dark:border-slate-700",
        "dark:bg-slate-800"
      ])

      refute html =~ "ring-navy/10"
      refute html =~ "bg-slate-50"
      refute html =~ "bg-slate-100/70"
    end

    test "primary variant emits distinctive brand emphasis tokens" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card variant={:primary}>
          <:title>Primary</:title>
          Body
        </.card>
        """)

      assert_has_tokens(html, ["ring-navy/10", "dark:ring-sky-400/20", "text-navy"])
    end

    test "secondary variant emits distinctive softened surface tokens" do
      assigns = %{}
      html = render_heex(~H|<.card variant={:secondary}>Secondary card</.card>|)

      assert_has_tokens(html, ["bg-slate-50", "dark:bg-slate-900/40"])
      refute html =~ "bg-white"
    end

    test "rail variant emits distinctive recessed rail tokens" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.card variant={:rail}>
          <:title>Rail</:title>
          <:subtitle>Dense diagnostics</:subtitle>
          Body
        </.card>
        """)

      assert_has_tokens(html, ["bg-slate-100/70", "dark:bg-slate-900/50", "text-sm"])
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
  # Metric and Detail Primitives
  # ===========================================================================

  describe "metric_tile/1" do
    test "comfortable neutral renders canonical label, value, and surface tokens" do
      assigns = %{}

      html =
        render_heex(~H|<.metric_tile id="metric-total" label="Total requests" value="1,024" />|)

      assert html =~ ~s(id="metric-total")
      assert html =~ "Total requests"
      assert html =~ "1,024"

      assert_has_tokens(html, [
        "rounded-lg",
        "px-4",
        "py-3",
        "bg-slate-50",
        "dark:bg-slate-900/60",
        "text-xs",
        "font-medium",
        "uppercase",
        "tracking-wide",
        "mt-1",
        "text-2xl",
        "font-mono"
      ])

      refute html =~ "ring-slate"
      refute html =~ "border-slate-200"
    end

    test "comfortable success renders tinted ring surface tokens" do
      assigns = %{}

      html = render_heex(~H|<.metric_tile label="Healthy" value="3" tone={:success} />|)

      assert_has_tokens(html, [
        "bg-forest-50/50",
        "ring-1",
        "ring-forest-300/60",
        "dark:bg-emerald-900/20",
        "dark:ring-emerald-700/30"
      ])
    end

    test "compact error renders compact typography and border-only tone" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.metric_tile label="Failed" value="2" tone={:error} density={:compact} />|
        )

      assert_has_tokens(html, [
        "rounded-lg",
        "border",
        "px-3",
        "py-2",
        "text-center",
        "border-red-200",
        "dark:border-red-800",
        "text-lg",
        "font-semibold",
        "font-mono",
        "text-xs",
        "text-slate-500",
        "dark:text-slate-400"
      ])

      refute html =~ "bg-red-50/50"
    end

    for {tone, tone_tokens} <- @comfortable_metric_tone_contracts do
      test "comfortable #{tone} renders documented tone and density tokens" do
        assigns = %{tone: unquote(tone)}

        html =
          render_heex(
            ~H|<.metric_tile label="Metric" value="1" tone={@tone} density={:comfortable} />|
          )

        assert_has_tokens(html, [
          "rounded-lg",
          "px-4",
          "py-3",
          "text-xs",
          "font-medium",
          "uppercase",
          "tracking-wide",
          "mt-1",
          "text-2xl",
          "font-mono"
          | unquote(Macro.escape(tone_tokens))
        ])
      end
    end

    for {tone, tone_tokens} <- @compact_metric_tone_contracts do
      test "compact #{tone} renders documented tone and density tokens" do
        assigns = %{tone: unquote(tone)}

        html =
          render_heex(
            ~H|<.metric_tile label="Metric" value="1" tone={@tone} density={:compact} />|
          )

        assert_has_tokens(html, [
          "rounded-lg",
          "border",
          "px-3",
          "py-2",
          "text-center",
          "text-lg",
          "font-semibold",
          "font-mono",
          "text-xs",
          "text-slate-500",
          "dark:text-slate-400"
          | unquote(Macro.escape(tone_tokens))
        ])
      end
    end
  end

  describe "metric_grid/1" do
    test "renders a div grid with caller layout classes" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.metric_grid id="metrics" class="sm:grid-cols-2 xl:grid-cols-4 mb-4">
          <.metric_tile label="Total" value="1" />
        </.metric_grid>
        """)

      assert html =~ ~s(<div id="metrics")
      assert_has_tokens(html, ["grid", "gap-3", "sm:grid-cols-2", "xl:grid-cols-4", "mb-4"])
    end

    test "uses explicit gap_class instead of the default gap" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.metric_grid
          id="metrics"
          gap_class="gap-4"
          class="sm:grid-cols-2 xl:grid-cols-4"
        >
          <.metric_tile label="Total" value="1" />
        </.metric_grid>
        """)

      assert_has_tokens(html, ["grid", "gap-4", "sm:grid-cols-2", "xl:grid-cols-4"])
      refute html =~ "gap-3"
    end
  end

  describe "model_identity/1" do
    test "pins hyphen opportunities while preserving separator breaks and exact text" do
      value = "mlx-community/Qwen3.6-35B-A3B-4bit@38740b847e4cb78f352aba30aa41c76e08e6eb46"
      assigns = %{value: value}

      html =
        render_heex(~H"""
        <.model_identity id="model-identity" value={@value} />
        """)

      document = LazyHTML.from_fragment(html)
      identity = LazyHTML.query(document, "#model-identity")
      segments = LazyHTML.query(document, "#model-identity > span")

      assert LazyHTML.text(identity) == value
      assert LazyHTML.attribute(identity, "class") == ["wrap-anywhere"]

      assert Enum.map(segments, &LazyHTML.text/1) == [
               "mlx",
               "-c",
               "ommunity/",
               "Qwen3.6",
               "-3",
               "5B",
               "-A",
               "3B",
               "-4",
               "bit@",
               "38740b847e4cb78f352aba30aa41c76e08e6eb46"
             ]

      pinned_segments = LazyHTML.query(document, "#model-identity > span.whitespace-nowrap")

      assert Enum.map(pinned_segments, &LazyHTML.text/1) == ["-c", "-3", "-A", "-4"]
      refute Enum.any?(pinned_segments, &(LazyHTML.text(&1) == "-"))

      wbrs = LazyHTML.query(identity, "wbr")
      assert Enum.at(wbrs, 0)
      assert Enum.at(wbrs, 1)
      refute Enum.at(wbrs, 2)

      assert Enum.all?(segments, fn segment ->
               not String.contains?(LazyHTML.text(segment), "-") or
                 "whitespace-nowrap" in LazyHTML.attribute(segment, "class")
             end)
    end

    test "renders a separator-free value with pinned hyphen text" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.model_identity id="model-identity" value="gpt-4" />
        """)

      document = LazyHTML.from_fragment(html)
      identity = LazyHTML.query(document, "#model-identity")
      segments = LazyHTML.query(document, "#model-identity > span")

      assert LazyHTML.text(identity) == "gpt-4"
      assert LazyHTML.attribute(identity, "class") == ["wrap-anywhere"]
      assert Enum.map(segments, &LazyHTML.text/1) == ["gpt", "-4"]

      assert Enum.map(
               LazyHTML.query(document, "#model-identity > span.whitespace-nowrap"),
               &LazyHTML.text/1
             ) == ["-4"]

      assert Enum.empty?(LazyHTML.query(identity, "wbr"))
    end

    test "omits an empty trailing segment after a separator" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.model_identity id="model-identity" value="mlx-community/" />
        """)

      document = LazyHTML.from_fragment(html)
      identity = LazyHTML.query(document, "#model-identity")
      segments = LazyHTML.query(document, "#model-identity > span")

      assert LazyHTML.text(identity) == "mlx-community/"
      assert Enum.map(segments, &LazyHTML.text/1) == ["mlx", "-c", "ommunity/"]
      assert Enum.empty?(LazyHTML.query(identity, "wbr"))
    end

    test "renders separator breaks without pinned chunks" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.model_identity id="model-identity" value="abc@def" />
        """)

      document = LazyHTML.from_fragment(html)
      identity = LazyHTML.query(document, "#model-identity")

      assert LazyHTML.text(identity) == "abc@def"
      assert Enum.empty?(LazyHTML.query(document, "#model-identity > span.whitespace-nowrap"))
      assert Enum.at(LazyHTML.query(identity, "wbr"), 0)
      refute Enum.at(LazyHTML.query(identity, "wbr"), 1)
    end

    test "preserves a trailing hyphen" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.model_identity id="model-identity" value="abc-" />
        """)

      identity =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#model-identity")

      assert LazyHTML.text(identity) == "abc-"
    end
  end

  describe "detail_field/1" do
    test "renders dt and dd with default text-sm value typography" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.detail_field id="request-state" label="State">Completed</.detail_field>
        """)

      assert html =~ ~s(id="request-state")
      assert html =~ "State"
      assert html =~ "Completed"

      assert_has_tokens(html, [
        "text-xs",
        "font-medium",
        "uppercase",
        "tracking-wide",
        "text-slate-500",
        "dark:text-slate-400",
        "mt-1",
        "text-sm",
        "text-slate-900",
        "dark:text-slate-100"
      ])

      refute html =~ "text-base"
      refute html =~ "font-mono"
      refute html =~ "break-all"
    end

    test "optionally renders mono and break-all value tokens" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.detail_field id="model-revision" label="Revision" mono break_all>
          abcdef0123456789
        </.detail_field>
        """)

      assert_has_tokens(html, ["font-mono", "break-all"])
    end

    test "optionally applies value_class to the dd only" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.detail_field id="tenant-detail-name" label="Name" value_class="font-medium">
          Default
        </.detail_field>
        """)

      assert html =~ ~s(<div id="tenant-detail-name" class="">)
      refute html =~ ~s(<div id="tenant-detail-name" class="font-medium">)
      assert html =~ ~s(<dd class="mt-1 text-sm text-slate-900 dark:text-slate-100 font-medium">)
    end
  end

  describe "detail_grid/1" do
    test "renders a dl grid with caller layout classes" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.detail_grid id="details" class="sm:grid-cols-2 lg:grid-cols-4">
          <.detail_field id="detail-name" label="Name">Default</.detail_field>
        </.detail_grid>
        """)

      assert html =~ ~s(<dl id="details")
      assert_has_tokens(html, ["grid", "gap-x-6", "gap-y-4", "sm:grid-cols-2", "lg:grid-cols-4"])
    end

    test "uses explicit gap_class instead of the default gaps" do
      assigns = %{}

      html =
        render_heex(~H"""
        <.detail_grid
          id="details"
          gap_class="gap-4"
          class="sm:grid-cols-2 lg:grid-cols-4"
        >
          <.detail_field id="detail-name" label="Name">Default</.detail_field>
        </.detail_grid>
        """)

      assert_has_tokens(html, ["grid", "gap-4", "sm:grid-cols-2", "lg:grid-cols-4"])
      refute html =~ "gap-x-6"
      refute html =~ "gap-y-4"
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

    test "clickable rows get keyboard accessibility attributes" do
      assigns = %{rows: [%{id: "m1", name: "GPT-4"}]}

      html =
        render_heex(~H"""
        <.table
          id="clickable-test"
          rows={@rows}
          row_click={fn row -> JS.push("select", value: %{id: row.id}) end}
        >
          <:col :let={row} label="Name">{row.name}</:col>
        </.table>
        """)

      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(phx-click=")
      assert html =~ ~s(phx-keydown=")
      assert html =~ ~s(phx-key="Enter")
      assert html =~ "cursor-pointer"
      assert html =~ "focus-visible:bg-sky-50"
    end

    test "non-clickable rows do not get keyboard attributes" do
      assigns = %{rows: [%{name: "Plain"}]}

      html =
        render_heex(~H"""
        <.table id="no-click" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
        </.table>
        """)

      refute html =~ ~s(tabindex="0")
      refute html =~ "phx-keydown"
      refute html =~ ~s(phx-key="Enter")
      refute html =~ "cursor-pointer"
    end

    test "raises ArgumentError when row_click and :action slot are both present" do
      assigns = %{rows: [%{id: "m1", name: "GPT-4"}]}

      assert_raise ArgumentError, ~r/row_click.*action/s, fn ->
        render_heex(~H"""
        <.table
          id="conflict-test"
          rows={@rows}
          row_click={fn row -> JS.push("select", value: %{id: row.id}) end}
        >
          <:col :let={row} label="Name">{row.name}</:col>
          <:action :let={_row}>
            <button>Delete</button>
          </:action>
        </.table>
        """)
      end
    end

    test "raises ArgumentError for row_click + :action even with empty rows" do
      assigns = %{}

      assert_raise ArgumentError, ~r/row_click.*action/s, fn ->
        render_heex(~H"""
        <.table
          id="conflict-empty"
          rows={[]}
          row_click={fn row -> JS.push("select", value: %{id: row}) end}
        >
          <:col label="Name" />
          <:action :let={_row}>
            <button>Delete</button>
          </:action>
        </.table>
        """)
      end
    end

    test "table with :action slot but no row_click renders normally" do
      assigns = %{rows: [%{name: "Item"}]}

      html =
        render_heex(~H"""
        <.table id="action-only" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
          <:action :let={_row}>
            <button>Edit</button>
          </:action>
        </.table>
        """)

      assert html =~ "Edit"
      assert html =~ "Actions"
      refute html =~ ~s(tabindex="0")
      refute html =~ "phx-keydown"
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
  # Theme Toggle
  # ===========================================================================

  describe "theme_toggle/1" do
    test "renders three radio segments with data-theme-mode" do
      assigns = %{}
      html = render_heex(~H|<.theme_toggle />|)

      assert html =~ ~s(role="radiogroup")
      assert html =~ ~s(aria-label="Color theme")
      assert html =~ ~s(phx-hook="ThemeToggle")
      assert html =~ ~s(data-theme-mode="system")
      assert html =~ ~s(data-theme-mode="light")
      assert html =~ ~s(data-theme-mode="dark")
    end

    test "all segments default aria-checked=false for hook activation" do
      assigns = %{}
      html = render_heex(~H|<.theme_toggle />|)

      assert length(Regex.scan(~r/aria-checked="false"/, html)) == 3
      assert html =~ ~s(class="sidebar-label")
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

    test "text input has tactile well rest, hover, focus, disabled, and readonly tokens" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="text" name="user[name]" label="Name" value="" id="name" placeholder="Name" />|
        )

      assert_has_tokens(html, [
        "border",
        "placeholder:text-slate-400",
        "hover:border-slate-400",
        "focus-visible:outline-none",
        "focus-visible:border-navy",
        "focus-visible:ring-2",
        "focus-visible:ring-offset-2",
        "focus-visible:ring-offset-white",
        "disabled:cursor-not-allowed",
        "disabled:bg-slate-100",
        "read-only:bg-slate-100",
        "dark:border-slate-700",
        "dark:hover:border-slate-600",
        "dark:focus-visible:border-sky-400",
        "dark:focus-visible:ring-sky-400/40",
        "dark:focus-visible:ring-offset-slate-900"
      ])

      assert_medium_input_well_tokens(html)
    end

    test "medium text and search inputs keep medium tactile well tokens" do
      assigns = %{}

      text_html = render_heex(~H|<.input type="text" name="name" value="" id="name" />|)
      search_html = render_heex(~H|<.input type="search" name="query" value="" id="query" />|)

      assert_medium_input_well_tokens(text_html)
      assert_medium_input_well_tokens(search_html)
    end

    test "large text and search inputs emit large sizing without medium text conflict" do
      assigns = %{}

      text_html =
        render_heex(~H|<.input size={:lg} type="text" name="name" value="" id="name" />|)

      search_html =
        render_heex(~H|<.input size={:lg} type="search" name="query" value="" id="query" />|)

      assert_large_input_well_tokens(text_html)
      assert_large_input_well_tokens(search_html)
      refute text_html =~ ~s(size="lg")
      refute search_html =~ ~s(size="lg")
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

    test "select input shares tactile well tokens" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="select" name="role" label="Role" options={["Admin", "User"]} value="" id="role" />|
        )

      assert_has_tokens(html, [
        "border",
        "hover:border-slate-400",
        "focus-visible:ring-2",
        "focus-visible:ring-offset-white",
        "dark:focus-visible:ring-sky-400/40",
        "dark:focus-visible:ring-offset-slate-900"
      ])

      assert_medium_input_well_tokens(html)
    end

    test "large select emits large sizing without native size passthrough" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input size={:lg} type="select" name="role" options={["Admin", "User"]} value="" id="role" />|
        )

      assert_large_input_well_tokens(html)
      refute html =~ ~s(size="lg")
    end

    test "renders textarea" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" />|)

      assert html =~ "Bio"
      assert html =~ "<textarea"
    end

    test "textarea shares tactile well tokens" do
      assigns = %{}

      html = render_heex(~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" />|)

      assert_has_tokens(html, [
        "border",
        "hover:border-slate-400",
        "focus-visible:ring-2",
        "focus-visible:ring-offset-white",
        "dark:focus-visible:ring-sky-400/40",
        "dark:focus-visible:ring-offset-slate-900"
      ])

      assert_medium_input_well_tokens(html)
    end

    test "large inputs keep large sizing in error state without neutral border conflicts" do
      assigns = %{}

      for {type, template} <- [
            text:
              ~H|<.input size={:lg} type="text" name="user[name]" value="" id="name" errors={["can't be blank"]} />|,
            search:
              ~H|<.input size={:lg} type="search" name="query" value="" id="query" errors={["Required"]} />|,
            select:
              ~H|<.input size={:lg} type="select" name="role" options={["Admin", "User"]} value="" id="role" errors={["can't be blank"]} />|,
            textarea:
              ~H|<.input size={:lg} type="textarea" name="bio" value="" id="bio" errors={["Required"]} />|
          ] do
        html = render_heex(template)

        assert_large_input_well_tokens(html)
        assert_input_error_tokens(html, type)
      end
    end

    test "large textarea emits large sizing without medium text conflict" do
      assigns = %{}

      html = render_heex(~H|<.input size={:lg} type="textarea" name="bio" value="" id="bio" />|)

      assert_large_input_well_tokens(html)
    end

    test "input error state uses red border tokens without neutral border conflicts" do
      assigns = %{}

      for {type, template} <- [
            text:
              ~H|<.input type="text" name="user[name]" label="Name" value="" id="name" errors={["can't be blank"]} />|,
            select:
              ~H|<.input type="select" name="role" label="Role" options={["Admin", "User"]} value="" id="role" errors={["can't be blank"]} />|,
            textarea:
              ~H|<.input type="textarea" name="bio" label="Bio" value="" id="bio" errors={["can't be blank"]} />|
          ] do
        html = render_heex(template)

        assert_input_error_tokens(html, type)
      end
    end

    test "field input merges explicit errors into tactile red well state" do
      assigns = %{form: to_form(%{"prompt" => ""}, as: :playground)}

      html =
        render_heex(
          ~H|<.input field={@form[:prompt]} type="textarea" label="Message" errors={["Please enter a prompt"]} />|
        )

      assert html =~ "Please enter a prompt"
      assert html =~ ~s(aria-invalid="true")
      assert html =~ ~s(aria-describedby="playground_prompt-errors")
      assert html =~ ~s(id="playground_prompt-errors")
      assert_input_error_tokens(html, :textarea)
    end

    test "input merges existing aria-describedby with error id without duplicate attributes" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="text" name="user[name]" label="Name" value="" id="name" aria-describedby="name-hint" errors={["can't be blank"]} />|
        )

      assert html =~ ~s(aria-invalid="true")
      assert html =~ ~s(aria-describedby="name-hint name-errors")
      assert html =~ ~s(id="name-errors")
      assert html |> String.split(~s(aria-describedby=)) |> length() == 2
    end

    test "errored input overrides caller aria-invalid without duplicate attributes" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="text" name="user[name]" label="Name" value="" id="name" aria-invalid="false" errors={["can't be blank"]} />|
        )

      assert html =~ ~s(aria-invalid="true")
      assert html |> String.split(~s(aria-invalid=)) |> length() == 2
    end

    test "valid input preserves caller-managed aria-invalid" do
      assigns = %{}

      html =
        render_heex(
          ~H|<.input type="text" name="user[name]" label="Name" value="" id="name" aria-invalid="grammar" />|
        )

      assert html =~ ~s(aria-invalid="grammar")
      assert html |> String.split(~s(aria-invalid=)) |> length() == 2
    end

    test "valid input omits generated error aria attributes and error wrapper" do
      assigns = %{}

      html =
        render_heex(~H|<.input type="text" name="user[name]" label="Name" value="" id="name" />|)

      refute html =~ "aria-invalid"
      refute html =~ "aria-describedby"
      refute html =~ ~s(id="name-errors")
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

  describe "models_navigation/1" do
    test "renders Catalog and canonical Discover links" do
      assigns = %{}
      html = render_heex(~H|<.models_navigation active={:catalog} />|)

      assert html =~ ~s(id="models-navigation")
      assert html =~ ~s(aria-label="Models")
      assert html =~ ~s(href="/console/models")
      assert html =~ "Catalog"
      assert html =~ ~s(href="/console/models/discover")
      assert html =~ "Discover"
    end

    test "marks only the selected models destination as current" do
      assigns = %{}
      html = render_heex(~H|<.models_navigation active={:discover} />|)

      assert html =~ ~r/href="\/console\/models\/discover"[^>]*aria-current="page"/
      refute html =~ ~r/href="\/console\/models"[^>]*aria-current="page"/
    end
  end

  describe "sidebar_nav/1" do
    test "renders all nav items" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert html =~ "Overview"
      assert html =~ "Playground"
      assert html =~ "Models"
      refute html =~ "Model Hub"
      assert html =~ "Access"
      assert html =~ "Requests"
      assert html =~ "Settings"
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
      refute html =~ "/console/model-hub"
      assert html =~ "/console/access"
      assert html =~ "/console/settings"
    end

    test "nav items include tactile focus-visible ring tokens" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert_has_tokens(html, [
        "focus-visible:outline-none",
        "focus-visible:ring-2",
        "focus-visible:ring-navy/40",
        "focus-visible:ring-offset-2",
        "focus-visible:ring-offset-slate-100",
        "dark:focus-visible:ring-sky-400/40",
        "dark:focus-visible:ring-offset-slate-800"
      ])
    end

    test "active item uses contained navy accent" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:overview} />|)

      assert_has_tokens(html, [
        "bg-navy/10",
        "text-navy",
        "ring-1",
        "ring-inset",
        "ring-navy/15",
        "dark:bg-sky-400/10",
        "dark:text-sky-400",
        "dark:ring-sky-400/20"
      ])
    end

    test "Playground shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:playground} />|)

      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
      assert html =~ "ring-inset"
    end

    test "Models renders as the single active model-management entry" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:models} />|)

      assert html =~ "/console/models"
      refute html =~ "Model Hub"
      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
      assert html =~ "dark:bg-sky-400/10"
    end

    test "Requests shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:requests} />|)

      assert html =~ "/console/requests"
      refute html =~ "coming soon"
      assert html =~ ~s(aria-current="page")
      assert html =~ "text-navy"
    end

    test "Settings renders as enabled link and shows active styling when active" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:settings} />|)

      assert html =~ "/console/settings"
      refute html =~ "Settings \u2014 coming soon"
      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
      assert html =~ "dark:bg-sky-400/10"
    end

    test "enabled inactive links have lifted tile hover classes" do
      assigns = %{}
      html = render_heex(~H|<.sidebar_nav active={:playground} />|)

      assert_has_tokens(html, [
        "text-slate-600",
        "hover:bg-white",
        "hover:text-slate-900",
        "dark:text-slate-400",
        "dark:hover:bg-slate-700/60",
        "dark:hover:text-slate-100"
      ])

      refute html =~ "hover:bg-slate-100"
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
        year: 2026,
        month: 3,
        day: 31,
        hour: 14,
        minute: 0,
        second: 0,
        microsecond: {0, 6},
        time_zone: "Etc/GMT-2",
        zone_abbr: "+02",
        utc_offset: 7200,
        std_offset: 0,
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
