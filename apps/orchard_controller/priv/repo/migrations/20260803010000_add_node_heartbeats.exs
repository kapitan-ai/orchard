defmodule Orchard.Repo.Migrations.AddNodeHeartbeats do
  use Ecto.Migration

  def change do
    create table(:node_heartbeats) do
      add(:node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false)
      add(:observed_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
      add(:health, :node_health, null: false)
      add(:available_memory_bytes, :bigint)
      add(:swap_used_bytes, :bigint)
      add(:cpu_load_1m, :decimal, precision: 8, scale: 2)
      add(:thermal_pressure, :text)
      add(:active_requests, :integer, null: false, default: 0)
      add(:payload, :map, null: false, default: %{})
    end

    create(
      index(:node_heartbeats, [:node_id, {:desc, :observed_at}],
        name: :idx_node_heartbeats_node_observed_at
      )
    )
  end
end
