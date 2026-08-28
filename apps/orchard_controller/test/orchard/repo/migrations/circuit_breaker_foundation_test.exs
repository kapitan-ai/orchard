defmodule Orchard.Repo.Migrations.CircuitBreakerFoundationTest do
  @moduledoc """
  Executes the real circuit-breaker migrations in an isolated Postgres schema.
  """

  use Orchard.DataCase, async: false

  alias Ecto.Migration.Runner
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.CircuitBreakerContributionEvidence
  alias Orchard.Repo.Migrations.CircuitBreakerFoundation

  @migration_dir Path.expand("../../../../priv/repo/migrations", __DIR__)
  Code.require_file(Path.join(@migration_dir, "20260828010000_circuit_breaker_foundation.exs"))

  Code.require_file(
    Path.join(@migration_dir, "20260828010100_circuit_breaker_contribution_evidence.exs")
  )

  test "the actual migrations run up, down, and up with their durable constraints" do
    prefix = "circuit_breaker_migration_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("CREATE TABLE #{prefix}.nodes (id uuid PRIMARY KEY)")

    run(CircuitBreakerFoundation, :up, prefix)
    run(CircuitBreakerContributionEvidence, :up, prefix)
    assert_contract(prefix)

    run(CircuitBreakerContributionEvidence, :down, prefix)
    run(CircuitBreakerFoundation, :down, prefix)
    refute table_exists?(prefix, "circuit_breakers")
    refute table_exists?(prefix, "circuit_breaker_failures")
    assert table_exists?(prefix, "nodes")

    run(CircuitBreakerFoundation, :up, prefix)
    run(CircuitBreakerContributionEvidence, :up, prefix)
    assert_contract(prefix)
  end

  defp run(module, direction, prefix) do
    runner_direction = if direction == :up, do: :forward, else: :backward

    Runner.run(
      Repo,
      Repo.config(),
      0,
      module,
      runner_direction,
      :change,
      direction,
      prefix: prefix,
      log: false
    )
  end

  defp assert_contract(prefix) do
    assert table_exists?(prefix, "circuit_breakers")
    assert table_exists?(prefix, "circuit_breaker_failures")
    assert column_exists?(prefix, "circuit_breaker_failures", "decision_at")
    assert column_exists?(prefix, "circuit_breaker_failures", "disposition")
    assert column_exists?(prefix, "circuit_breaker_failures", "transition")
    assert index_exists?(prefix, "circuit_breakers_node_identity")
    assert index_exists?(prefix, "circuit_breakers_placement_identity")
    assert index_exists?(prefix, "circuit_breaker_failures_decision_window")
    assert constraint_exists?(prefix, "circuit_breakers", "circuit_breakers_identity_valid")

    assert constraint_exists?(
             prefix,
             "circuit_breaker_failures",
             "circuit_breaker_failures_disposition_valid"
           )

    node_id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO #{prefix}.nodes (id) VALUES ($1)", [Ecto.UUID.dump!(node_id)])

    Repo.query!("""
    INSERT INTO #{prefix}.circuit_breakers (kind, node_id, state, inserted_at, updated_at)
    VALUES ('node', '#{node_id}', 'closed', NOW(), NOW())
    """)
  end

  defp table_exists?(prefix, table) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [prefix, table]
      )

    count > 0
  end

  defp column_exists?(prefix, table, column) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
        [prefix, table, column]
      )

    count > 0
  end

  defp index_exists?(prefix, index) do
    %{num_rows: count} =
      Repo.query!("SELECT 1 FROM pg_indexes WHERE schemaname = $1 AND indexname = $2", [
        prefix,
        index
      ])

    count > 0
  end

  defp constraint_exists?(prefix, table, constraint) do
    %{num_rows: count} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = $1 AND t.relname = $2 AND c.conname = $3
        """,
        [prefix, table, constraint]
      )

    count > 0
  end
end
