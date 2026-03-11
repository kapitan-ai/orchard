defmodule Orchard.Node.ModelAcquisitionTest do
  use ExUnit.Case, async: true

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("model_acquisition_test_#{:rand.uniform(1_000_000)}")

    models_root = Path.join(tmp_dir, "models")
    source_dir = Path.join(tmp_dir, "source")

    File.mkdir_p!(models_root)
    File.mkdir_p!(source_dir)

    # Create a source bundle
    File.write!(Path.join(source_dir, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_dir, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_dir, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{
      tmp_dir: tmp_dir,
      models_root: models_root,
      source_dir: source_dir,
      source_uri: "file://#{source_dir}",
      hash: hash
    }
  end

  describe "ensure_cached/1 with file:// source" do
    test "materializes bundle from file:// source into cache", ctx do
      request = build_request(ctx)

      assert {:ok, final_path, :materialized} = ModelAcquisition.ensure_cached(request)
      assert File.dir?(final_path)
      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(final_path)
    end

    test "returns cache_hit when bundle already exists and hash matches", ctx do
      request = build_request(ctx)

      # Pre-stage at cache location
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
    end

    test "returns error when source URI is blank and cache is missing", ctx do
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "test-org/model",
        version: "v1",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: System.system_time(:millisecond) + 5_000,
        artifact_source_uri: ""
      }

      {:ok, request} = Request.from_proto(proto, ctx.models_root)

      assert {:error, :missing_artifact_source_uri} = ModelAcquisition.ensure_cached(request)
    end

    test "returns cache_hit when source URI is blank but cache exists and verifies", ctx do
      # Pre-stage at cache location
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      # Now build a request with blank source URI
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "test-org/model",
        version: "v1",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: System.system_time(:millisecond) + 5_000,
        artifact_source_uri: ""
      }

      {:ok, no_source_request} = Request.from_proto(proto, ctx.models_root)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(no_source_request)
    end

    test "hash mismatch does not promote staging directory", ctx do
      request = build_request(ctx, artifact_sha256: String.duplicate("0", 64))

      assert {:error, :artifact_hash_mismatch} = ModelAcquisition.ensure_cached(request)

      # Final path should not exist
      refute File.exists?(request.final_path)

      # Staging should be cleaned up
      refute File.exists?(request.staging_path)
    end

    test "stale staging directory is removed before retry", ctx do
      request = build_request(ctx)

      # Create a stale staging directory with junk
      File.mkdir_p!(request.staging_path)
      File.write!(Path.join(request.staging_path, "stale.txt"), "old data")

      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Staging should be gone (renamed to final)
      refute File.exists?(request.staging_path)
      assert File.dir?(request.final_path)
    end

    test "corrupted cache is replaced by re-acquisition from file:// source", ctx do
      request = build_request(ctx)

      # Pre-stage a corrupted cache (wrong content)
      File.mkdir_p!(request.final_path)
      File.write!(Path.join(request.final_path, "corrupted.txt"), "bad data")

      assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)

      # Cache should now have correct content
      expected_hash = ctx.hash
      assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(request.final_path)
    end
  end

  describe "Request.from_proto/2" do
    test "builds valid request from proto", ctx do
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "test-org/model",
        version: "v1",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: System.system_time(:millisecond) + 5_000,
        artifact_source_uri: ctx.source_uri
      }

      assert {:ok, %Request{} = req} = Request.from_proto(proto, ctx.models_root)
      assert req.model_id == "test-org/model"
      assert req.version == "v1"
      assert req.source_scheme == "file"
      assert req.final_path == Path.join([ctx.models_root, "test-org/model", "v1"])
      assert req.staging_path == Path.join([ctx.models_root, ".staging", "test-org/model", "v1"])
    end

    test "normalizes blank source URI to nil", ctx do
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "test-org/model",
        version: "v1",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: 0,
        artifact_source_uri: ""
      }

      assert {:ok, %Request{artifact_source_uri: nil, source_scheme: nil}} =
               Request.from_proto(proto, ctx.models_root)
    end

    test "rejects missing model_id", ctx do
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "",
        version: "v1",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: 0
      }

      assert {:error, :missing_model_id} = Request.from_proto(proto, ctx.models_root)
    end

    test "rejects missing version", ctx do
      proto = %EnsureModelLoadedRequest{
        node_id: "node-local",
        model_id: "test-org/model",
        version: "",
        artifact_sha256: ctx.hash,
        preload: true,
        deadline_unix_ms: 0
      }

      assert {:error, :missing_version} = Request.from_proto(proto, ctx.models_root)
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp build_request(ctx, overrides \\ []) do
    proto = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: "test-org/model",
      version: "v1",
      artifact_sha256: Keyword.get(overrides, :artifact_sha256, ctx.hash),
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: Keyword.get(overrides, :artifact_source_uri, ctx.source_uri)
    }

    {:ok, request} = Request.from_proto(proto, ctx.models_root)
    request
  end
end
