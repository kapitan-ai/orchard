defmodule Orchard.Models.ImporterTest do
  use Orchard.DataCase, async: false

  alias Orchard.Models
  alias Orchard.Models.Importer

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)

  setup do
    # Create a temporary artifacts_root for each test
    artifacts_root =
      System.tmp_dir!()
      |> Path.join("orchard_importer_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(artifacts_root)

    on_exit(fn -> File.rm_rf!(artifacts_root) end)

    %{artifacts_root: artifacts_root}
  end

  describe "import_bundle/2" do
    test "imports a valid bundle as :registered", %{artifacts_root: artifacts_root} do
      assert {:ok, model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert model.model_id == "test-org/tiny-llm"
      assert model.version == "mlx-q4-v1"
      assert model.state == :registered
      assert model.format == "mlx"
      assert model.capabilities == ["chat"]
      assert model.max_context_tokens == 4_096

      # SHA-256 is computed, not from manifest
      assert is_binary(model.artifact_sha256)
      assert String.length(model.artifact_sha256) == 64
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, model.artifact_sha256)

      assert model.artifact_uri ==
               "file://#{Path.join([artifacts_root, "test-org/tiny-llm", "mlx-q4-v1"])}"

      # Verify the bundle was actually copied
      dest = Path.join([artifacts_root, "test-org/tiny-llm", "mlx-q4-v1"])
      assert File.exists?(Path.join(dest, "manifest.json"))
      assert File.exists?(Path.join(dest, "tokenizer.json"))
      assert File.exists?(Path.join(dest, "weights/model.safetensors"))
    end

    test "imports with --activate sets state to :active", %{artifacts_root: artifacts_root} do
      assert {:ok, model} =
               Importer.import_bundle(@fixture_bundle,
                 artifacts_root: artifacts_root,
                 activate: true
               )

      assert model.state == :active

      # Should show up in active models list
      active = Models.list_active_models()
      assert length(active) == 1
      assert hd(active).id == model.id
    end

    test "rejects duplicate model_id + version", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert {:error, {:duplicate, message}} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert message =~ "test-org/tiny-llm@mlx-q4-v1"
      assert message =~ "already exists"
    end

    test "rejects nonexistent source path", %{artifacts_root: artifacts_root} do
      assert {:error, {:source_not_found, "/nonexistent/path"}} =
               Importer.import_bundle("/nonexistent/path", artifacts_root: artifacts_root)
    end

    test "rejects source that is a file instead of directory", %{artifacts_root: artifacts_root} do
      file_path = Path.join(artifacts_root, "not_a_dir.txt")
      File.write!(file_path, "hi")

      assert {:error, {:source_not_directory, message}} =
               Importer.import_bundle(file_path, artifacts_root: artifacts_root)

      assert message =~ "expected a directory"
    end

    test "rejects bundle without manifest.json", %{artifacts_root: artifacts_root} do
      empty_bundle = Path.join(artifacts_root, "empty_bundle")
      File.mkdir_p!(empty_bundle)

      assert {:error, {:manifest_not_found, _path}} =
               Importer.import_bundle(empty_bundle, artifacts_root: artifacts_root)
    end

    test "imported model is visible via list when active", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle,
                 artifacts_root: artifacts_root,
                 activate: true
               )

      models = Models.list_active_models()
      assert length(models) == 1

      model = hd(models)
      assert model.model_id == "test-org/tiny-llm"
      assert model.version == "mlx-q4-v1"
    end

    test "registered model is not visible in active list", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      assert Models.list_active_models() == []
    end

    test "SHA-256 is deterministic across imports with different staging paths", %{
      artifacts_root: artifacts_root
    } do
      # Import the same bundle into two separate roots. The random staging-*
      # directory name must NOT leak into the hash.
      root2 =
        System.tmp_dir!()
        |> Path.join("orchard_sha_test_#{:rand.uniform(1_000_000)}")

      File.mkdir_p!(root2)
      on_exit(fn -> File.rm_rf!(root2) end)

      assert {:ok, m1} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      # Delete the catalog record so the duplicate check passes for the second import
      Orchard.Repo.delete!(m1)

      assert {:ok, m2} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: root2)

      assert m1.artifact_sha256 == m2.artifact_sha256
    end

    test "no staging directory remains on success", %{artifacts_root: artifacts_root} do
      assert {:ok, _model} =
               Importer.import_bundle(@fixture_bundle, artifacts_root: artifacts_root)

      staging_dirs =
        artifacts_root
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, ".staging-"))

      assert staging_dirs == []
    end
  end

  describe "import_bundle/2 security" do
    test "rejects model_id with path traversal", %{artifacts_root: artifacts_root} do
      # Create a bundle with traversal in model_id
      evil_bundle = create_bundle(artifacts_root, %{"model_id" => "../escape"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "path traversal"
    end

    test "rejects version with path traversal", %{artifacts_root: artifacts_root} do
      evil_bundle = create_bundle(artifacts_root, %{"version" => "../../etc"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "path traversal"
    end

    test "rejects model_id with unsafe characters", %{artifacts_root: artifacts_root} do
      evil_bundle = create_bundle(artifacts_root, %{"model_id" => "model; rm -rf /"})

      assert {:error, {:validation, message}} =
               Importer.import_bundle(evil_bundle, artifacts_root: artifacts_root)

      assert message =~ "unsafe characters"
    end

    test "rejects symlinks in bundle contents", %{artifacts_root: artifacts_root} do
      # Create a bundle with a symlink
      bundle_dir = Path.join(artifacts_root, "symlink_bundle")
      File.mkdir_p!(bundle_dir)

      write_manifest(bundle_dir, %{"model_id" => "safe-model", "version" => "v1"})

      # Create a symlink pointing outside the bundle
      outside_file = Path.join(artifacts_root, "secret.txt")
      File.write!(outside_file, "secret data")
      File.ln_s!(outside_file, Path.join(bundle_dir, "linked.txt"))

      assert {:error, {:symlink_rejected, message}} =
               Importer.import_bundle(bundle_dir, artifacts_root: artifacts_root)

      assert message =~ "symlinks not allowed"
    end
  end

  # -- Test helpers ----------------------------------------------------------

  defp create_bundle(root, manifest_overrides) do
    bundle_dir = Path.join(root, "test_bundle_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(bundle_dir)
    write_manifest(bundle_dir, manifest_overrides)
    bundle_dir
  end

  defp write_manifest(bundle_dir, overrides) do
    manifest =
      Map.merge(
        %{
          "model_id" => "test-org/tiny-llm",
          "version" => "mlx-q4-v1",
          "format" => "mlx",
          "artifact_layout" => "directory",
          "entrypoint" => "weights/",
          "sha256" => String.duplicate("a", 64),
          "size_bytes" => 1024,
          "resident_memory_bytes" => 2048,
          "kv_cache_bytes_per_token" => 16,
          "prefill_workspace_bytes_per_token" => 8,
          "max_context_tokens" => 4096,
          "capabilities" => ["chat"],
          "tokenizer" => %{"kind" => "huggingface_tokenizer_json", "path" => "tokenizer.json"},
          "runtime_requirements" => %{"adapter" => "mlx_lm", "min_agent_capability" => "mlx"}
        },
        overrides
      )

    File.write!(Path.join(bundle_dir, "manifest.json"), Jason.encode!(manifest))
  end
end
