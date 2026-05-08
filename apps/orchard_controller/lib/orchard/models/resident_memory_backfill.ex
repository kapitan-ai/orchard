defmodule Orchard.Models.ResidentMemoryBackfill do
  @moduledoc """
  Backfills `resident_memory_bytes` for existing MLX artifact bundles.

  This is an observe-only metadata repair: it rewrites `manifest.json` and the
  catalog hash together, but does not change placement, readiness, admission, or
  scheduler policy.

  Bundles whose manifests do not satisfy `Orchard.Models.ManifestParser` are
  intentionally failed before rewrite so schema-invalid artifacts can be repaired
  explicitly instead of being partially metadata-backfilled.
  """

  import Ecto.Query

  require Logger

  alias Orchard.ArtifactBundle
  alias Orchard.FS
  alias Orchard.ModelManifest
  alias Orchard.Models
  alias Orchard.Models.ManifestParser
  alias Orchard.Models.MemoryEstimator
  alias Orchard.Models.Model
  alias Orchard.Repo

  defstruct processed: 0,
            updated: 0,
            would_update: 0,
            skipped: 0,
            skipped_already_present: 0,
            skipped_drift: 0,
            skipped_concurrent: 0,
            skipped_unknown: 0,
            failed: 0,
            dry_run: true

  @type t :: %__MODULE__{
          processed: non_neg_integer(),
          updated: non_neg_integer(),
          would_update: non_neg_integer(),
          skipped: non_neg_integer(),
          skipped_already_present: non_neg_integer(),
          skipped_drift: non_neg_integer(),
          skipped_concurrent: non_neg_integer(),
          skipped_unknown: non_neg_integer(),
          failed: non_neg_integer(),
          dry_run: boolean()
        }

  @type run_result :: {:ok, t()} | {:error, t()}
  @type log_fun :: (String.t() -> term())

  @doc """
  Runs the resident-memory backfill.

  Dry-run mode is the default. Pass `apply: true` to rewrite manifests and
  update catalog rows. The `:log` option accepts a one-arity logging function.
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    env = run_env(opts)
    summary = %__MODULE__{dry_run: not env.apply?}

    Models.list_models()
    |> Enum.reduce_while({:ok, summary}, fn model, {:ok, acc} ->
      process_model(model, acc, env)
    end)
  end

  defp process_model(%Model{} = model, summary, env) do
    summary = count(summary, :processed)

    case backfill_model(model, summary, env) do
      {:ok, updated_summary} -> {:cont, {:ok, updated_summary}}
      {:error, updated_summary} -> {:halt, {:error, updated_summary}}
    end
  end

  defp backfill_model(%Model{resident_memory_bytes: value} = model, summary, env)
       when is_integer(value) and value > 0 do
    env.log.("Skipping #{model_label(model)}: resident_memory_bytes already present")
    {:ok, count(summary, :skipped_already_present)}
  end

  defp backfill_model(%Model{} = model, summary, env) do
    with {:ok, bundle_path} <- resolve_bundle_path(model),
         :ok <- ensure_bundle_dir(bundle_path),
         {:ok, pre_repair_sha} <- current_tree_sha(bundle_path),
         :ok <- ensure_hash_aligned(model, pre_repair_sha),
         {:ok, resident_memory_bytes} <- estimate_resident_memory(bundle_path) do
      maybe_apply_backfill(
        model,
        bundle_path,
        pre_repair_sha,
        resident_memory_bytes,
        summary,
        env
      )
    else
      {:skip, field, message} ->
        env.log.("Skipping #{model_label(model)}: #{message}")
        {:ok, count(summary, field)}

      {:fail, message} ->
        env.log.("Failed #{model_label(model)}: #{message}")
        {:ok, count(summary, :failed)}
    end
  end

  defp maybe_apply_backfill(
         model,
         bundle_path,
         pre_repair_sha,
         resident_memory_bytes,
         summary,
         env
       ) do
    if env.apply? do
      apply_backfill(model, bundle_path, pre_repair_sha, resident_memory_bytes, summary, env)
    else
      env.log.(
        "Would update #{model_label(model)} resident_memory_bytes=#{resident_memory_bytes}"
      )

      {:ok, count(summary, :would_update)}
    end
  end

  defp apply_backfill(model, bundle_path, pre_repair_sha, resident_memory_bytes, summary, env) do
    manifest_path = Path.join(bundle_path, "manifest.json")

    case read_manifest_map(manifest_path) do
      {:ok, original_json, manifest_map} ->
        case validate_original_manifest(original_json) do
          :ok ->
            apply_manifest_rewrite(
              %{
                model: model,
                bundle_path: bundle_path,
                manifest_path: manifest_path,
                pre_repair_sha: pre_repair_sha,
                original_json: original_json,
                manifest_map: manifest_map,
                resident_memory_bytes: resident_memory_bytes
              },
              summary,
              env
            )

          {:error, reason} ->
            env.log.("Failed #{model_label(model)}: #{inspect(reason)}")
            {:ok, count(summary, :failed)}
        end

      {:error, reason} ->
        env.log.("Failed #{model_label(model)}: #{inspect(reason)}")
        {:ok, count(summary, :failed)}
    end
  end

  defp apply_manifest_rewrite(write, summary, env) do
    updated_json = encode_manifest(write.manifest_map, write.resident_memory_bytes)

    case write_manifest(env, write.manifest_path, updated_json) do
      :ok ->
        verify_rewrite_and_update_catalog(write, summary, env)

      {:error, reason} ->
        env.log.("Failed #{model_label(write.model)}: #{inspect(reason)}")
        {:ok, count(summary, :failed)}
    end
  end

  defp verify_rewrite_and_update_catalog(write, summary, env) do
    case reparse_rewritten_manifest(write.bundle_path, write.resident_memory_bytes) do
      :ok ->
        update_catalog_with_current_tree_hash(write, summary, env)

      {:manifest_reparse_failed, reason} ->
        rollback_invalid_rewrite(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          reason,
          summary,
          env
        )
    end
  end

  defp update_catalog_with_current_tree_hash(write, summary, env) do
    case current_tree_sha(write.bundle_path) do
      {:ok, new_sha} ->
        update_catalog_after_write(Map.put(write, :new_sha, new_sha), summary, env)

      {:fail, _message} = error_result ->
        rollback_or_fail(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          error_result,
          summary,
          env
        )
    end
  end

  defp validate_original_manifest(original_json) do
    case ManifestParser.parse_json(original_json) do
      {:ok, %ModelManifest{}} -> :ok
      {:error, reason} -> {:error, {:manifest_validation, reason}}
    end
  end

  defp reparse_rewritten_manifest(bundle_path, expected_resident_memory_bytes) do
    case ManifestParser.parse_from_bundle(bundle_path) do
      {:ok, %ModelManifest{resident_memory_bytes: ^expected_resident_memory_bytes}} ->
        :ok

      {:ok, %ModelManifest{resident_memory_bytes: resident_memory_bytes}} ->
        {:manifest_reparse_failed,
         {:resident_memory_mismatch,
          expected: expected_resident_memory_bytes, actual: resident_memory_bytes}}

      {:error, reason} ->
        {:manifest_reparse_failed, reason}
    end
  end

  defp rollback_invalid_rewrite(
         model,
         bundle_path,
         manifest_path,
         original_json,
         pre_repair_sha,
         reason,
         summary,
         env
       ) do
    env.log.(
      "Rolling back #{model_label(model)} after manifest reparse failure: #{inspect(reason)}"
    )

    with :ok <- write_manifest(env, manifest_path, original_json),
         {:ok, ^pre_repair_sha} <- current_tree_sha(bundle_path) do
      env.log.("Failed #{model_label(model)}: rewritten manifest failed parser validation")
      {:ok, count(summary, :failed)}
    else
      rollback_reason ->
        env.log.("Critical #{model_label(model)}: rollback failed #{inspect(rollback_reason)}")
        {:error, count(summary, :failed)}
    end
  end

  defp rollback_or_fail(
         model,
         bundle_path,
         manifest_path,
         original_json,
         pre_repair_sha,
         error_result,
         summary,
         env
       ) do
    env.log.(
      "Rolling back #{model_label(model)} after post-write failure: #{format_failure(error_result)}"
    )

    rollback_manifest(
      model,
      bundle_path,
      manifest_path,
      original_json,
      pre_repair_sha,
      summary,
      env
    )
  end

  defp format_failure({:fail, message}), do: message

  defp update_catalog_after_write(write, summary, env) do
    update_result =
      try do
        env.update_catalog.(
          write.model,
          write.resident_memory_bytes,
          write.pre_repair_sha,
          write.new_sha
        )
      rescue
        error -> {:exception, error}
      catch
        kind, reason -> {:catch, kind, reason}
      end

    case update_result do
      1 ->
        env.log.(
          "Updated #{model_label(write.model)} resident_memory_bytes=#{write.resident_memory_bytes}"
        )

        {:ok, count(summary, :updated)}

      0 ->
        handle_concurrent_update(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          write.new_sha,
          summary,
          env
        )

      other when is_integer(other) ->
        env.log.(
          "Unexpected update_catalog result for #{model_label(write.model)}: #{inspect(other)}; rolling back manifest"
        )

        rollback_manifest(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          summary,
          env
        )

      {:exception, error} ->
        env.log.(
          "update_catalog raised for #{model_label(write.model)}: #{Exception.message(error)}; rolling back manifest"
        )

        rollback_manifest(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          summary,
          env
        )

      {:catch, kind, reason} ->
        env.log.(
          "update_catalog exited for #{model_label(write.model)}: #{kind} #{inspect(reason)}; rolling back manifest"
        )

        rollback_manifest(
          write.model,
          write.bundle_path,
          write.manifest_path,
          write.original_json,
          write.pre_repair_sha,
          summary,
          env
        )
    end
  end

  defp handle_concurrent_update(
         model,
         bundle_path,
         manifest_path,
         original_json,
         pre_repair_sha,
         new_sha,
         summary,
         env
       ) do
    case Repo.get(Model, model.id) do
      %Model{resident_memory_bytes: value, artifact_sha256: sha}
      when is_integer(value) and value > 0 and sha == new_sha ->
        # Someone else backfilled to the exact same content. Disk already matches.
        env.log.(
          "Skipping #{model_label(model)}: resident memory was backfilled concurrently (matching hash)"
        )

        {:ok, count(summary, :skipped_already_present)}

      %Model{resident_memory_bytes: value, artifact_sha256: sha}
      when is_integer(value) and value > 0 and sha == pre_repair_sha ->
        # DB claims backfilled but still shows old hash — safe to rollback to DB state.
        env.log.(
          "Rolling back #{model_label(model)}: DB backfill state inconsistent (db_sha=#{sha}, pre_repair_sha=#{pre_repair_sha})"
        )

        rollback_manifest(
          model,
          bundle_path,
          manifest_path,
          original_json,
          pre_repair_sha,
          summary,
          env
        )

      %Model{resident_memory_bytes: value, artifact_sha256: sha}
      when is_integer(value) and value > 0 ->
        # DB has a third hash that matches neither pre_repair_sha nor new_sha.
        # Rolling back to pre_repair_sha would create a mismatch. Hard-fail.
        env.log.(
          "Critical #{model_label(model)}: DB hash=#{sha} does not match pre_repair=#{pre_repair_sha} nor new=#{new_sha}; manual repair required"
        )

        {:error, count(summary, :failed)}

      %Model{resident_memory_bytes: 0, artifact_sha256: sha} when sha == pre_repair_sha ->
        # Pure race: DB still shows original hash. Safe to rollback.
        rollback_manifest(
          model,
          bundle_path,
          manifest_path,
          original_json,
          pre_repair_sha,
          summary,
          env
        )

      %Model{resident_memory_bytes: 0, artifact_sha256: sha} ->
        # DB shows zero resident_memory_bytes but a non-original hash.
        # Rolling back to pre_repair_sha would create a mismatch. Hard-fail.
        env.log.(
          "Critical #{model_label(model)}: DB hash=#{sha} does not match pre_repair=#{pre_repair_sha} while resident_memory_bytes=0; manual repair required"
        )

        {:error, count(summary, :failed)}

      nil ->
        # Model was deleted concurrently after manifest rewrite.
        env.log.(
          "Critical #{model_label(model)}: model deleted concurrently after manifest rewrite; manual repair required"
        )

        {:error, count(summary, :failed)}
    end
  end

  defp rollback_manifest(
         model,
         bundle_path,
         manifest_path,
         original_json,
         pre_repair_sha,
         summary,
         env
       ) do
    with :ok <- write_manifest(env, manifest_path, original_json),
         {:ok, ^pre_repair_sha} <- current_tree_sha(bundle_path) do
      env.log.("Skipping #{model_label(model)}: catalog update raced; manifest rolled back")
      {:ok, count(summary, :skipped_concurrent)}
    else
      reason ->
        env.log.("Critical #{model_label(model)}: rollback failed #{inspect(reason)}")
        {:error, count(summary, :failed)}
    end
  end

  defp resolve_bundle_path(model) do
    case Models.artifact_local_path(model) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:fail, "artifact path rejected #{inspect(reason)}"}
    end
  end

  defp ensure_bundle_dir(bundle_path) do
    if File.dir?(bundle_path) do
      :ok
    else
      {:fail, "artifact path does not exist or is not a directory: #{bundle_path}"}
    end
  end

  defp current_tree_sha(bundle_path) do
    case ArtifactBundle.tree_sha256(bundle_path) do
      {:ok, sha} -> {:ok, sha}
      {:error, reason} -> {:fail, "artifact hash failed #{inspect(reason)}"}
    end
  end

  defp ensure_hash_aligned(%Model{artifact_sha256: artifact_sha256}, artifact_sha256), do: :ok

  defp ensure_hash_aligned(%Model{artifact_sha256: artifact_sha256}, actual_sha) do
    {:skip, :skipped_drift, "artifact hash drift db=#{artifact_sha256} disk=#{actual_sha}"}
  end

  defp estimate_resident_memory(bundle_path) do
    case MemoryEstimator.resident_memory_bytes_from_bundle(bundle_path) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:skip, :skipped_unknown, "resident_memory_bytes estimator returned :unknown"}
    end
  end

  defp read_manifest_map(manifest_path) do
    with {:ok, json} <- File.read(manifest_path),
         {:ok, manifest_map} when is_map(manifest_map) <- Jason.decode(json) do
      {:ok, json, manifest_map}
    else
      {:ok, _other} -> {:error, {:manifest_json, "manifest must decode to a JSON object"}}
      {:error, reason} -> {:error, {:manifest_read, reason}}
    end
  end

  defp encode_manifest(manifest_map, resident_memory_bytes) do
    manifest_map
    |> Map.put("resident_memory_bytes", resident_memory_bytes)
    |> Jason.encode!()
  end

  defp write_manifest(env, manifest_path, content) do
    case env.write_manifest.(manifest_path, content) do
      :ok -> :ok
      other -> {:error, {:manifest_write, other}}
    end
  rescue
    error -> {:error, {:manifest_write, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:manifest_write, {kind, reason}}}
  end

  defp default_update_catalog(model, resident_memory_bytes, pre_repair_sha, new_sha) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _rows} =
      Model
      |> where(
        [m],
        m.id == ^model.id and m.resident_memory_bytes == 0 and
          m.artifact_sha256 == ^pre_repair_sha
      )
      |> Repo.update_all(
        set: [
          resident_memory_bytes: resident_memory_bytes,
          artifact_sha256: new_sha,
          updated_at: now
        ]
      )

    count
  end

  defp count(summary, :processed), do: %{summary | processed: summary.processed + 1}
  defp count(summary, :updated), do: %{summary | updated: summary.updated + 1}
  defp count(summary, :would_update), do: %{summary | would_update: summary.would_update + 1}
  defp count(summary, :failed), do: %{summary | failed: summary.failed + 1}

  defp count(summary, field) do
    summary
    |> Map.update!(field, &(&1 + 1))
    |> Map.update!(:skipped, &(&1 + 1))
  end

  defp run_env(opts) do
    %{
      apply?: Keyword.get(opts, :apply, false),
      log: Keyword.get(opts, :log, &Logger.info/1),
      update_catalog: Keyword.get(opts, :update_catalog, &default_update_catalog/4),
      write_manifest: Keyword.get(opts, :write_manifest, &FS.atomic_write!/2)
    }
  end

  defp model_label(%Model{model_id: model_id, version: version}) do
    "#{model_id}@#{version}"
  end
end
