defmodule Orchard.Node.ModelAcquisition do
  @moduledoc """
  Orchestrates model artifact acquisition: cache check → staging → verify → finalize.

  Runs inside a supervised task spawned by `ModelManager`. This module is
  stateless — all mutable coordination lives in `ModelManager`.
  """

  require Logger

  alias Orchard.ArtifactBundle
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.Source
  alias Orchard.Node.ModelAcquisition.VerificationReceipt

  @type outcome :: :cache_hit | :materialized

  @doc """
  Ensure a model bundle is cached at `request.final_path` and verified.

  Returns `{:ok, final_path, outcome}` or `{:error, reason}`.
  """
  @spec ensure_cached(Request.t(), keyword()) ::
          {:ok, String.t(), outcome()} | {:error, term()}
  def ensure_cached(%Request{} = request, opts \\ []) do
    :telemetry.execute(
      [:orchard, :node, :model_acquisition, :start],
      %{system_time: System.system_time()},
      %{
        model_id: request.model_id,
        version: request.version,
        source_scheme: request.source_scheme
      }
    )

    start_time = System.monotonic_time(:millisecond)
    result = do_ensure_cached(request, opts)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, _path, outcome} ->
        :telemetry.execute(
          [:orchard, :node, :model_acquisition, :stop],
          %{duration_ms: duration_ms},
          %{model_id: request.model_id, version: request.version, outcome: outcome}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:orchard, :node, :model_acquisition, :exception],
          %{duration_ms: duration_ms},
          %{model_id: request.model_id, version: request.version, reason: reason}
        )
    end

    result
  end

  defp do_ensure_cached(%Request{} = request, opts) do
    case check_existing_cache(request, opts) do
      {:ok, _path, _outcome} = hit ->
        hit

      :reacquire ->
        acquire_and_verify(request, opts)

      {:error, _} = err ->
        err
    end
  end

  defp check_existing_cache(%Request{} = request, opts) do
    cond do
      File.dir?(request.final_path) ->
        verify_existing_cache(request, opts)

      request.artifact_source_uri == nil ->
        {:error, :missing_artifact_source_uri}

      true ->
        :reacquire
    end
  end

  defp verify_existing_cache(%Request{} = request, opts) do
    if Keyword.get(opts, :force_full?, false) do
      verify_existing_cache_after_invalidation(request, :operator_forced, opts)
    else
      case VerificationReceipt.check(request) do
        :match ->
          log_verification(request, :info, :fast, :receipt_matched)
          {:ok, request.final_path, :cache_hit}

        {:miss, reason} ->
          maybe_log_invalidation(request, reason)
          verify_existing_cache_after_invalidation(request, reason, opts)
      end
    end
  end

  defp verify_existing_cache_after_invalidation(request, reason, opts) do
    case VerificationReceipt.invalidate(request) do
      :ok ->
        verify_existing_cache_fully(request, reason, opts)

      {:error, :receipt_invalidation_failed} = error ->
        log_verification(request, :warning, :failed, :receipt_invalidation_failed)
        error
    end
  end

  defp verify_existing_cache_fully(request, reason, opts) do
    log_verification(request, :info, :full, reason)

    case authoritative_verify(request.final_path, request.artifact_sha256) do
      {:ok, evidence} ->
        case persist_receipt(request, evidence, :verified, opts) do
          :ok ->
            {:ok, request.final_path, :cache_hit}

          {:error, reason} ->
            fail_closed_after_receipt_rejection(request, reason)
        end

      {:error, :artifact_hash_mismatch} ->
        log_verification(request, :warning, :failed, :artifact_hash_mismatch)
        handle_stale_cache(request, :artifact_hash_mismatch)

      {:error, reason} ->
        log_verification(request, :warning, :failed, :verification_error)
        handle_stale_cache(request, {:cache_verification_failed, reason})
    end
  end

  defp handle_stale_cache(%Request{artifact_source_uri: nil}, error), do: {:error, error}

  defp handle_stale_cache(%Request{} = request, _error) do
    Logger.warning("Model cache stale or unreadable; reacquiring #{model_ref(request)}")

    File.rm_rf(request.final_path)
    :reacquire
  end

  defp acquire_and_verify(%Request{} = request, opts) do
    with :ok <- VerificationReceipt.invalidate(request),
         :ok <- prepare_staging(request),
         :ok <- materialize_source(request),
         {:ok, evidence} <- verify_staging(request),
         :ok <- finalize_staging(request),
         :ok <- persist_receipt(request, evidence, :promoted, opts) do
      Logger.info("Materialized #{model_ref(request)}")

      {:ok, request.final_path, :materialized}
    else
      {:error, {:verification_receipt_rejected, _reason}} = error ->
        _ = VerificationReceipt.invalidate(request)
        File.rm_rf(request.final_path)
        cleanup_staging(request)
        error

      {:error, _} = err ->
        # Always clean up staging on failure
        cleanup_staging(request)
        err
    end
  end

  defp prepare_staging(%Request{} = request) do
    # Remove any stale staging directory from a prior failed attempt
    File.rm_rf(request.staging_path)

    case File.mkdir_p(request.staging_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:staging_failed, "mkdir staging: #{inspect(reason)}"}}
    end
  end

  defp materialize_source(%Request{} = request) do
    case select_adapter(request.source_scheme) do
      {:ok, adapter} -> adapter.materialize(request)
      {:error, _} = err -> err
    end
  end

  defp select_adapter("file"), do: {:ok, Source.File}
  defp select_adapter("hf"), do: {:ok, Source.HuggingFace}
  defp select_adapter("s3"), do: {:ok, Source.S3}
  defp select_adapter(nil), do: {:error, :missing_artifact_source_uri}
  defp select_adapter(scheme), do: {:error, {:unsupported_source_scheme, scheme}}

  defp verify_staging(%Request{} = request) do
    log_verification(request, :info, :full, :first_acquisition)

    case authoritative_verify(request.staging_path, request.artifact_sha256) do
      {:ok, evidence} ->
        {:ok, evidence}

      {:error, :artifact_hash_mismatch} ->
        log_verification(request, :warning, :failed, :artifact_hash_mismatch)
        {:error, :artifact_hash_mismatch}

      {:error, reason} ->
        log_verification(request, :warning, :failed, :verification_error)
        {:error, {:verification_failed, reason}}
    end
  end

  defp authoritative_verify(path, expected_hash) do
    with {:ok, before_evidence, verification_boundary} <-
           VerificationReceipt.prepare_for_verification(path),
         {:ok, ^expected_hash} <- ArtifactBundle.tree_sha256(path),
         {:ok, after_evidence} <- VerificationReceipt.inventory_evidence(path),
         true <- before_evidence.fingerprint == after_evidence.fingerprint do
      {:ok, Map.put(after_evidence, :verified_at, verification_boundary)}
    else
      {:ok, _mismatched_hash} -> {:error, :artifact_hash_mismatch}
      false -> {:error, :artifact_changed_during_verification}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_receipt(request, evidence, mode, opts) do
    persistor = Keyword.get(opts, :receipt_persistor, &persist_receipt_data/3)
    result = persistor.(request, evidence, mode)

    case result do
      :ok ->
        :ok

      {:error, :receipt_write_failed} ->
        log_receipt_failure(request, :receipt_write_failed)
        :ok

      {:error, reason} ->
        bounded_reason = bounded_receipt_reason(reason)
        log_receipt_failure(request, bounded_reason)
        log_verification(request, :warning, :failed, bounded_reason)
        {:error, {:verification_receipt_rejected, bounded_reason}}
    end
  end

  defp persist_receipt_data(request, evidence, mode) do
    case mode do
      :verified -> VerificationReceipt.record_verified(request, evidence)
      :promoted -> VerificationReceipt.record(request, evidence)
    end
  end

  defp log_receipt_failure(request, reason) do
    Logger.warning(
      "Unable to persist model cache verification receipt for #{model_ref(request)} " <>
        "reason=#{reason}"
    )
  end

  defp bounded_receipt_reason(reason)
       when reason in [
              :inventory_changed_after_verification,
              :inventory_changed_after_normalization,
              :inventory_unreadable,
              :receipt_invalidation_failed,
              :receipt_write_failed
            ],
       do: reason

  defp bounded_receipt_reason(_reason), do: :receipt_persistence_failed

  defp fail_closed_after_receipt_rejection(request, reason) do
    with :ok <- VerificationReceipt.invalidate(request) do
      handle_stale_cache(request, reason)
    end
  end

  defp maybe_log_invalidation(_request, :receipt_missing), do: :ok

  defp maybe_log_invalidation(request, reason) do
    log_verification(request, :warning, :invalidated, reason)
  end

  defp log_verification(request, level, path, reason) do
    Logger.log(
      level,
      "Model cache verification #{model_ref(request)} verification_path=#{path} reason=#{reason}"
    )
  end

  defp model_ref(request), do: "#{request.model_id}@#{request.version}"

  defp finalize_staging(%Request{} = request) do
    # Ensure parent directory exists for the final path
    case File.mkdir_p(Path.dirname(request.final_path)) do
      :ok ->
        case File.rename(request.staging_path, request.final_path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:finalize_failed, "rename: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        {:error, {:finalize_failed, "mkdir parent: #{inspect(reason)}"}}
    end
  end

  # Remove the staging directory and prune empty parent dirs up to .staging root.
  defp cleanup_staging(%Request{} = request) do
    File.rm_rf(request.staging_path)
    staging_root = Path.join(request.models_root, ".staging")
    prune_empty_parents(Path.dirname(request.staging_path), staging_root)
  end

  defp prune_empty_parents(dir, stop) when dir == stop, do: :ok

  defp prune_empty_parents(dir, stop) do
    case File.ls(dir) do
      {:ok, []} ->
        File.rmdir(dir)
        prune_empty_parents(Path.dirname(dir), stop)

      _ ->
        :ok
    end
  end
end
