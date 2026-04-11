defmodule Orchard.Repo.Migrations.ToolRegistryFoundationTest do
  @moduledoc """
  Regression test for the `20260410100000_tool_registry_foundation` migration.

  Executes the migration DDL directly through raw SQL inside the sandboxed test
  transaction so we can verify `up -> down -> up` safety without using
  `Ecto.Migrator`.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  @tool_state_labels ["active", "deprecated"]
  @execution_mode_labels ["client_only", "server_hostable"]
  @source_kind_labels ["manual", "mcp_server"]

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "up -> down -> up recreates tools table and enums" do
    run_down_sql()
    refute table_exists?("tools")
    refute type_exists?("tool_registry_state")
    refute type_exists?("tool_execution_mode")
    refute type_exists?("tool_source_kind")

    run_up_sql()
    assert table_exists?("tools")
    assert type_exists?("tool_registry_state")
    assert type_exists?("tool_execution_mode")
    assert type_exists?("tool_source_kind")
    assert enum_labels("tool_registry_state") == @tool_state_labels
    assert enum_labels("tool_execution_mode") == @execution_mode_labels
    assert enum_labels("tool_source_kind") == @source_kind_labels
    assert index_exists?("tools", "tools_name_version_index")
    assert index_exists?("tools", "tools_state_inserted_at_index")

    assert inserted_defaults() == [["active", "client_only", "manual"]]

    run_down_sql()
    refute table_exists?("tools")
    refute type_exists?("tool_registry_state")
    refute type_exists?("tool_execution_mode")
    refute type_exists?("tool_source_kind")

    run_up_sql()
    assert table_exists?("tools")
    assert enum_labels("tool_registry_state") == @tool_state_labels
    assert enum_labels("tool_execution_mode") == @execution_mode_labels
    assert enum_labels("tool_source_kind") == @source_kind_labels
  end

  test "name and version uniqueness is enforced at the database layer" do
    run_down_sql()
    run_up_sql()
    insert_tool_row("lookup_weather", "2026-04-10")

    assert_raise Postgrex.Error, ~r/tools_name_version_index/, fn ->
      insert_tool_row("lookup_weather", "2026-04-10")
    end
  end

  defp run_up_sql do
    Repo.query!("""
    CREATE TYPE tool_registry_state AS ENUM (
      'active',
      'deprecated'
    )
    """)

    Repo.query!("""
    CREATE TYPE tool_execution_mode AS ENUM (
      'client_only',
      'server_hostable'
    )
    """)

    Repo.query!("""
    CREATE TYPE tool_source_kind AS ENUM (
      'manual',
      'mcp_server'
    )
    """)

    Repo.query!("""
    CREATE TABLE tools (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      version text NOT NULL,
      state tool_registry_state NOT NULL DEFAULT 'active',
      definition jsonb NOT NULL,
      execution_mode tool_execution_mode NOT NULL DEFAULT 'client_only',
      source_kind tool_source_kind NOT NULL DEFAULT 'manual',
      source_ref text,
      inserted_at timestamp(6) without time zone NOT NULL DEFAULT NOW(),
      updated_at timestamp(6) without time zone NOT NULL DEFAULT NOW()
    )
    """)

    Repo.query!("CREATE UNIQUE INDEX tools_name_version_index ON tools (name, version)")
    Repo.query!("CREATE INDEX tools_state_inserted_at_index ON tools (state, inserted_at)")
  end

  defp run_down_sql do
    Repo.query!("DROP TABLE IF EXISTS tools")
    Repo.query!("DROP TYPE IF EXISTS tool_source_kind")
    Repo.query!("DROP TYPE IF EXISTS tool_execution_mode")
    Repo.query!("DROP TYPE IF EXISTS tool_registry_state")
  end

  defp insert_tool_row(name, version) do
    Repo.query!(
      """
      INSERT INTO tools (name, version, definition)
      VALUES ($1, $2, '{"type":"function","function":{"name":"lookup_weather"}}'::jsonb)
      """,
      [name, version]
    )
  end

  defp inserted_defaults do
    insert_tool_row("defaults_probe", "2026-04-09")

    %{rows: rows} =
      Repo.query!(
        "SELECT state::text, execution_mode::text, source_kind::text FROM tools WHERE name = 'defaults_probe'"
      )

    rows
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
