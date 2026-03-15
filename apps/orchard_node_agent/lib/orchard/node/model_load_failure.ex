defmodule Orchard.Node.ModelLoadFailure do
  @moduledoc """
  Classifies model load failures into sanitized, client-safe categories.

  Converts raw Elixir error reasons from the acquisition pipeline, worker runtime,
  and model manager into structured `%EnsureModelLoadedResponse{}` proto fields.

  Classification happens at the node-agent boundary — this is the single point where
  internal error shapes are mapped to the proto contract.
  """

  alias Orchard.Cluster.V1.{EnsureModelLoadedResponse, ModelLoadFailureCategory}

  @enforce_keys [:category, :code, :message]
  defstruct [:category, :code, :message]

  @type t :: %__MODULE__{
          category: ModelLoadFailureCategory.t(),
          code: String.t(),
          message: String.t()
        }

  # Worker error codes from Python model_loader.py / backends.py that indicate
  # the model artifact itself is invalid (not a runtime problem).
  @worker_model_invalid_codes MapSet.new([
                                "manifest_not_found",
                                "manifest_read_failed",
                                "manifest_decode_error",
                                "manifest_validation_error",
                                "model_identity_mismatch",
                                "unsupported_model_format",
                                "unsupported_artifact_layout",
                                "unsupported_runtime_adapter",
                                "unsupported_tokenizer_kind",
                                "bundle_path_escape",
                                "entrypoint_missing",
                                "tokenizer_missing",
                                "model_path_missing"
                              ])

  # Worker error codes indicating the runtime environment is unavailable.
  @worker_runtime_unavailable_codes MapSet.new([
                                      "mlx_backend_unavailable",
                                      "mlx_probe_failed",
                                      "metal_unavailable"
                                    ])

  @worker_model_invalid_messages %{
    "manifest_not_found" => "model manifest is missing",
    "manifest_read_failed" => "model manifest could not be read",
    "manifest_decode_error" => "model manifest is invalid",
    "manifest_validation_error" => "model manifest failed validation",
    "model_identity_mismatch" => "model artifact identity does not match the requested model",
    "unsupported_model_format" => "model format is unsupported by this runtime",
    "unsupported_artifact_layout" => "model artifact layout is unsupported by this runtime",
    "unsupported_runtime_adapter" => "model runtime adapter is unsupported",
    "unsupported_tokenizer_kind" => "model tokenizer kind is unsupported",
    "bundle_path_escape" => "model bundle contains invalid paths",
    "entrypoint_missing" => "model entrypoint is missing",
    "tokenizer_missing" => "model tokenizer files are missing",
    "model_path_missing" => "model weights path is missing"
  }

  @worker_runtime_unavailable_messages %{
    "mlx_backend_unavailable" => "MLX backend is unavailable on this node",
    "mlx_probe_failed" => "MLX backend probe failed on this node",
    "metal_unavailable" => "Metal is unavailable on this node"
  }

  @doc """
  Classifies a raw error reason into a sanitized failure struct.

  Accepts all known reason shapes from the acquisition pipeline, worker runtime
  adapter, and model manager. Unknown shapes fall through to INTERNAL.
  """
  @spec from_reason(term()) :: t()

  # --- MODEL_INVALID: request validation ---
  def from_reason(:missing_model_id),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "missing_model_id",
        "model identifier is missing"
      )

  def from_reason(:missing_version),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "missing_version",
        "model version is missing"
      )

  def from_reason(:missing_artifact_sha256),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "missing_artifact_sha256",
        "model artifact digest is missing"
      )

  def from_reason(:invalid_source_uri),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "invalid_source_uri",
        "model artifact source URI is invalid"
      )

  def from_reason({:unsupported_source_scheme, _scheme}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "unsupported_source_scheme",
        "model artifact source scheme is unsupported"
      )

  def from_reason(:path_escape),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "path_escape",
        "model identifier or version contains an invalid path segment"
      )

  # --- MODEL_INVALID: artifact verification ---
  def from_reason(:artifact_hash_mismatch),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "artifact_hash_mismatch",
        "model artifact verification failed"
      )

  def from_reason({:cache_verification_failed, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "cache_verification_failed",
        "cached model artifact verification failed"
      )

  def from_reason({:verification_failed, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "verification_failed",
        "model artifact verification failed"
      )

  def from_reason({:invalid_source_layout, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "invalid_source_layout",
        "model artifact layout is invalid"
      )

  def from_reason({:archive_extract_failed, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "archive_extract_failed",
        "model artifact archive could not be extracted"
      )

  def from_reason({:source_not_directory, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "source_not_directory",
        "model artifact source has an invalid layout"
      )

  def from_reason({:unsupported_archive_extension, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID,
        "unsupported_archive_extension",
        "model artifact archive format is unsupported"
      )

  # --- ACQUISITION_FAILED ---
  def from_reason(:missing_artifact_source_uri),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "missing_artifact_source_uri",
        "model artifact source URI is not configured"
      )

  def from_reason({:source_not_found, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "source_not_found",
        "model artifact source was not found"
      )

  def from_reason({:source_unauthorized, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "source_unauthorized",
        "node is not authorized to access model artifacts"
      )

  def from_reason({:source_unavailable, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "source_unavailable",
        "model artifact source is unavailable"
      )

  def from_reason({:download_failed, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "download_failed",
        "model artifact download failed"
      )

  def from_reason({:download_incomplete, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED,
        "download_incomplete",
        "model artifact download was incomplete"
      )

  # --- RUNTIME_UNAVAILABLE ---
  def from_reason(:worker_executable_not_found),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
        "worker_executable_not_found",
        "model runtime executable is not available on this node"
      )

  def from_reason(:worker_unavailable),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
        "worker_unavailable",
        "model runtime is unavailable on this node"
      )

  def from_reason({:worker_exited, _status}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
        "worker_exited",
        "model runtime exited unexpectedly"
      )

  def from_reason({:rpc_error, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
        "rpc_error",
        "model runtime RPC failed"
      )

  def from_reason({:worker_unhealthy, code, _message}) when is_binary(code) do
    sanitized_code = sanitize_code(code, "worker_unhealthy")

    message =
      Map.get(
        @worker_runtime_unavailable_messages,
        sanitized_code,
        "model runtime is unhealthy on this node"
      )

    new(:MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE, sanitized_code, message)
  end

  # --- RUNTIME_UNAVAILABLE / MODEL_INVALID / INTERNAL via worker load failure ---
  def from_reason({:worker_load_failed, code, _detail}) when is_binary(code) do
    sanitized_code = sanitize_code(code, "worker_load_failed")
    classify_worker_load_code(sanitized_code)
  end

  # Legacy 2-tuple from pre-Task-4.2 adapter (defensive)
  def from_reason({:worker_load_failed, message}) when is_binary(message),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "worker_load_failed",
        "model runtime failed to load the model"
      )

  # --- TIMEOUT ---
  def from_reason(:deadline_exceeded),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
        "deadline_exceeded",
        "model load exceeded its deadline"
      )

  def from_reason(:worker_ready_timeout),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
        "worker_ready_timeout",
        "model runtime did not become ready in time"
      )

  # --- RESOURCE_EXHAUSTED ---
  def from_reason(:model_capacity_exhausted),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED,
        "model_capacity_exhausted",
        "node runtime is at loaded-model capacity"
      )

  # --- INTERNAL: manager-level ---
  def from_reason(:task_crashed),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "task_crashed",
        "model load task crashed unexpectedly"
      )

  def from_reason(:load_cancelled),
    do: new(:MODEL_LOAD_FAILURE_CATEGORY_INTERNAL, "load_cancelled", "model load was cancelled")

  def from_reason(:conflicting_request),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "conflicting_request",
        "another load request for this model is already in progress"
      )

  # --- INTERNAL: staging/filesystem ---
  def from_reason({:staging_failed, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "staging_failed",
        "node failed to prepare model staging storage"
      )

  def from_reason({:finalize_failed, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "finalize_failed",
        "node failed to finalize the model artifact"
      )

  def from_reason({:filesystem_error, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "filesystem_error",
        "node encountered a local filesystem error"
      )

  def from_reason({:invalid_source_config, _msg}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "invalid_source_config",
        "node model source configuration is invalid"
      )

  def from_reason(:invalid_model_path),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "invalid_model_path",
        "node could not access the prepared model path"
      )

  def from_reason({:socket_cleanup_failed, _reason}),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "socket_cleanup_failed",
        "node failed to prepare the worker runtime socket"
      )

  def from_reason(:runtime_adapter_not_implemented),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "runtime_adapter_not_implemented",
        "model runtime is not configured on this node"
      )

  # --- Catch-all ---
  def from_reason(_reason),
    do:
      new(
        :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL,
        "internal_error",
        "model load failed due to an internal error"
      )

  @doc """
  Converts a raw error reason into a failed `EnsureModelLoadedResponse`.

  Convenience wrapper that calls `from_reason/1` and builds the proto response.
  """
  @spec to_response(term()) :: EnsureModelLoadedResponse.t()
  def to_response(reason) do
    %__MODULE__{category: category, code: code, message: message} = from_reason(reason)

    %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: category,
      failure_code: code,
      failure_message: message
    }
  end

  # --- Private helpers ---

  defp new(category, code, message) do
    %__MODULE__{category: category, code: code, message: message}
  end

  defp classify_worker_load_code(code) do
    cond do
      MapSet.member?(@worker_model_invalid_codes, code) ->
        message = Map.fetch!(@worker_model_invalid_messages, code)
        new(:MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID, code, message)

      MapSet.member?(@worker_runtime_unavailable_codes, code) ->
        message = Map.fetch!(@worker_runtime_unavailable_messages, code)
        new(:MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE, code, message)

      true ->
        new(:MODEL_LOAD_FAILURE_CATEGORY_INTERNAL, code, "model runtime failed to load the model")
    end
  end

  # Validates that a code string matches the expected snake_case format.
  # Returns the sanitized code or a fallback if the code is invalid/empty.
  defp sanitize_code(code, fallback) do
    trimmed = String.trim(code)

    if trimmed != "" and Regex.match?(~r/^[a-z0-9_]+$/, trimmed) do
      trimmed
    else
      fallback
    end
  end
end
