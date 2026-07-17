defmodule Orchard.Repo.Migrations.NodeInventoryFoundationTest do
  @moduledoc """
  Regression test for the `20260323010000_m3a_1a_node_inventory_foundation`
  migration.

  Executes DDL directly through raw SQL inside the sandboxed test transaction
  to verify `up -> down -> up` safety without using `Ecto.Migrator`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  @node_state_labels [
    "provisioned",
    "registered",
    "admitted",
    "active",
    "cordoned",
    "draining",
    "maintenance",
    "decommissioning",
    "removed"
  ]

  @node_health_labels ["healthy", "degraded", "unhealthy", "unreachable"]

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "up -> down -> up recreates nodes table and enums" do
    # First down: remove the real migration artifacts so we can re-create
    run_down_sql()
    refute table_exists?("nodes")
    refute type_exists?("node_state")
    refute type_exists?("node_health")

    # First up
    run_up_sql()
    assert table_exists?("nodes")
    assert type_exists?("node_state")
    assert type_exists?("node_health")

    # Verify enum labels match SPEC vocabulary
    assert enum_labels("node_state") == @node_state_labels
    assert enum_labels("node_health") == @node_health_labels

    # Verify indexes exist
    assert index_exists?("nodes", "nodes_display_name_index")
    assert index_exists?("nodes", "nodes_advertise_addr_rpc_port_index")

    # Second down
    run_down_sql()
    refute table_exists?("nodes")
    refute type_exists?("node_state")
    refute type_exists?("node_health")

    # Second up: confirms re-creation works
    run_up_sql()
    assert table_exists?("nodes")
    assert enum_labels("node_state") == @node_state_labels
    assert enum_labels("node_health") == @node_health_labels
  end

  test "port constraint enforced" do
    # Insert valid node to confirm constraint doesn't block normal inserts
    Repo.query!("""
    INSERT INTO nodes (id, hostname, display_name, advertise_addr, rpc_port, state, health, capabilities)
    VALUES (gen_random_uuid(), 'host.local', 'test-node', '10.0.0.1', 9444, 'active', 'healthy', '{}'::jsonb)
    """)

    # Invalid port should violate constraint
    assert_raise Postgrex.Error, ~r/nodes_rpc_port_range/, fn ->
      Repo.query!("""
      INSERT INTO nodes (id, hostname, display_name, advertise_addr, rpc_port, state, health, capabilities)
      VALUES (gen_random_uuid(), 'host2.local', 'test-node-2', '10.0.0.2', 0, 'active', 'healthy', '{}'::jsonb)
      """)
    end
  end

  # -- SQL helpers --

  defp run_up_sql do
    Repo.query!("""
    CREATE TYPE node_state AS ENUM (
      'provisioned', 'registered', 'admitted', 'active',
      'cordoned', 'draining', 'maintenance', 'decommissioning', 'removed'
    )
    """)

    Repo.query!("""
    CREATE TYPE node_health AS ENUM (
      'healthy', 'degraded', 'unhealthy', 'unreachable'
    )
    """)

    Repo.query!("""
    CREATE TABLE nodes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      hostname text NOT NULL,
      display_name text NOT NULL,
      advertise_addr text NOT NULL,
      rpc_port integer NOT NULL DEFAULT 9444,
      state node_state NOT NULL DEFAULT 'provisioned',
      health node_health NOT NULL DEFAULT 'unreachable',
      capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
      agent_version text,
      last_heartbeat_at timestamp(6) without time zone,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      CONSTRAINT nodes_rpc_port_range CHECK (rpc_port > 0 AND rpc_port <= 65535)
    )
    """)

    Repo.query!("CREATE UNIQUE INDEX nodes_display_name_index ON nodes (display_name)")

    Repo.query!(
      "CREATE UNIQUE INDEX nodes_advertise_addr_rpc_port_index ON nodes (advertise_addr, rpc_port)"
    )
  end

  defp run_down_sql do
    Repo.query!("DROP TABLE IF EXISTS node_runtime_capacity_evidence")
    Repo.query!("DROP TABLE IF EXISTS node_dispatch_capacity_policies")
    Repo.query!("DROP TABLE IF EXISTS beam_peer_grants")
    Repo.query!("DROP TABLE IF EXISTS node_enrollments")
    Repo.query!("DROP TABLE IF EXISTS node_admission_decisions")
    Repo.query!("DROP TABLE IF EXISTS node_admission_candidates")
    Repo.query!("DROP TABLE IF EXISTS nodes")
    Repo.query!("DROP TYPE IF EXISTS node_health")
    Repo.query!("DROP TYPE IF EXISTS node_state")
  end

  defp table_exists?(table_name) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1",
        [table_name]
      )

    count > 0
  end

  defp type_exists?(type_name) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM pg_type WHERE typname = $1 AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')",
        [type_name]
      )

    count > 0
  end

  defp index_exists?(table_name, index_name) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM pg_indexes WHERE tablename = $1 AND indexname = $2",
        [table_name, index_name]
      )

    count > 0
  end

  defp enum_labels(type_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT e.enumlabel
        FROM pg_enum e
        JOIN pg_type t ON e.enumtypid = t.oid
        JOIN pg_namespace n ON t.typnamespace = n.oid
        WHERE t.typname = $1 AND n.nspname = 'public'
        ORDER BY e.enumsortorder
        """,
        [type_name]
      )

    Enum.map(rows, fn [label] -> label end)
  end
end
