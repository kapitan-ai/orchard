defmodule Orchard.Node.ModelAcquisitionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Node.ModelAcquisition
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.VerificationReceipt

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("model_acquisition_test_#{:rand.uniform(1_000_000)}")

    models_root = Path.join(tmp_dir, "models")
    source_dir = Path.join(tmp_dir, "source")

    File.mkdir_p!(models_root)
    File.mkdir_p!(source_dir)

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

    test "first acquisition seeds a receipt for the next unchanged load", ctx do
      request = build_request(ctx)

      assert count_tree_hash_calls(fn ->
               assert {:ok, _path, :materialized} = ModelAcquisition.ensure_cached(request)
               assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
             end) == 1

      [receipt_path] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))
      assert %File.Stat{mode: mode} = File.stat!(receipt_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      receipt = receipt_path |> File.read!() |> Jason.decode!()
      assert {:ok, evidence} = VerificationReceipt.inventory_evidence(request.final_path)
      assert evidence.fingerprint == receipt["inventory_sha256"]
      assert File.stat!(request.final_path, time: :posix).mtime == 946_684_800

      assert File.stat!(
               Path.join(request.final_path, "weights/model.safetensors"),
               time: :posix
             ).mtime == 946_684_800
    end

    test "returns cache_hit when bundle already exists and hash matches", ctx do
      request = build_request(ctx)

      # Pre-stage at cache location
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
    end

    test "SPEC 6.7 previously verified unchanged cache skips the second tree hash", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      log =
        capture_info_log(fn ->
          tree_hash_calls =
            count_tree_hash_calls(fn ->
              assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
              assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
            end)

          assert tree_hash_calls == 1
        end)

      assert log =~ "verification_path=full"
      assert log =~ "verification_path=fast"
      refute log =~ request.final_path
    end

    test "SPEC 6.7 immediate same-size shard tampering invalidates the receipt", ctx do
      request = build_request(ctx)
      no_source_request = build_request(ctx, artifact_source_uri: nil)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      shard = Path.join(request.final_path, "weights/model.safetensors")
      File.write!(shard, "evil-weights-data")

      log =
        capture_info_log(fn ->
          assert count_tree_hash_calls(fn ->
                   assert {:error, :artifact_hash_mismatch} =
                            ModelAcquisition.ensure_cached(no_source_request)
                 end) == 1
        end)

      assert log =~ "verification_path=invalidated"
      assert log =~ "verification_path=failed"
      refute log =~ request.final_path
    end

    test "SPEC 6.7 truncated shard invalidates the receipt and is rejected", ctx do
      request = build_request(ctx)
      no_source_request = build_request(ctx, artifact_source_uri: nil)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      shard = Path.join(request.final_path, "weights/model.safetensors")
      File.write!(shard, "short")

      assert count_tree_hash_calls(fn ->
               assert {:error, :artifact_hash_mismatch} =
                        ModelAcquisition.ensure_cached(no_source_request)
             end) == 1
    end

    test "operator can force authoritative verification of an unchanged receipt", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      log =
        capture_info_log(fn ->
          assert count_tree_hash_calls(fn ->
                   assert {:ok, _path, :cache_hit} =
                            ModelAcquisition.ensure_cached(request, force_full?: true)
                 end) == 1
        end)

      assert log =~ "verification_path=full"
      assert log =~ "reason=operator_forced"
    end

    test "forced verification fails before hashing when the prior receipt cannot be revoked",
         ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
      verification_dir = Path.join(ctx.models_root, ".verification")
      File.chmod!(verification_dir, 0o500)

      try do
        assert count_tree_hash_calls(fn ->
                 assert {:error, :receipt_invalidation_failed} =
                          ModelAcquisition.ensure_cached(request, force_full?: true)
               end) == 0
      after
        File.chmod!(verification_dir, 0o700)
      end
    end

    test "malformed receipt fails closed to authoritative verification", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
      [receipt_path] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))
      File.write!(receipt_path, "not-json")

      log =
        capture_info_log(fn ->
          assert count_tree_hash_calls(fn ->
                   assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
                 end) == 1
        end)

      assert log =~ "verification_path=invalidated"
      assert log =~ "reason=receipt_invalid"
    end

    test "future receipt timestamp fails closed to authoritative verification", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
      [receipt_path] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))

      receipt = receipt_path |> File.read!() |> Jason.decode!()
      future_receipt = Map.put(receipt, "verified_at_posix", System.system_time(:second) + 3_600)
      File.write!(receipt_path, Jason.encode!(future_receipt))

      log =
        capture_info_log(fn ->
          assert count_tree_hash_calls(fn ->
                   assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
                 end) == 1
        end)

      assert log =~ "verification_path=invalidated"
      assert log =~ "reason=receipt_invalid"
    end

    test "forced verification failure invalidates the prior receipt", ctx do
      request = build_request(ctx)
      no_source_request = build_request(ctx, artifact_source_uri: nil)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      assert [_receipt_path] =
               Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))

      shard = Path.join(request.final_path, "weights/model.safetensors")
      File.write!(shard, "evil-weights-data")

      assert {:error, :artifact_hash_mismatch} =
               ModelAcquisition.ensure_cached(no_source_request, force_full?: true)

      assert [] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))

      assert count_tree_hash_calls(fn ->
               assert {:error, :artifact_hash_mismatch} =
                        ModelAcquisition.ensure_cached(no_source_request)
             end) == 1
    end

    test "receipt persistence failure logs only a bounded reason and falls back next load", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      persistor = fn _persisted_request, _evidence, :verified ->
        {:error, :receipt_write_failed}
      end

      log =
        capture_info_log(fn ->
          assert {:ok, _path, :cache_hit} =
                   ModelAcquisition.ensure_cached(request, receipt_persistor: persistor)
        end)

      assert log =~ "reason=receipt_write_failed"
      refute log =~ ctx.models_root
      refute log =~ request.final_path
      refute log =~ ctx.source_uri

      assert count_tree_hash_calls(fn ->
               assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)
             end) == 1
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

      log =
        capture_info_log(fn ->
          assert {:error, :artifact_hash_mismatch} = ModelAcquisition.ensure_cached(request)
        end)

      assert log =~ "verification_path=full"
      assert log =~ "verification_path=failed"
      assert log =~ "reason=artifact_hash_mismatch"
      refute log =~ request.final_path

      # Final path should not exist
      refute File.exists?(request.final_path)

      # Staging should be cleaned up
      refute File.exists?(request.staging_path)
    end

    test "stale staging directory is removed before retry", ctx do
      request = build_request(ctx)

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

  describe "verification receipt publication" do
    test "initial verification inventory rejects an entry that lost the sentinel mtime", ctx do
      assert {:ok, _evidence, _verified_at} =
               VerificationReceipt.prepare_for_verification(ctx.source_dir)

      File.write!(Path.join(ctx.source_dir, "weights/model.safetensors"), "evil-weights-data")

      assert {:error, :inventory_changed_after_normalization} =
               VerificationReceipt.inventory_evidence(ctx.source_dir,
                 require_normalized_mtime?: true
               )
    end

    test "existing-cache mutation rejected during receipt publication fails closed", ctx do
      request = build_request(ctx, artifact_source_uri: nil)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      persistor = fn persisted_request, evidence, :verified ->
        File.write!(
          Path.join(persisted_request.final_path, "weights/model.safetensors"),
          "evil-weights-data"
        )

        VerificationReceipt.record_verified(persisted_request, evidence)
      end

      log =
        capture_info_log(fn ->
          assert {:error, {:verification_receipt_rejected, :inventory_changed_after_verification}} =
                   ModelAcquisition.ensure_cached(request, receipt_persistor: persistor)
        end)

      assert log =~ "verification_path=failed"
      assert log =~ "reason=inventory_changed_after_verification"
      assert [] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))
    end

    test "post-promotion mutation rejected during receipt publication removes the cache", ctx do
      request = build_request(ctx)

      persistor = fn persisted_request, evidence, :promoted ->
        File.write!(
          Path.join(persisted_request.final_path, "weights/model.safetensors"),
          "evil-weights-data"
        )

        VerificationReceipt.record(persisted_request, evidence)
      end

      assert {:error, {:verification_receipt_rejected, :inventory_changed_after_verification}} =
               ModelAcquisition.ensure_cached(request, receipt_persistor: persistor)

      refute File.exists?(request.final_path)
      refute File.exists?(request.staging_path)
      assert [] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))
    end

    test "failed reacquisition invalidates an older receipt through a symlinked models root",
         ctx do
      physical_root = Path.join(ctx.tmp_dir, "physical-models")
      symlinked_root = Path.join(ctx.tmp_dir, "symlinked-models")
      File.mkdir_p!(physical_root)
      File.ln_s!(physical_root, symlinked_root)

      request = build_request(%{ctx | models_root: symlinked_root})
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      assert [_receipt_path] =
               Path.wildcard(Path.join([physical_root, ".verification", "*.json"]))

      File.rm_rf!(request.final_path)
      File.write!(Path.join(ctx.source_dir, "weights/model.safetensors"), "corrupt-source")

      assert {:error, :artifact_hash_mismatch} = ModelAcquisition.ensure_cached(request)
      assert [] = Path.wildcard(Path.join([physical_root, ".verification", "*.json"]))
    end

    test "post-publication root metadata change invalidates the complete inventory", ctx do
      request = build_request(ctx)
      no_source_request = build_request(ctx, artifact_source_uri: nil)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, _path, :cache_hit} = ModelAcquisition.ensure_cached(request)

      File.chmod!(request.final_path, 0o700)

      log =
        capture_info_log(fn ->
          assert count_tree_hash_calls(fn ->
                   assert {:ok, _path, :cache_hit} =
                            ModelAcquisition.ensure_cached(no_source_request)
                 end) == 1
        end)

      assert log =~ "verification_path=invalidated"
      assert log =~ "reason=inventory_changed"
    end

    test "rejects an inventory change after authoritative verification", ctx do
      request = build_request(ctx)
      File.mkdir_p!(request.final_path)
      :ok = ArtifactBundle.copy_directory(ctx.source_dir, request.final_path)

      assert {:ok, evidence, verification_boundary} =
               VerificationReceipt.prepare_for_verification(request.final_path)

      File.write!(Path.join(request.final_path, "weights/model.safetensors"), "evil-weights-data")

      assert {:error, :inventory_changed_after_verification} =
               VerificationReceipt.record(
                 request,
                 Map.put(evidence, :verified_at, verification_boundary)
               )

      assert [] = Path.wildcard(Path.join([ctx.models_root, ".verification", "*.json"]))
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

  defp count_tree_hash_calls(fun) do
    mfa = {ArtifactBundle, :tree_sha256, 1}
    :erlang.trace_pattern(mfa, true, [:call_count])
    {:call_count, before_count} = :erlang.trace_info(mfa, :call_count)

    try do
      fun.()
      {:call_count, after_count} = :erlang.trace_info(mfa, :call_count)
      after_count - before_count
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  defp capture_info_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end
end
