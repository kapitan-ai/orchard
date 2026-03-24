defmodule Orchard.Repo.Migrations.M3A1ANodeInventoryFoundation do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TYPE node_state AS ENUM (
      'provisioned',
      'registered',
      'admitted',
      'active',
      'cordoned',
      'draining',
      'maintenance',
      'decommissioning',
      'removed'
    )
    """)

    execute("""
    CREATE TYPE node_health AS ENUM (
      'healthy',
      'degraded',
      'unhealthy',
      'unreachable'
    )
    """)

    create table(:nodes, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:hostname, :text, null: false)
      add(:display_name, :text, null: false)
      add(:advertise_addr, :text, null: false)
      add(:rpc_port, :integer, null: false, default: 9444)
      add(:state, :node_state, null: false, default: "provisioned")
      add(:health, :node_health, null: false, default: "unreachable")
      add(:capabilities, :map, null: false, default: %{})
      add(:agent_version, :text)
      add(:last_heartbeat_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:nodes, [:display_name]))
    create(unique_index(:nodes, [:advertise_addr, :rpc_port]))

    create(
      constraint(:nodes, :nodes_rpc_port_range,
        check: "rpc_port > 0 AND rpc_port <= 65535"
      )
    )
  end

  def down do
    drop_if_exists(table(:nodes))

    execute("DROP TYPE IF EXISTS node_health")
    execute("DROP TYPE IF EXISTS node_state")
  end
end
