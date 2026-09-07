defmodule Orchard.Inference.ToolCapabilityReadinessTest do
  use Orchard.DataCase, async: false

  alias Orchard.Inference.ToolCapabilityReadiness
  alias Orchard.Nodes.Node

  import Orchard.TestSupport.RepoHelpers, only: [with_repo_unregistered: 1]

  import Orchard.TestSupport.ToolRegistryTestSupport,
    only: [create_tool!: 3, with_inference_overrides: 2]

  describe "list_candidates/3" do
    test "rejects missing, inactive, and non-server-hostable registry tools" do
      assert {:error, :tool_not_found} =
               ToolCapabilityReadiness.list_candidates("lookup_docs", "2026-04-11")

      create_tool!("lookup_docs", "2026-04-11", %{state: :deprecated})

      assert {:error, :tool_inactive} =
               ToolCapabilityReadiness.list_candidates("lookup_docs", "2026-04-11")

      create_tool!("lookup_weather", "2026-04-10", %{execution_mode: :client_only})

      assert {:error, :tool_not_server_hostable} =
               ToolCapabilityReadiness.list_candidates("lookup_weather", "2026-04-10")
    end

    test "returns explicit error when the tool registry is unavailable" do
      create_tool!("lookup_docs", "2026-04-11", %{execution_mode: :server_hostable})

      with_repo_unregistered(fn ->
        assert {:error, :tool_registry_unavailable} =
                 ToolCapabilityReadiness.list_candidates("lookup_docs", "2026-04-11")

        assert {:error, :tool_registry_unavailable} =
                 ToolCapabilityReadiness.list_hostable_nodes("lookup_docs", "2026-04-11")
      end)
    end

    test "returns deterministic node candidate metadata and explicit effective readiness" do
      create_tool!("lookup_docs", "2026-04-11", %{execution_mode: :server_hostable})

      now = ~U[2026-04-11 12:00:00Z]
      ref = tool_ref("lookup_docs", "2026-04-11")

      ready_node =
        insert_node!(%{
          display_name: "alpha-ready",
          capabilities: %{"hosted_tools" => [hosted_capability("lookup_docs", "2026-04-11")]},
          tool_readiness: %{
            ref => %{"ready" => true, "status_code" => "ok", "status_message" => "ready"}
          },
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      degraded_ready_node =
        insert_node!(%{
          display_name: "beta-degraded",
          health: :degraded,
          capabilities: %{"hosted_tools" => [hosted_capability("lookup_docs", "2026-04-11")]},
          tool_readiness: %{
            ref => %{"ready" => true, "status_code" => "", "status_message" => ""}
          },
          last_heartbeat_at: DateTime.add(now, -10, :second)
        })

      stale_node =
        insert_node!(%{
          display_name: "gamma-stale",
          capabilities: %{"hosted_tools" => [hosted_capability("lookup_docs", "2026-04-11")]},
          tool_readiness: %{
            ref => %{"ready" => true, "status_code" => "", "status_message" => ""}
          },
          last_heartbeat_at: DateTime.add(now, -45, :second)
        })

      warming_node =
        insert_node!(%{
          display_name: "delta-warming",
          capabilities: %{"hosted_tools" => [hosted_capability("lookup_docs", "2026-04-11")]},
          tool_readiness: %{
            ref => %{
              "ready" => false,
              "status_code" => "warming",
              "status_message" => "warming up"
            }
          },
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      missing_capability_node =
        insert_node!(%{
          display_name: "epsilon-missing-capability",
          capabilities: %{"hosted_tools" => []},
          tool_readiness: %{},
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      cordoned_node =
        insert_node!(%{
          display_name: "zeta-cordoned",
          state: :cordoned,
          capabilities: %{"hosted_tools" => [hosted_capability("lookup_docs", "2026-04-11")]},
          tool_readiness: %{
            ref => %{"ready" => true, "status_code" => "", "status_message" => ""}
          },
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      with_inference_overrides([node_freshness_threshold_ms: 30_000], fn ->
        assert {:ok, candidates} =
                 ToolCapabilityReadiness.list_candidates("lookup_docs", "2026-04-11", now: now)

        assert Enum.map(candidates, & &1.display_name) == [
                 "alpha-ready",
                 "beta-degraded",
                 "delta-warming",
                 "epsilon-missing-capability",
                 "gamma-stale",
                 "zeta-cordoned"
               ]

        candidate_by_id = Map.new(candidates, &{&1.node_id, &1})

        assert %ToolCapabilityReadiness.Candidate{
                 tool_ref: "tool://lookup_docs@2026-04-11",
                 tool_name: "lookup_docs",
                 tool_version: "2026-04-11",
                 execution_mode: :server_hostable,
                 advertised?: true,
                 tool_ready?: true,
                 adapter_kind: "mcp",
                 status_code: "ok",
                 status_message: "ready",
                 fresh?: true,
                 effective_ready?: true
               } = candidate_by_id[ready_node.id]

        assert %ToolCapabilityReadiness.Candidate{
                 advertised?: true,
                 tool_ready?: true,
                 adapter_kind: "mcp",
                 status_code: nil,
                 status_message: nil,
                 health: :degraded,
                 fresh?: true,
                 effective_ready?: true
               } = candidate_by_id[degraded_ready_node.id]

        assert %ToolCapabilityReadiness.Candidate{
                 advertised?: true,
                 tool_ready?: false,
                 status_code: "warming",
                 status_message: "warming up",
                 fresh?: true,
                 effective_ready?: false
               } = candidate_by_id[warming_node.id]

        assert %ToolCapabilityReadiness.Candidate{
                 advertised?: false,
                 tool_ready?: nil,
                 adapter_kind: nil,
                 fresh?: true,
                 effective_ready?: false
               } = candidate_by_id[missing_capability_node.id]

        assert %ToolCapabilityReadiness.Candidate{
                 advertised?: true,
                 tool_ready?: true,
                 fresh?: false,
                 effective_ready?: false
               } = candidate_by_id[stale_node.id]

        assert %ToolCapabilityReadiness.Candidate{
                 advertised?: true,
                 tool_ready?: true,
                 state: :cordoned,
                 fresh?: true,
                 effective_ready?: false
               } = candidate_by_id[cordoned_node.id]

        assert {:ok, hostable_nodes} =
                 ToolCapabilityReadiness.list_hostable_nodes("lookup_docs", "2026-04-11",
                   now: now
                 )

        assert Enum.map(hostable_nodes, & &1.node_id) == [ready_node.id, degraded_ready_node.id]
      end)
    end
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "host-#{unique}.local",
          display_name: "node-#{unique}",
          advertise_addr: "node-#{unique}.test",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          capabilities: %{"hosted_tools" => []},
          tool_readiness: %{},
          last_heartbeat_at: DateTime.utc_now()
        },
        overrides
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp hosted_capability(name, version, adapter_kind \\ "mcp") do
    %{
      "ref" => tool_ref(name, version),
      "name" => name,
      "version" => version,
      "adapter_kind" => adapter_kind
    }
  end

  defp tool_ref(name, version), do: "tool://#{name}@#{version}"
end
