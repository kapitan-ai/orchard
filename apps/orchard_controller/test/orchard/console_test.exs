defmodule OrchardConsoleTest.MissingSentryLiveViewHook do
  @moduledoc false
end

defmodule OrchardConsoleTest.StubSentryLiveViewHook do
  @moduledoc false

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(hook_id, params, session, socket) do
    send(self(), {:stub_sentry_live_view_hook, hook_id, params, session, socket})
    {:cont, %{socket | id: socket.id <> "-hooked"}}
  end
end

defmodule OrchardConsoleTest do
  use ExUnit.Case, async: true

  # SPEC.md §13.1 keeps Build Provenance at the full source commit, but the console
  # sidebar is a fixed 16rem with `white-space: nowrap` and `overflow: hidden`. A full
  # 40-character commit is clipped mid-SHA there and renders as a plausible but wrong
  # shorter SHA, so the sidebar shows an abbreviation derived from the full value.
  # Authenticated `/ops/v1/health` `build_ref` and the Sentry `build_sha` tag carry the
  # full commit.
  describe "display_version/0" do
    test "abbreviates build provenance to seven characters" do
      version = OrchardConsole.display_version()

      case Regex.run(~r/\(([^)]*)\)\z/, version) do
        nil ->
          assert Orchard.BuildInfo.git_sha() == "unknown"

        [_match, provenance] ->
          assert provenance == String.slice(Orchard.BuildInfo.git_sha(), 0, 7)
      end
    end

    test "stays short enough for the fixed-width sidebar" do
      assert String.length(OrchardConsole.display_version()) <= 24
    end
  end

  describe "optional Sentry LiveView hook (issue #191)" do
    @missing_hook_module :"Elixir.OrchardConsoleTest.MissingSentryLiveViewHookNeverDefined"

    test "live_view quote mounts the runtime-gated OrchardConsole hook" do
      source = OrchardConsole.live_view() |> Macro.to_string()

      assert source =~ "maybe_sentry_live_view_hook"
      refute source =~ "on_mount(Sentry.LiveViewHook)"
      refute source =~ "on_mount(Sentry.LiveViewHook,"
    end

    test "reports unavailable when the Sentry hook module is not loaded" do
      refute OrchardConsole.sentry_live_view_hook_available?(@missing_hook_module)
    end

    test "reports unavailable when the module loads without on_mount/4" do
      assert Code.ensure_loaded?(OrchardConsoleTest.MissingSentryLiveViewHook)

      refute OrchardConsole.sentry_live_view_hook_available?(
               OrchardConsoleTest.MissingSentryLiveViewHook
             )
    end

    test "reports available for the real Sentry LiveView hook when compiled in" do
      # Normal umbrella compile order loads LiveView before Sentry, so the hook
      # exists in test. Issue #191 is the inverted compile-order failure mode.
      assert Code.ensure_loaded?(Sentry.LiveViewHook)
      assert function_exported?(Sentry.LiveViewHook, :on_mount, 4)
      assert OrchardConsole.sentry_live_view_hook_available?()
      assert OrchardConsole.sentry_live_view_hook_available?(Sentry.LiveViewHook)
    end

    test "continues mount when the Sentry LiveView hook module is missing" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, ^socket} =
               OrchardConsole.maybe_attach_sentry_live_view_hook(
                 %{},
                 %{},
                 socket,
                 hook_module: @missing_hook_module
               )
    end

    test "continues mount when the module lacks on_mount/4" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, ^socket} =
               OrchardConsole.maybe_attach_sentry_live_view_hook(
                 %{},
                 %{},
                 socket,
                 hook_module: OrchardConsoleTest.MissingSentryLiveViewHook
               )
    end

    test "delegates to the Sentry LiveView hook when the module is loaded" do
      assert Code.ensure_loaded?(OrchardConsoleTest.StubSentryLiveViewHook)
      assert function_exported?(OrchardConsoleTest.StubSentryLiveViewHook, :on_mount, 4)

      assert OrchardConsole.sentry_live_view_hook_available?(
               OrchardConsoleTest.StubSentryLiveViewHook
             )

      socket = %Phoenix.LiveView.Socket{id: "console-sentry-hook"}

      assert {:cont, returned} =
               OrchardConsole.maybe_attach_sentry_live_view_hook(
                 %{"id" => "1"},
                 %{"token" => "session"},
                 socket,
                 hook_module: OrchardConsoleTest.StubSentryLiveViewHook
               )

      assert returned.id == "console-sentry-hook-hooked"

      assert_received {
        :stub_sentry_live_view_hook,
        :default,
        %{"id" => "1"},
        %{"token" => "session"},
        ^socket
      }
    end
  end
end
