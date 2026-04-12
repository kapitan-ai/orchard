defmodule Orchard.Node.ToolCapabilityCatalogTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{HostedToolCapability, HostedToolReadiness}
  alias Orchard.Node.ToolCapabilityCatalog

  test "build_snapshot returns empty lists for absent or invalid collections" do
    assert %{capabilities: [], readiness: []} = ToolCapabilityCatalog.build_snapshot(nil)
    assert %{capabilities: [], readiness: []} = ToolCapabilityCatalog.build_snapshot(%{})
  end

  test "build_snapshot deduplicates tool identities deterministically" do
    snapshot =
      ToolCapabilityCatalog.build_snapshot([
        %{name: "zeta", version: "2026-04-12", adapter_kind: "adapter-z"},
        %{
          name: "alpha",
          version: "2026-04-10",
          adapter_kind: "adapter-a",
          ready: false,
          readiness_code: "warming",
          readiness_message: "warming up"
        },
        %{name: "alpha", version: "2026-04-10", adapter_kind: "adapter-b", ready: true}
      ])

    assert snapshot.capabilities == [
             %HostedToolCapability{
               name: "alpha",
               version: "2026-04-10",
               adapter_kind: "adapter-a"
             },
             %HostedToolCapability{
               name: "zeta",
               version: "2026-04-12",
               adapter_kind: "adapter-z"
             }
           ]

    assert snapshot.readiness == [
             %HostedToolReadiness{
               name: "alpha",
               version: "2026-04-10",
               ready: false,
               readiness_code: "warming",
               readiness_message: "warming up"
             },
             %HostedToolReadiness{
               name: "zeta",
               version: "2026-04-12",
               ready: true,
               readiness_code: "",
               readiness_message: ""
             }
           ]
  end

  test "build_snapshot drops malformed hosted tool identities" do
    snapshot =
      ToolCapabilityCatalog.build_snapshot([
        %{name: "bad tool", version: "2026-04-10", adapter_kind: "adapter-a"},
        %{name: "bad-version", version: "2026 04 10", adapter_kind: "adapter-b"},
        %{name: "missing-version", adapter_kind: "adapter-b"},
        %{name: "missing-adapter", version: "2026-04-10"},
        :not_a_map,
        %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "adapter-c"}
      ])

    assert snapshot.capabilities == [
             %HostedToolCapability{
               name: "lookup_docs",
               version: "2026-04-11",
               adapter_kind: "adapter-c"
             }
           ]

    assert snapshot.readiness == [
             %HostedToolReadiness{
               name: "lookup_docs",
               version: "2026-04-11",
               ready: true,
               readiness_code: "",
               readiness_message: ""
             }
           ]
  end

  test "build_snapshot marks malformed readiness fields as not ready" do
    snapshot =
      ToolCapabilityCatalog.build_snapshot([
        %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "adapter-c", ready: "yes"}
      ])

    assert snapshot.capabilities == [
             %HostedToolCapability{
               name: "lookup_docs",
               version: "2026-04-11",
               adapter_kind: "adapter-c"
             }
           ]

    assert snapshot.readiness == [
             %HostedToolReadiness{
               name: "lookup_docs",
               version: "2026-04-11",
               ready: false,
               readiness_code: "invalid_config",
               readiness_message: "invalid hosted tool readiness configuration"
             }
           ]
  end
end
