defmodule Orchard.Repo.Migrations.AddNodeTransportFailureWatermark do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      add(:last_transport_failure_at, :utc_datetime_usec)
    end
  end
end
