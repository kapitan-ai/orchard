defmodule Orchard.Models.ResidentMemoryBackfillTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.ArtifactBundle
  alias Orchard.FS
  alias Orchard.Models.ResidentMemoryBackfill
  alias Orchard.Repo

  setup do
    artifacts_root =
      File.cwd!()
      |> Path.join("_build/test-tmp/orchard-backfill-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(artifacts_root)

    previous_inference = Application.get_env(:orchard_controller, :inference, [])

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous_inference, artifacts_root: artifacts_root)
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      File.rm_rf!(artifacts_root)
    end)

    %{artifacts_root: artifacts_root}
  end

  test "applies resident_memory_bytes and keeps DB hash aligned with disk", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.processed == 1
    assert result.updated == 1
    assert result.failed == 0

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == expected_resident
    assert {:ok, updated_model.artifact_sha256} == ArtifactBundle.tree_sha256(bundle_path)

    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)
  end

  test "skips models that already have resident memory", ctx do
    %{model: model} = create_estimable_model!(ctx, resident_memory_bytes: 123)

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.skipped_already_present == 1
    assert result.updated == 0
    assert Repo.get!(Orchard.Models.Model, model.id).resident_memory_bytes == 123
  end

  test "missing artifact path is failed and logged", ctx do
    missing_path = Path.join([ctx.artifacts_root, "missing", "v1"])
    create_catalog_model!(ctx, artifact_uri: "file://#{missing_path}")

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: test_log())
    assert result.failed == 1
    assert_receive {:backfill_log, message}
    assert message =~ "artifact path does not exist"
  end

  test "unknown estimator result is skipped", ctx do
    %{bundle_path: bundle_path} = create_bundle!(ctx, weights?: false)

    create_catalog_model!(ctx,
      artifact_uri: "file://#{bundle_path}",
      artifact_sha256: tree_sha!(bundle_path)
    )

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.skipped_unknown == 1
    assert result.updated == 0
  end

  test "hash drift skips without mutating the manifest", ctx do
    %{bundle_path: bundle_path} = create_bundle!(ctx)
    original_sha = tree_sha!(bundle_path)
    File.write!(Path.join(bundle_path, "extra.txt"), "drift")

    create_catalog_model!(ctx,
      artifact_uri: "file://#{bundle_path}",
      artifact_sha256: original_sha
    )

    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.skipped_drift == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest
  end

  test "dry-run reports would_update without DB or manifest writes", ctx do
    %{model: model, bundle_path: bundle_path, sha: sha} = create_estimable_model!(ctx)
    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    assert {:ok, result} = ResidentMemoryBackfill.run(log: quiet_log())
    assert result.dry_run
    assert result.would_update == 1
    assert result.updated == 0
    assert Repo.get!(Orchard.Models.Model, model.id).artifact_sha256 == sha
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest
  end

  test "catalog update race rolls back the manifest", ctx do
    %{bundle_path: bundle_path, sha: sha} = create_estimable_model!(ctx)

    assert {:ok, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, _new_sha -> 0 end
             )

    assert result.skipped_concurrent == 1
    assert %{"resident_memory_bytes" => 0} = read_manifest!(bundle_path)
    assert tree_sha!(bundle_path) == sha
  end

  test "rollback write failure aborts and reports failed", ctx do
    %{bundle_path: bundle_path} = create_estimable_model!(ctx)
    writer = fail_second_write()

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, _new_sha -> 0 end,
               write_manifest: writer
             )

    assert result.failed == 1
    assert %{"resident_memory_bytes" => value} = read_manifest!(bundle_path)
    assert value > 0
  end

  test "second apply run is idempotent", ctx do
    create_estimable_model!(ctx)

    assert {:ok, first} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert first.updated == 1

    assert {:ok, second} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert second.updated == 0
    assert second.skipped_already_present == 1
  end

  test "non-file artifact URI is failed", ctx do
    create_catalog_model!(ctx, artifact_uri: "https://example.test/model")

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.failed == 1
  end

  test "symlink artifact path is failed before mutation", ctx do
    target = Path.join(ctx.artifacts_root, "target")
    File.mkdir_p!(target)
    link = Path.join(ctx.artifacts_root, "linked")
    File.ln_s!(target, link)

    create_catalog_model!(ctx, artifact_uri: "file://#{Path.join(link, "v1")}")

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.failed == 1
  end

  test "path traversal outside artifacts_root is failed", ctx do
    escaped_path = Path.expand(Path.join(ctx.artifacts_root, "../outside-bundle"))
    create_catalog_model!(ctx, artifact_uri: "file://#{escaped_path}")

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.failed == 1
  end

  defp create_estimable_model!(ctx, overrides \\ %{}) do
    overrides = Map.new(overrides)
    bundle = create_bundle!(ctx, overrides)

    model =
      create_catalog_model!(ctx,
        artifact_uri: "file://#{bundle.bundle_path}",
        artifact_sha256: bundle.sha,
        resident_memory_bytes: Map.get(overrides, :resident_memory_bytes, 0),
        model_id: bundle.model_id,
        version: bundle.version
      )

    Map.put(bundle, :model, model)
  end

  defp create_bundle!(ctx, opts \\ %{}) do
    opts = Map.new(opts)
    suffix = System.unique_integer([:positive])
    model_id = Map.get(opts, :model_id, "test-org/backfill-#{suffix}")
    version = Map.get(opts, :version, "v1")
    bundle_path = Path.join([ctx.artifacts_root, model_id, version])
    weights? = Map.get(opts, :weights?, true)
    manifest_resident = Map.get(opts, :manifest_resident_memory_bytes, 0)

    File.mkdir_p!(Path.join(bundle_path, "weights"))
    write_manifest!(bundle_path, model_id, version, manifest_resident)

    expected_resident =
      if weights? do
        weights = "resident-memory-weights"
        File.write!(Path.join([bundle_path, "weights", "model.safetensors"]), weights)
        byte_size(weights)
      else
        0
      end

    %{
      model_id: model_id,
      version: version,
      bundle_path: bundle_path,
      sha: tree_sha!(bundle_path),
      expected_resident: expected_resident
    }
  end

  defp write_manifest!(bundle_path, model_id, version, resident_memory_bytes) do
    manifest = %{
      "model_id" => model_id,
      "version" => version,
      "format" => "mlx",
      "resident_memory_bytes" => resident_memory_bytes
    }

    File.write!(Path.join(bundle_path, "manifest.json"), Jason.encode!(manifest))
  end

  defp create_catalog_model!(ctx, overrides) do
    overrides = Map.new(overrides)

    defaults = %{
      artifact_uri: "file://#{Path.join([ctx.artifacts_root, "default", "v1"])}",
      artifact_source_uri: Map.get(overrides, :artifact_uri),
      artifact_sha256: String.duplicate("a", 64),
      resident_memory_bytes: 0
    }

    defaults
    |> Map.merge(overrides)
    |> create_model!()
  end

  defp read_manifest!(bundle_path) do
    bundle_path
    |> Path.join("manifest.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp tree_sha!(bundle_path) do
    assert {:ok, sha} = ArtifactBundle.tree_sha256(bundle_path)
    sha
  end

  defp fail_second_write do
    counter = :counters.new(1, [])

    fn path, content ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 -> FS.atomic_write!(path, content)
        _other -> {:error, :rollback_failed}
      end
    end
  end

  defp quiet_log, do: fn _message -> :ok end
  defp test_log, do: fn message -> send(self(), {:backfill_log, message}) end
end
