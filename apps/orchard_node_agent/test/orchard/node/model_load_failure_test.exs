defmodule Orchard.Node.ModelLoadFailureTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.ModelLoadFailure
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse

  # -- MODEL_INVALID --

  test "missing_model_id -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:missing_model_id)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "missing_model_id"
    assert f.message == "model identifier is missing"
  end

  test "missing_version -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:missing_version)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "missing_version"
  end

  test "missing_artifact_sha256 -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:missing_artifact_sha256)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "missing_artifact_sha256"
  end

  test "invalid_source_uri -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:invalid_source_uri)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "invalid_source_uri"
  end

  test "unsupported_source_scheme -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:unsupported_source_scheme, "ftp"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "unsupported_source_scheme"
  end

  test "path_escape -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:path_escape)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "path_escape"
  end

  test "artifact_hash_mismatch -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason(:artifact_hash_mismatch)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "artifact_hash_mismatch"
  end

  test "cache_verification_failed -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:cache_verification_failed, :some_reason})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "cache_verification_failed"
  end

  test "verification_failed -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:verification_failed, :some_reason})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "verification_failed"
  end

  test "invalid_source_layout -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:invalid_source_layout, "bad layout"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "invalid_source_layout"
  end

  test "archive_extract_failed -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:archive_extract_failed, "corrupt"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "archive_extract_failed"
  end

  test "source_not_directory -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:source_not_directory, "/some/path"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "source_not_directory"
  end

  test "unsupported_archive_extension -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:unsupported_archive_extension, ".rar"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "unsupported_archive_extension"
  end

  # -- MODEL_INVALID via worker load codes --

  test "worker_load_failed with manifest_not_found -> MODEL_INVALID" do
    f =
      ModelLoadFailure.from_reason(
        {:worker_load_failed, "manifest_not_found", "manifest.json missing"}
      )

    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "manifest_not_found"
    assert f.message == "model manifest is missing"
  end

  test "worker_load_failed with unsupported_model_format -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "unsupported_model_format", "detail"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "unsupported_model_format"
  end

  test "worker_load_failed with tokenizer_missing -> MODEL_INVALID" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "tokenizer_missing", "detail"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert f.code == "tokenizer_missing"
  end

  # -- ACQUISITION_FAILED --

  test "missing_artifact_source_uri -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason(:missing_artifact_source_uri)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "missing_artifact_source_uri"
  end

  test "source_not_found -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason({:source_not_found, "not found"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "source_not_found"
  end

  test "source_unauthorized -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason({:source_unauthorized, "401"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "source_unauthorized"
  end

  test "source_unavailable -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason({:source_unavailable, "503"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "source_unavailable"
  end

  test "download_failed -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason({:download_failed, "network"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "download_failed"
  end

  test "download_incomplete -> ACQUISITION_FAILED" do
    f = ModelLoadFailure.from_reason({:download_incomplete, "partial"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert f.code == "download_incomplete"
  end

  # -- RUNTIME_UNAVAILABLE --

  test "worker_executable_not_found -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason(:worker_executable_not_found)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "worker_executable_not_found"
  end

  test "worker_unavailable -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason(:worker_unavailable)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "worker_unavailable"
  end

  test "worker_exited -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason({:worker_exited, 1})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "worker_exited"
  end

  test "rpc_error -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason({:rpc_error, :unavailable})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "rpc_error"
  end

  test "worker_unhealthy with mlx_backend_unavailable -> RUNTIME_UNAVAILABLE" do
    f =
      ModelLoadFailure.from_reason(
        {:worker_unhealthy, "mlx_backend_unavailable", "worker is unhealthy"}
      )

    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "mlx_backend_unavailable"
    assert f.message == "MLX backend is unavailable on this node"
  end

  test "worker_unhealthy with metal_unavailable -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason({:worker_unhealthy, "metal_unavailable", "no Metal"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "metal_unavailable"
    assert f.message == "Metal is unavailable on this node"
  end

  test "worker_unhealthy with unknown code -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason({:worker_unhealthy, "some_new_code", "details"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "some_new_code"
    assert f.message == "model runtime is unhealthy on this node"
  end

  test "worker_load_failed with mlx_backend_unavailable -> RUNTIME_UNAVAILABLE" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "mlx_backend_unavailable", "detail"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "mlx_backend_unavailable"
  end

  # -- TIMEOUT --

  test "deadline_exceeded -> TIMEOUT" do
    f = ModelLoadFailure.from_reason(:deadline_exceeded)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
    assert f.code == "deadline_exceeded"
    assert f.message == "model load exceeded its deadline"
  end

  test "worker_ready_timeout -> TIMEOUT" do
    f = ModelLoadFailure.from_reason(:worker_ready_timeout)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
    assert f.code == "worker_ready_timeout"
  end

  # -- RESOURCE_EXHAUSTED --

  test "model_capacity_exhausted -> RESOURCE_EXHAUSTED" do
    f = ModelLoadFailure.from_reason(:model_capacity_exhausted)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED
    assert f.code == "model_capacity_exhausted"
    assert f.message == "node runtime is at loaded-model capacity"
  end

  test "to_response for model_capacity_exhausted" do
    response = ModelLoadFailure.to_response(:model_capacity_exhausted)
    assert %EnsureModelLoadedResponse{} = response
    assert response.already_loaded == false
    assert response.placement_state == :PLACEMENT_STATE_FAILED
    assert response.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED
    assert response.failure_code == "model_capacity_exhausted"
    assert response.failure_message == "node runtime is at loaded-model capacity"
  end

  # -- INTERNAL --

  test "task_crashed -> INTERNAL" do
    f = ModelLoadFailure.from_reason(:task_crashed)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "task_crashed"
  end

  test "load_cancelled -> INTERNAL" do
    f = ModelLoadFailure.from_reason(:load_cancelled)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "load_cancelled"
  end

  test "conflicting_request -> INTERNAL" do
    f = ModelLoadFailure.from_reason(:conflicting_request)
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "conflicting_request"
  end

  test "staging_failed -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:staging_failed, :eacces})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "staging_failed"
  end

  test "finalize_failed -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:finalize_failed, :eacces})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "finalize_failed"
  end

  test "filesystem_error -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:filesystem_error, :enoent})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "filesystem_error"
  end

  test "invalid_source_config -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:invalid_source_config, "bad config"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "invalid_source_config"
  end

  test "worker_load_failed with model_load_failed -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "model_load_failed", "OOM"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "model_load_failed"
  end

  test "worker_load_failed with unknown code -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "some_future_code", "detail"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "some_future_code"
  end

  test "legacy 2-tuple worker_load_failed -> INTERNAL" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "code: detail"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "worker_load_failed"
  end

  # -- Catch-all --

  test "unknown reason -> INTERNAL with internal_error" do
    f = ModelLoadFailure.from_reason({:totally_new_error, "surprise"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "internal_error"
    assert f.message == "model load failed due to an internal error"
  end

  # -- Sanitization --

  test "worker_unhealthy with invalid code format sanitizes to fallback" do
    f = ModelLoadFailure.from_reason({:worker_unhealthy, "INVALID-CODE!", "details"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
    assert f.code == "worker_unhealthy"
  end

  test "worker_load_failed with empty code sanitizes to fallback" do
    f = ModelLoadFailure.from_reason({:worker_load_failed, "", "details"})
    assert f.category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
    assert f.code == "worker_load_failed"
  end

  # -- to_response/1 --

  test "to_response builds a complete failed EnsureModelLoadedResponse" do
    response = ModelLoadFailure.to_response(:artifact_hash_mismatch)
    assert %EnsureModelLoadedResponse{} = response
    assert response.already_loaded == false
    assert response.placement_state == :PLACEMENT_STATE_FAILED
    assert response.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert response.failure_code == "artifact_hash_mismatch"
    assert response.failure_message == "model artifact verification failed"
  end

  test "to_response for timeout" do
    response = ModelLoadFailure.to_response(:deadline_exceeded)
    assert response.placement_state == :PLACEMENT_STATE_FAILED
    assert response.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
    assert response.failure_code == "deadline_exceeded"
  end
end
