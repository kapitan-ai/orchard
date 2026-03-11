defmodule Orchard.Repo.Migrations.AddArtifactSourceUriToModels do
  use Ecto.Migration

  def up do
    alter table(:models) do
      add :artifact_source_uri, :text
    end

    # Backfill from existing artifact_uri for rows that have one.
    execute """
    UPDATE models
    SET artifact_source_uri = artifact_uri
    WHERE artifact_uri IS NOT NULL
    """
  end

  def down do
    alter table(:models) do
      remove :artifact_source_uri
    end
  end
end
