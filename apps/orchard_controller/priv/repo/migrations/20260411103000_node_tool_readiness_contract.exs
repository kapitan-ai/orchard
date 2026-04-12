defmodule Orchard.Repo.Migrations.NodeToolReadinessContract do
  use Ecto.Migration

  def up do
    alter table(:nodes) do
      add(:tool_readiness, :map, null: false, default: %{})
    end
  end

  def down do
    alter table(:nodes) do
      remove(:tool_readiness)
    end
  end
end
