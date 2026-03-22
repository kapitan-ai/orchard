defmodule Orchard.Repo.Migrations.AddArtifactSourceUriToModelsTest do
  @moduledoc """
  Regression test for the `artifact_source_uri` backfill migration
  (20260311000000_add_artifact_source_uri_to_models.exs).

  Executes the migration's DDL and backfill SQL directly via Repo.query!
  inside the sandbox transaction. Postgres DDL is fully transactional,
  so the sandbox auto-rolls back all schema changes after the test.

  We avoid Ecto.Migrator because its internal Task spawning deadlocks
  with the sandbox's connection ownership model.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  # Stable test identifiers — must not collide with fixture model_ids
  @with_uri_model_id "migration-backfill-with-uri"
  @null_uri_model_id "migration-backfill-null-uri"
  @test_model_ids [@with_uri_model_id, @null_uri_model_id]

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  describe "20260311000000 backfill from artifact_uri" do
    test "copies artifact_uri into artifact_source_uri for non-NULL rows, leaves NULL rows as NULL" do
      Repo.query!("ALTER TABLE models DROP COLUMN IF EXISTS artifact_source_uri")

      refute column_exists?("models", "artifact_source_uri"),
             "artifact_source_uri column still exists after DROP — test setup broken"

      insert_legacy_row!(@with_uri_model_id, artifact_uri: "file:///tmp/backfill-source")
      insert_legacy_row!(@null_uri_model_id, artifact_uri: nil)

      Repo.query!("ALTER TABLE models ADD COLUMN artifact_source_uri text")

      Repo.query!("""
      UPDATE models
      SET artifact_source_uri = artifact_uri
      WHERE artifact_uri IS NOT NULL
      """)

      assert column_exists?("models", "artifact_source_uri"),
             "artifact_source_uri column missing after migration SQL"

      rows = fetch_backfill_results()

      with_uri_row = Enum.find(rows, &(&1["model_id"] == @with_uri_model_id))
      null_uri_row = Enum.find(rows, &(&1["model_id"] == @null_uri_model_id))

      assert with_uri_row, "expected row with model_id #{@with_uri_model_id} not found"
      assert null_uri_row, "expected row with model_id #{@null_uri_model_id} not found"

      assert with_uri_row["artifact_source_uri"] == "file:///tmp/backfill-source",
             "expected backfill to copy artifact_uri, got: #{inspect(with_uri_row["artifact_source_uri"])}"

      assert is_nil(null_uri_row["artifact_source_uri"]),
             "expected NULL artifact_source_uri for NULL artifact_uri, got: #{inspect(null_uri_row["artifact_source_uri"])}"
    end
  end

  # -------------------------------------------------------------------
  # Schema introspection
  # -------------------------------------------------------------------

  defp column_exists?(table, column) do
    %{num_rows: n} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
        [table, column]
      )

    n > 0
  end

  # -------------------------------------------------------------------
  # Raw SQL seed / query helpers
  # -------------------------------------------------------------------

  defp insert_legacy_row!(model_id, opts) do
    artifact_uri = Keyword.get(opts, :artifact_uri)

    Repo.query!(
      """
      INSERT INTO models (
        model_id, version, state, format, capabilities, tokenizer,
        artifact_uri, artifact_sha256, artifact_size_bytes,
        resident_memory_bytes, kv_cache_bytes_per_token,
        prefill_workspace_bytes_per_token, max_context_tokens,
        default_parameters, runtime_requirements
      ) VALUES (
        $1, '1.0', 'registered', 'mlx', '{}', '{}',
        $2, 'sha256-test-placeholder', 0,
        0, 0, 0, 2048,
        '{}', '{}'
      )
      """,
      [model_id, artifact_uri]
    )
  end

  defp fetch_backfill_results do
    %{columns: columns, rows: rows} =
      Repo.query!(
        "SELECT model_id, artifact_uri, artifact_source_uri FROM models WHERE model_id = ANY($1) ORDER BY model_id",
        [@test_model_ids]
      )

    Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
  end
end
