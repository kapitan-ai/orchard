defmodule Orchard.Repo.Migrations.NodeToolReadinessContractTest do
  @moduledoc """
  Regression test for the `20260411103000_node_tool_readiness_contract`
  migration.

  Executes the migration DDL directly through raw SQL inside the sandboxed test
  transaction so we can verify `up -> down -> up` safety without using
  `Ecto.Migrator`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "up -> down -> up adds nodes.tool_readiness as additive jsonb with default" do
    run_down_sql()
    refute column_exists?("nodes", "tool_readiness")

    run_up_sql()
    assert column_exists?("nodes", "tool_readiness")
    assert column_is_not_nullable?("nodes", "tool_readiness")
    assert inserted_defaults() == [[%{}]]

    run_down_sql()
    refute column_exists?("nodes", "tool_readiness")

    run_up_sql()
    assert column_exists?("nodes", "tool_readiness")
  end

  defp run_up_sql do
    Repo.query!("ALTER TABLE nodes ADD COLUMN tool_readiness jsonb NOT NULL DEFAULT '{}'::jsonb")
  end

  defp run_down_sql do
    Repo.query!("ALTER TABLE nodes DROP COLUMN IF EXISTS tool_readiness")
  end

  defp column_exists?(table_name, column_name) do
    %{num_rows: count} =
      Repo.query!(
        """
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table_name, column_name]
      )

    count > 0
  end

  defp column_is_not_nullable?(table_name, column_name) do
    %{rows: [[nullable]]} =
      Repo.query!(
        """
        SELECT is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
        """,
        [table_name, column_name]
      )

    nullable == "NO"
  end

  defp inserted_defaults do
    unique = System.unique_integer([:positive])

    Repo.query!(
      """
      INSERT INTO nodes (id, hostname, display_name, advertise_addr, rpc_port, state, health, capabilities)
      VALUES (gen_random_uuid(), $1, $2, $3, 9444, 'active', 'healthy', '{}'::jsonb)
      """,
      [
        "tool-readiness-#{unique}.local",
        "tool-readiness-#{unique}",
        "10.0.1.#{rem(unique, 255)}"
      ]
    )

    %{rows: rows} =
      Repo.query!(
        "SELECT tool_readiness FROM nodes WHERE display_name = $1",
        ["tool-readiness-#{unique}"]
      )

    rows
  end
end
