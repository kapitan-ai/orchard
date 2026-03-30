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

  @type outcome :: :cache_hit | :materialized

  @doc """
  Ensure a model bundle is cached at `request.final_path` and verified.

  Returns `{:ok, final_path, outcome}` or `{:error, reason}`.
  """
  @spec ensure_cached(Request.t()) :: {:ok, String.t(), outcome()} | {:error, term()}
  def ensure_cached(%Request{} = request) do
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
    result = do_ensure_cached(request)
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

  defp do_ensure_cached(%Request{} = request) do
    case check_existing_cache(request) do
      {:ok, _path, _outcome} = hit ->
        hit

      :reacquire ->
        acquire_and_verify(request)

      {:error, _} = err ->
        err
    end
  end

  defp check_existing_cache(%Request{} = request) do
    cond do
      File.dir?(request.final_path) ->
        verify_existing_cache(request)

      request.artifact_source_uri == nil ->
        {:error, :missing_artifact_source_uri}

      true ->
        :reacquire
    end
  end

  defp verify_existing_cache(%Request{} = request) do
    case ArtifactBundle.tree_sha256(request.final_path) do
      {:ok, hash} when hash == request.artifact_sha256 ->
        Logger.info(
          "Cache hit for #{request.model_id}@#{request.version} at #{request.final_path}"
        )

        {:ok, request.final_path, :cache_hit}

      {:ok, _mismatched_hash} ->
        handle_stale_cache(request, :artifact_hash_mismatch)

      {:error, reason} ->
        Logger.warning(
          "Failed to verify cache for #{request.model_id}@#{request.version}: #{inspect(reason)}"
        )

        handle_stale_cache(request, {:cache_verification_failed, reason})
    end
  end

  defp handle_stale_cache(%Request{artifact_source_uri: nil}, error), do: {:error, error}

  defp handle_stale_cache(%Request{} = request, _error) do
    Logger.warning(
      "Cache stale or unreadable for #{request.model_id}@#{request.version}, reacquiring"
    )

    File.rm_rf(request.final_path)
    :reacquire
  end

  defp acquire_and_verify(%Request{} = request) do
    with :ok <- prepare_staging(request),
         :ok <- materialize_source(request),
         :ok <- verify_staging(request),
         :ok <- finalize_staging(request) do
      Logger.info("Materialized #{request.model_id}@#{request.version} at #{request.final_path}")

      {:ok, request.final_path, :materialized}
    else
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
    case ArtifactBundle.tree_sha256(request.staging_path) do
      {:ok, hash} when hash == request.artifact_sha256 ->
        :ok

      {:ok, _mismatched_hash} ->
        {:error, :artifact_hash_mismatch}

      {:error, reason} ->
        {:error, {:verification_failed, reason}}
    end
  end

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
