defmodule Orchard.Repo.Migrations.AddModelCapabilityEvidence do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :capability_evidence, :map
    end
  end
end
