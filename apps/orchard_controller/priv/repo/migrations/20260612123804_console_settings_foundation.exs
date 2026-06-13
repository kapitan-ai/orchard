defmodule Orchard.Repo.Migrations.ConsoleSettingsFoundation do
  use Ecto.Migration

  def change do
    create table(:console_settings, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value, :map, null: false, default: fragment("'{}'::jsonb"))

      timestamps(type: :utc_datetime_usec)
    end
  end
end
