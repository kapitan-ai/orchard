defmodule Orchard.Repo.Migrations.AddOutputUsageStatusToRequestsTest do
  use Orchard.DataCase, async: false

  alias Ecto.Migration.Runner
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.AddOutputUsageStatusToRequests, as: Migration

  @migration_path Path.expand(
                    "../../../../priv/repo/migrations/20260911020000_add_output_usage_status_to_requests.exs",
                    __DIR__
                  )
  Code.require_file(@migration_path)

  test "SPEC.md §§5.3 and 10.10 adds a nullable unclassified usage status without a default or backfill" do
    prefix = "output_usage_status_migration_#{System.unique_integer([:positive])}"
    request_id = Ecto.UUID.generate()

    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("CREATE TABLE #{prefix}.requests (id uuid PRIMARY KEY)")
    Repo.query!("INSERT INTO #{prefix}.requests (id) VALUES ($1)", [Ecto.UUID.dump!(request_id)])

    run(:up, prefix)

    assert column_exists?(prefix, "requests", "output_usage_status")
    assert nullable_without_default?(prefix, "requests", "output_usage_status")
    assert request_usage_status(prefix, request_id) == nil

    insert_request(prefix, "exact")
    insert_request(prefix, "lower_bound")

    assert_raise Postgrex.Error, ~r/requests_output_usage_status_check/, fn ->
      insert_request(prefix, "estimated")
    end

    run(:down, prefix)
    refute column_exists?(prefix, "requests", "output_usage_status")
  end

  defp run(direction, prefix) do
    runner_direction = if direction == :up, do: :forward, else: :backward

    Runner.run(
      Repo,
      Repo.config(),
      0,
      Migration,
      runner_direction,
      :change,
      direction,
      prefix: prefix,
      log: false
    )
  end

  defp column_exists?(prefix, table, column) do
    %{num_rows: count} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
        [prefix, table, column]
      )

    count == 1
  end

  defp nullable_without_default?(prefix, table, column) do
    %{rows: [["YES", nil]]} =
      Repo.query!(
        "SELECT is_nullable, column_default FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2 AND column_name = $3",
        [prefix, table, column]
      )

    true
  end

  defp request_usage_status(prefix, request_id) do
    %{rows: [[status]]} =
      Repo.query!("SELECT output_usage_status FROM #{prefix}.requests WHERE id = $1", [
        Ecto.UUID.dump!(request_id)
      ])

    status
  end

  defp insert_request(prefix, status) do
    Repo.query!("INSERT INTO #{prefix}.requests (id, output_usage_status) VALUES ($1, $2)", [
      Ecto.UUID.dump!(Ecto.UUID.generate()),
      status
    ])
  end
end
