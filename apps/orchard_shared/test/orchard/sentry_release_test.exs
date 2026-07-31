defmodule Orchard.SentryReleaseTest do
  use ExUnit.Case, async: true

  alias Orchard.SentryRelease

  @build_opts [
    build_sha: "abcdef0123456789abcdef0123456789abcdef01",
    build_date: "2026-07-30",
    build_channel: "internal"
  ]

  test "builds controller release identity from Product Version and provenance" do
    identity = SentryRelease.identity("orchard_controller", "0.5.0-dev", @build_opts)

    assert identity.release == "orchard_controller@0.5.0-dev+abcdef0"

    assert identity.tags == %{
             orchard_app: "controller",
             orchard_version: "0.5.0-dev",
             orchard_build_channel: "internal",
             build_sha: "abcdef0123456789abcdef0123456789abcdef01",
             build_date: "2026-07-30"
           }
  end

  test "runtime identity derives from canonical OTP Product Version and BuildInfo" do
    identity = SentryRelease.identity("orchard_controller")

    assert identity.tags.orchard_version == OrchardShared.version()
    assert identity.tags.orchard_build_channel == Orchard.BuildInfo.build_channel()
    assert identity.tags.build_sha == Orchard.BuildInfo.git_sha()
    assert identity.tags.build_date == Orchard.BuildInfo.build_date()
    assert String.starts_with?(identity.release, "orchard_controller@#{OrchardShared.version()}+")
  end

  test "runtime options keep optional Sentry crash-only and data-minimized" do
    options = SentryRelease.runtime_options("orchard_node_agent")

    assert options[:before_send] == {Orchard.SentryFilter, :filter}
    assert options[:server_name] == "[redacted]"
    assert options[:tags].orchard_app == "node_agent"

    assert options[:in_app_otp_apps] ==
             [:orchard_controller, :orchard_node_agent, :orchard_shared, :orchard_cli]

    assert options[:enable_source_code_context] == false
    assert options[:traces_sample_rate] == nil
    assert Keyword.has_key?(options, :traces_sampler)
    assert options[:traces_sampler] == nil
    assert options[:enable_logs] == false
    assert options[:report_deps] == false
    assert options[:send_client_reports] == false
    assert options[:dedup_events] == true
    refute Keyword.has_key?(options, :dsn)
    refute Keyword.has_key?(options, :environment_name)
  end

  test "maps packaged Node Agent and CLI release names without mislabeling source development" do
    assert SentryRelease.identity("orchard_node_agent", "0.5.0-dev", @build_opts).tags.orchard_app ==
             "node_agent"

    assert SentryRelease.identity("orchard_cli", "0.5.0-dev", @build_opts).tags.orchard_app ==
             "cli"

    assert SentryRelease.identity("mix", "0.5.0-dev", @build_opts).tags.orchard_app ==
             "development"

    assert SentryRelease.identity("unexpected", "0.5.0-dev", @build_opts).tags.orchard_app ==
             "unknown"
  end

  test "falls back safely when provenance values are malformed" do
    identity =
      SentryRelease.identity("orchard_controller", "0.5.0-dev",
        build_sha: "bad\nrelease",
        build_date: "not-a-date",
        build_channel: "internal\nsecret"
      )

    assert identity.release == "orchard_controller@0.5.0-dev+unknown"
    assert identity.tags.build_sha == "unknown"
    assert identity.tags.build_date == "unknown"
    assert identity.tags.orchard_build_channel == "unknown"
  end
end
