defmodule Orchard.Repo.Migrations.AddOutputUsageStatusToRequestsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migration.Runner
  alias Orchard.Repo
  alias Orchard.Repo.Migrations.AddOutputUsageStatusToRequests, as: Migration
  alias Orchard.Repo.Migrations.ValidateOutputUsageStatusOnRequests, as: Validation

  for file <- ~w(
    20260911020000_add_output_usage_status_to_requests.exs
    20260911030000_validate_output_usage_status_on_requests.exs
  ) do
    Code.require_file(Path.expand("../../../../priv/repo/migrations/#{file}", __DIR__))
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    prefix = "output_usage_status_migration_#{System.unique_integer([:positive])}"

    Repo.query!("CREATE SCHEMA #{prefix}")

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.query!("DROP SCHEMA #{prefix} CASCADE") end)
    end)

    Repo.query!("""
    CREATE TABLE #{prefix}.requests (id uuid PRIMARY KEY, output_tokens integer NOT NULL DEFAULT 0)
    """)

    Repo.query!("""
    INSERT INTO #{prefix}.requests (id, output_tokens)
    SELECT md5(n::text)::uuid, n FROM generate_series(1, 64) AS n
    """)

    {:ok, _} = Repo.transaction(fn -> run(Migration, :up, prefix) end)
    %{prefix: prefix}
  end

  test "SPEC.md §§8.2 and 13.2 preserves old and new unclassified rows through separate validation",
       %{prefix: prefix} do
    assert column_exists?(prefix, "requests", "output_usage_status")
    assert nullable_without_default?(prefix, "requests", "output_usage_status")
    refute constraint_validated?(prefix)
    assert unclassified_usage(prefix) == [64, 2080]

    request_id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO #{prefix}.requests (id) VALUES ($1)", [Ecto.UUID.dump!(request_id)])
    assert request_usage_status(prefix, request_id) == nil
    insert_request(prefix, "exact")
    insert_request(prefix, "lower_bound")

    assert_raise Postgrex.Error, ~r/requests_output_usage_status_check/, fn ->
      insert_request(prefix, "estimated")
    end

    assert_raise Postgrex.Error, ~r/requests_output_usage_status_check/, fn ->
      Repo.query!("UPDATE #{prefix}.requests SET output_usage_status = 'unknown'")
    end

    {:ok, _} = Repo.transaction(fn -> run(Validation, :up, prefix) end)
    assert constraint_validated?(prefix)
    assert unclassified_usage(prefix) == [65, 2080]
    assert request_usage_status(prefix, request_id) == nil

    {:ok, _} = Repo.transaction(fn -> run(Validation, :up, prefix) end)
    assert constraint_validated?(prefix)
    run(Validation, :down, prefix)
    run(Migration, :down, prefix)
    refute column_exists?(prefix, "requests", "output_usage_status")
  end

  test "SPEC.md §13.2 validation permits ordinary DML before its transaction commits",
       %{prefix: prefix} do
    refute Migration.__migration__()[:disable_ddl_transaction]
    refute Validation.__migration__()[:disable_ddl_transaction]

    {:ok, _} =
      Repo.transaction(fn ->
        run(Validation, :up, prefix)

        %{rows: locks} =
          Repo.query!(
            """
            SELECT mode FROM pg_locks
            WHERE pid = pg_backend_pid() AND relation = $1::text::regclass
            """,
            ["#{prefix}.requests"]
          )

        assert ["ShareUpdateExclusiveLock"] in locks
        refute ["AccessExclusiveLock"] in locks

        task =
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                Repo.query!("SET LOCAL lock_timeout = '1s'")
                assert unclassified_usage(prefix) == [64, 2080]
                insert_request(prefix, "lower_bound")

                assert %{rows: [["exact"]]} =
                         Repo.query!("""
                         UPDATE #{prefix}.requests SET output_usage_status = 'exact'
                         WHERE output_usage_status = 'lower_bound' RETURNING output_usage_status
                         """)
              end)
            end)
          end)

        assert {:ok, _} = Task.await(task)
      end)

    assert constraint_validated?(prefix)
    assert unclassified_usage(prefix) == [64, 2080]
  end

  defp run(migration, direction, prefix) do
    runner_direction = if direction == :up, do: :forward, else: :backward

    Runner.run(
      Repo,
      Repo.config(),
      0,
      migration,
      runner_direction,
      :change,
      direction,
      prefix: prefix,
      log: false
    )
  end

  defp constraint_validated?(prefix) do
    %{rows: [[validated]]} =
      Repo.query!(
        """
        SELECT convalidated FROM pg_constraint
        WHERE conrelid = $1::text::regclass AND conname = $2
        """,
        ["#{prefix}.requests", "requests_output_usage_status_check"]
      )

    validated
  end

  defp unclassified_usage(prefix) do
    %{rows: [row]} =
      Repo.query!("""
      SELECT count(*), sum(output_tokens) FROM #{prefix}.requests WHERE output_usage_status IS NULL
      """)

    row
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
