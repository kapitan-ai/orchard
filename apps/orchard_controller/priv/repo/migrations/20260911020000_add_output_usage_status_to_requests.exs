defmodule Orchard.Repo.Migrations.AddOutputUsageStatusToRequests do
  use Ecto.Migration

  def change do
    alter table(:requests) do
      add(:output_usage_status, :text)
    end

    create constraint(:requests, :requests_output_usage_status_check,
             check: "output_usage_status IS NULL OR output_usage_status IN ('exact', 'lower_bound')",
             validate: false
           )
  end
end
