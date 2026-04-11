defmodule Orchard.Repo.Migrations.ToolRegistryRefIdentityConstraintsTest do
  @moduledoc """
  Regression test for `20260410103000_tool_registry_ref_identity_constraints`.

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

  test "up -> down -> up manages ref-safe identity constraints" do
    run_down_sql()
    refute constraint_exists?("tools", "tools_name_ref_safe")
    refute constraint_exists?("tools", "tools_version_ref_safe")

    run_up_sql()
    assert constraint_exists?("tools", "tools_name_ref_safe")
    assert constraint_exists?("tools", "tools_version_ref_safe")

    run_down_sql()
    refute constraint_exists?("tools", "tools_name_ref_safe")
    refute constraint_exists?("tools", "tools_version_ref_safe")

    run_up_sql()
    assert constraint_exists?("tools", "tools_name_ref_safe")
    assert constraint_exists?("tools", "tools_version_ref_safe")
  end

  test "constraints allow valid identities and reject invalid name/version" do
    run_down_sql()
    run_up_sql()

    insert_tool_row("lookup_weather", "2026-04-10")

    assert_raise Postgrex.Error, ~r/tools_name_ref_safe/, fn ->
      insert_tool_row("lookup weather", "2026-04-10")
    end

    assert_raise Postgrex.Error, ~r/tools_version_ref_safe/, fn ->
      insert_tool_row("lookup_weather_v2", "2026 04 10")
    end
  end

  defp run_up_sql do
    Repo.query!("""
    ALTER TABLE tools
    ADD CONSTRAINT tools_name_ref_safe
    CHECK (
      name <> ''
      AND position('@' in name) = 0
      AND position(' ' in name) = 0
      AND position(E'\\n' in name) = 0
      AND position(E'\\t' in name) = 0
    )
    """)

    Repo.query!("""
    ALTER TABLE tools
    ADD CONSTRAINT tools_version_ref_safe
    CHECK (
      version <> ''
      AND position('@' in version) = 0
      AND position(' ' in version) = 0
      AND position(E'\\n' in version) = 0
      AND position(E'\\t' in version) = 0
    )
    """)
  end

  defp run_down_sql do
    Repo.query!("ALTER TABLE tools DROP CONSTRAINT IF EXISTS tools_version_ref_safe")
    Repo.query!("ALTER TABLE tools DROP CONSTRAINT IF EXISTS tools_name_ref_safe")
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

  defp constraint_exists?(table_name, constraint_name) do
    %{num_rows: count} =
      Repo.query!(
        """
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE n.nspname = 'public' AND t.relname = $1 AND c.conname = $2
        """,
        [table_name, constraint_name]
      )

    count > 0
  end
end
