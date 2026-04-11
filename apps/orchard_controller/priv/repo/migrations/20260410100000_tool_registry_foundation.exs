defmodule Orchard.Repo.Migrations.ToolRegistryFoundation do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TYPE tool_registry_state AS ENUM (
      'active',
      'deprecated'
    )
    """)

    execute("""
    CREATE TYPE tool_execution_mode AS ENUM (
      'client_only',
      'server_hostable'
    )
    """)

    execute("""
    CREATE TYPE tool_source_kind AS ENUM (
      'manual',
      'mcp_server'
    )
    """)

    create table(:tools, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :text, null: false)
      add(:version, :text, null: false)
      add(:state, :tool_registry_state, null: false, default: "active")
      add(:definition, :map, null: false)
      add(:execution_mode, :tool_execution_mode, null: false, default: "client_only")
      add(:source_kind, :tool_source_kind, null: false, default: "manual")
      add(:source_ref, :text)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:tools, [:name, :version]))
    create(index(:tools, [:state, :inserted_at]))
  end

  def down do
    drop_if_exists(table(:tools))

    execute("DROP TYPE IF EXISTS tool_source_kind")
    execute("DROP TYPE IF EXISTS tool_execution_mode")
    execute("DROP TYPE IF EXISTS tool_registry_state")
  end
end
