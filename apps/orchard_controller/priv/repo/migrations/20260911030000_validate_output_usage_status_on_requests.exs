defmodule Orchard.Repo.Migrations.ValidateOutputUsageStatusOnRequests do
  use Ecto.Migration

  def change do
    schema = String.replace(prefix() || "public", "\"", "\"\"")

    # A separate migration transaction releases the expansion's exclusive lock before scanning.
    execute(
      ~s(ALTER TABLE "#{schema}".requests VALIDATE CONSTRAINT requests_output_usage_status_check),
      ""
    )
  end
end
