defmodule Orchard.Models.ResidentMemoryBackfillTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.ArtifactBundle
  alias Orchard.FS
  alias Orchard.ModelManifest
  alias Orchard.Models.ManifestParser
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

  test "rewritten manifest reparses with ManifestParser and preserves top-level fields", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx,
        manifest_overrides: %{
          "chat_template" => %{
            "path" => "tokenizer_config.json",
            "sha256" => String.duplicate("b", 64)
          },
          "safe_tokenization" => safe_tokenization_map(["<|eot_id|>"])
        }
      )

    before_write = read_manifest!(bundle_path)

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.processed == 1
    assert result.updated == 1
    assert result.failed == 0

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == expected_resident
    assert {:ok, updated_model.artifact_sha256} == ArtifactBundle.tree_sha256(bundle_path)

    after_write = read_manifest!(bundle_path)
    assert Map.keys(after_write) |> Enum.sort() == Map.keys(before_write) |> Enum.sort()

    assert Map.drop(after_write, ["resident_memory_bytes"]) ==
             Map.drop(before_write, ["resident_memory_bytes"])

    assert %{"resident_memory_bytes" => ^expected_resident} = after_write

    assert {:ok, %ModelManifest{resident_memory_bytes: ^expected_resident}} =
             ManifestParser.parse_from_bundle(bundle_path)
  end

  test "rewritten manifest inserts omitted resident_memory_bytes deterministically and reparses",
       ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx, manifest_resident_memory_bytes: :omit)

    before_write = read_manifest!(bundle_path)
    refute Map.has_key?(before_write, "resident_memory_bytes")

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.updated == 1
    assert result.failed == 0

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    after_write = read_manifest!(bundle_path)

    assert Map.drop(after_write, ["resident_memory_bytes"]) == before_write
    assert after_write["resident_memory_bytes"] == expected_resident
    assert updated_model.resident_memory_bytes == expected_resident

    assert {:ok, %ModelManifest{resident_memory_bytes: ^expected_resident}} =
             ManifestParser.parse_from_bundle(bundle_path)
  end

  test "already-present resident memory leaves manifest byte-identical and parser-valid", ctx do
    %{model: model, bundle_path: bundle_path} =
      create_estimable_model!(ctx,
        resident_memory_bytes: 123,
        manifest_resident_memory_bytes: 123
      )

    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.skipped_already_present == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest
    assert Repo.get!(Orchard.Models.Model, model.id).resident_memory_bytes == 123

    assert {:ok, %ModelManifest{resident_memory_bytes: 123}} =
             ManifestParser.parse_from_bundle(bundle_path)
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

  test "malformed manifest JSON fails without disk or catalog mutation", ctx do
    %{bundle_path: bundle_path} = create_bundle!(ctx, manifest_json: "{bad json")
    original_sha = tree_sha!(bundle_path)
    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    model =
      create_catalog_model!(ctx,
        artifact_uri: "file://#{bundle_path}",
        artifact_sha256: original_sha
      )

    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.failed == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == 0
    assert updated_model.artifact_sha256 == original_sha
  end

  test "parser-invalid manifest object fails before rewrite and leaves disk and DB unchanged",
       ctx do
    %{bundle_path: bundle_path} =
      create_bundle!(ctx,
        manifest_overrides: %{"unexpected" => "field"},
        manifest_resident_memory_bytes: 0
      )

    original_sha = tree_sha!(bundle_path)
    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    model =
      create_catalog_model!(ctx,
        artifact_uri: "file://#{bundle_path}",
        artifact_sha256: original_sha
      )

    assert {:error, _reason} = ManifestParser.parse_from_bundle(bundle_path)
    assert {:ok, result} = ResidentMemoryBackfill.run(apply: true, log: quiet_log())
    assert result.failed == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == 0
    assert updated_model.artifact_sha256 == original_sha
  end

  test "post-write parser reparse failure rolls back manifest and leaves catalog unchanged",
       ctx do
    %{model: model, bundle_path: bundle_path, sha: sha} = create_estimable_model!(ctx)
    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    assert {:ok, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               write_manifest: corrupt_first_write()
             )

    assert result.failed == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest
    assert tree_sha!(bundle_path) == sha

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == 0
    assert updated_model.artifact_sha256 == sha

    assert {:ok, %ModelManifest{resident_memory_bytes: 0}} =
             ManifestParser.parse_from_bundle(bundle_path)
  end

  test "post-write resident-memory mismatch rolls back manifest and leaves catalog unchanged",
       ctx do
    %{model: model, bundle_path: bundle_path, sha: sha, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    original_manifest = File.read!(Path.join(bundle_path, "manifest.json"))

    assert {:ok, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               write_manifest: mismatch_resident_memory_first_write(expected_resident + 1)
             )

    assert result.failed == 1
    assert result.updated == 0
    assert File.read!(Path.join(bundle_path, "manifest.json")) == original_manifest
    assert tree_sha!(bundle_path) == sha

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == 0
    assert updated_model.artifact_sha256 == sha

    assert {:ok, %ModelManifest{resident_memory_bytes: 0}} =
             ManifestParser.parse_from_bundle(bundle_path)
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

  test "catalog update race with matching backfill skips as already present", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    assert {:ok, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, resident_memory_bytes, _pre_sha, new_sha ->
                 assert resident_memory_bytes == expected_resident

                 model
                 |> Ecto.Changeset.change(
                   resident_memory_bytes: resident_memory_bytes,
                   artifact_sha256: new_sha
                 )
                 |> Repo.update!()

                 0
               end
             )

    assert result.skipped_already_present == 1
    assert result.updated == 0
    assert result.failed == 0
    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == expected_resident
    assert updated_model.artifact_sha256 == tree_sha!(bundle_path)
  end

  test "catalog update race with new hash but wrong memory fails without rollback", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    wrong_resident = expected_resident + 1

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, new_sha ->
                 model
                 |> Ecto.Changeset.change(
                   resident_memory_bytes: wrong_resident,
                   artifact_sha256: new_sha
                 )
                 |> Repo.update!()

                 0
               end
             )

    assert result.failed == 1
    assert result.updated == 0
    assert result.skipped_concurrent == 0
    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == wrong_resident
    assert updated_model.artifact_sha256 == tree_sha!(bundle_path)
  end

  test "catalog update race with pre-repair hash but wrong memory rolls back and reports failed",
       ctx do
    %{
      model: model,
      bundle_path: bundle_path,
      sha: original_sha,
      expected_resident: expected_resident
    } =
      create_estimable_model!(ctx)

    wrong_resident = expected_resident + 1

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, _new_sha ->
                 model
                 |> Ecto.Changeset.change(
                   resident_memory_bytes: wrong_resident,
                   artifact_sha256: original_sha
                 )
                 |> Repo.update!()

                 0
               end
             )

    assert result.failed == 1
    assert result.updated == 0
    assert result.skipped_concurrent == 0
    assert %{"resident_memory_bytes" => 0} = read_manifest!(bundle_path)
    assert tree_sha!(bundle_path) == original_sha

    updated_model = Repo.get!(Orchard.Models.Model, model.id)
    assert updated_model.resident_memory_bytes == wrong_resident
    assert updated_model.artifact_sha256 == original_sha
  end

  test "catalog update race with positive memory and third hash fails without rollback", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    third_sha = String.duplicate("b", 64)

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, resident_memory_bytes, _pre_sha, _new_sha ->
                 assert resident_memory_bytes == expected_resident

                 model
                 |> Ecto.Changeset.change(
                   resident_memory_bytes: resident_memory_bytes,
                   artifact_sha256: third_sha
                 )
                 |> Repo.update!()

                 0
               end
             )

    assert result.failed == 1
    assert result.updated == 0
    assert result.skipped_concurrent == 0
    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)
    assert Repo.get!(Orchard.Models.Model, model.id).artifact_sha256 == third_sha
    assert tree_sha!(bundle_path) != third_sha
  end

  test "catalog update race with zero memory and third hash fails without rollback", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    third_sha = String.duplicate("c", 64)

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, _new_sha ->
                 model
                 |> Ecto.Changeset.change(artifact_sha256: third_sha, resident_memory_bytes: 0)
                 |> Repo.update!()

                 0
               end
             )

    assert result.failed == 1
    assert result.updated == 0
    assert result.skipped_concurrent == 0
    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)
    assert Repo.get!(Orchard.Models.Model, model.id).artifact_sha256 == third_sha
    assert tree_sha!(bundle_path) != third_sha
  end

  test "catalog update race with deleted model fails without rollback", ctx do
    %{model: model, bundle_path: bundle_path, expected_resident: expected_resident} =
      create_estimable_model!(ctx)

    assert {:error, result} =
             ResidentMemoryBackfill.run(
               apply: true,
               log: quiet_log(),
               update_catalog: fn _model, _resident_memory_bytes, _pre_sha, _new_sha ->
                 Repo.delete!(model)
                 0
               end
             )

    assert result.failed == 1
    assert result.updated == 0
    assert result.skipped_concurrent == 0
    assert %{"resident_memory_bytes" => ^expected_resident} = read_manifest!(bundle_path)
    assert Repo.get(Orchard.Models.Model, model.id) == nil
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
    manifest_overrides = Map.get(opts, :manifest_overrides, %{})

    File.mkdir_p!(Path.join(bundle_path, "weights"))

    case Map.fetch(opts, :manifest_json) do
      {:ok, json} ->
        File.write!(Path.join(bundle_path, "manifest.json"), json)

      :error ->
        write_manifest!(bundle_path, model_id, version, manifest_resident, manifest_overrides)
    end

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

  defp write_manifest!(bundle_path, model_id, version, resident_memory_bytes, overrides) do
    manifest = parser_valid_manifest_map(model_id, version, resident_memory_bytes, overrides)

    File.write!(Path.join(bundle_path, "manifest.json"), Jason.encode!(manifest))
  end

  defp parser_valid_manifest_map(model_id, version, resident_memory_bytes, overrides) do
    model_id
    |> base_manifest_map(version)
    |> maybe_put_resident_memory(resident_memory_bytes)
    |> Map.merge(overrides)
  end

  defp base_manifest_map(model_id, version) do
    %{
      "model_id" => model_id,
      "version" => version,
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => "weights/",
      "sha256" => String.duplicate("a", 64),
      "size_bytes" => 1024,
      "kv_cache_bytes_per_token" => 16,
      "prefill_workspace_bytes_per_token" => 8,
      "max_context_tokens" => 4096,
      "capabilities" => ["chat"],
      "tokenizer" => %{
        "kind" => "huggingface_tokenizer_json",
        "path" => "tokenizer.json"
      },
      "runtime_requirements" => %{
        "adapter" => "mlx_lm",
        "min_agent_capability" => "mlx"
      }
    }
  end

  defp maybe_put_resident_memory(manifest, :omit), do: manifest

  defp maybe_put_resident_memory(manifest, resident_memory_bytes) do
    Map.put(manifest, "resident_memory_bytes", resident_memory_bytes)
  end

  defp safe_tokenization_map(control_tokens) do
    control_tokens = control_tokens |> Enum.uniq() |> Enum.sort()

    %{
      "control_tokens" => control_tokens,
      "catalog_sha256" => catalog_sha256(control_tokens),
      "catalog_source" => %{
        "added_tokens_count" => 0,
        "config_singletons_count" => 0,
        "additional_special_tokens_count" => 0,
        "chat_template_literals_count" => 0,
        "wrapper_tool_markers_count" => 0,
        "extra_count" => 0
      },
      "compatible" => true,
      "template_compatible" => true
    }
  end

  defp catalog_sha256(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
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

  defp corrupt_first_write do
    counter = :counters.new(1, [])

    fn path, content ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          content
          |> Jason.decode!()
          |> Map.put("unexpected", "field")
          |> Jason.encode!()
          |> then(&FS.atomic_write!(path, &1))

        _other ->
          FS.atomic_write!(path, content)
      end
    end
  end

  defp mismatch_resident_memory_first_write(actual_resident_memory_bytes) do
    counter = :counters.new(1, [])

    fn path, content ->
      :counters.add(counter, 1, 1)

      case :counters.get(counter, 1) do
        1 ->
          content
          |> Jason.decode!()
          |> Map.put("resident_memory_bytes", actual_resident_memory_bytes)
          |> Jason.encode!()
          |> then(&FS.atomic_write!(path, &1))

        _other ->
          FS.atomic_write!(path, content)
      end
    end
  end

  defp quiet_log, do: fn _message -> :ok end
  defp test_log, do: fn message -> send(self(), {:backfill_log, message}) end
end
