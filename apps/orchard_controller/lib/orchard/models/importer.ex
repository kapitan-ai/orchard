defmodule Orchard.Models.Importer do
  @moduledoc """
  Imports a local model bundle into the Orchard catalog.

  Import steps per SPEC.md §6.5:

  1. Validate source path exists and is a directory
  2. Parse and validate manifest.json
  3. Validate identity fields are safe path segments
  4. Check for duplicate (model_id + version)
  5. Copy bundle to a staging temp directory (rejecting symlinks)
  6. Compute SHA-256 digest of staged contents
  7. Move staged directory to artifacts_root/<model_id>/<version>/
  8. Insert catalog record with state `:registered`
  9. Optionally activate (set state to `:active`)
  10. Clean up staged directory on any failure

  The same import service is used by both CLI and any future API endpoint,
  keeping import logic in one place.
  """

  alias Orchard.ModelManifest
  alias Orchard.Models
  alias Orchard.Models.ManifestParser

  @type import_opts :: [activate: boolean(), artifacts_root: String.t()]

  @doc """
  Returns the configured artifacts root from inference config.

  Convenience so callers (e.g. CLI) don't couple to `Orchard.Inference` directly.
  """
  @spec default_artifacts_root() :: String.t()
  def default_artifacts_root do
    Orchard.Inference.artifacts_root()
  end

  # Identity fields must be safe path segments: alphanumeric, hyphen, underscore,
  # dot, and forward-slash (for org/model namespacing). No leading dots, no ..
  @identity_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9._\-\/]*\z/

  @doc """
  Imports a model bundle from `source_path` into the artifact store and catalog.

  ## Options

    * `:artifacts_root` — required, the root directory for stored artifacts
    * `:activate` — if `true`, the model is inserted as `:active` instead of `:registered`

  Returns `{:ok, model}` on success or `{:error, reason}` on failure.
  """
  @spec import_bundle(String.t(), import_opts()) ::
          {:ok, struct()} | {:error, term()}
  def import_bundle(source_path, opts \\ []) do
    artifacts_root = Keyword.fetch!(opts, :artifacts_root)
    activate? = Keyword.get(opts, :activate, false)

    with :ok <- validate_source_path(source_path),
         {:ok, manifest} <- ManifestParser.parse_from_bundle(source_path),
         :ok <- validate_identity_safe(manifest),
         :ok <- check_no_duplicate(manifest),
         {:ok, staged_path} <- stage_bundle(source_path, artifacts_root),
         {:ok, sha256} <- compute_sha256(staged_path),
         {:ok, dest_path} <- finalize_staged(staged_path, manifest, artifacts_root) do
      case insert_catalog_record(manifest, dest_path, sha256, activate?) do
        {:ok, model} ->
          {:ok, model}

        {:error, _} = err ->
          File.rm_rf(dest_path)
          err
      end
    end
  end

  # -- Validation -----------------------------------------------------------

  defp validate_source_path(path) do
    cond do
      not File.exists?(path) ->
        {:error, {:source_not_found, path}}

      not File.dir?(path) ->
        {:error, {:source_not_directory, "expected a directory, got: #{path}"}}

      true ->
        :ok
    end
  end

  defp validate_identity_safe(%ModelManifest{model_id: model_id, version: version}) do
    with :ok <- validate_path_segment(model_id, "model_id") do
      validate_path_segment(version, "version")
    end
  end

  defp validate_path_segment(value, field) do
    cond do
      String.contains?(value, "..") ->
        {:error, {:validation, "#{field} contains path traversal sequence: #{inspect(value)}"}}

      not Regex.match?(@identity_pattern, value) ->
        {:error, {:validation, "#{field} contains unsafe characters: #{inspect(value)}"}}

      true ->
        :ok
    end
  end

  defp check_no_duplicate(%ModelManifest{model_id: model_id, version: version}) do
    case Models.get_model_by_identity(model_id, version) do
      nil -> :ok
      _existing -> {:error, {:duplicate, "model #{model_id}@#{version} already exists"}}
    end
  end

  # -- Staging & copy -------------------------------------------------------

  defp stage_bundle(source_path, artifacts_root) do
    staging_dir = Path.join(artifacts_root, ".staging-#{System.unique_integer([:positive])}")

    case File.mkdir_p(staging_dir) do
      :ok ->
        case safe_copy_directory(source_path, staging_dir, source_path) do
          :ok ->
            {:ok, staging_dir}

          {:error, _} = err ->
            File.rm_rf(staging_dir)
            err
        end

      {:error, reason} ->
        {:error, {:mkdir_failed, "failed to create staging dir: #{inspect(reason)}"}}
    end
  end

  defp safe_copy_directory(source, dest, bundle_root) do
    with {:ok, entries} <- list_dir(source) do
      copy_entries(entries, source, dest, bundle_root)
    end
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:copy_failed, "failed to list #{dir}: #{inspect(reason)}"}}
    end
  end

  defp copy_entries([], _source, _dest, _bundle_root), do: :ok

  defp copy_entries([entry | rest], source, dest, bundle_root) do
    case safe_copy_entry(Path.join(source, entry), Path.join(dest, entry), bundle_root) do
      :ok -> copy_entries(rest, source, dest, bundle_root)
      {:error, _} = err -> err
    end
  end

  defp safe_copy_entry(src, dst, bundle_root) do
    case File.lstat(src) do
      {:ok, stat} -> copy_by_type(stat.type, src, dst, bundle_root)
      {:error, reason} -> {:error, {:copy_failed, "stat #{src}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(:symlink, src, _dst, _bundle_root) do
    {:error, {:symlink_rejected, "symlinks not allowed in bundle: #{src}"}}
  end

  defp copy_by_type(:directory, src, dst, bundle_root) do
    case File.mkdir_p(dst) do
      :ok -> safe_copy_directory(src, dst, bundle_root)
      {:error, reason} -> {:error, {:copy_failed, "mkdir #{dst}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(:regular, src, dst, _bundle_root) do
    case File.cp(src, dst) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy_failed, "copy #{src}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(type, src, _dst, _bundle_root) do
    {:error, {:copy_failed, "unsupported file type #{type} at #{src}"}}
  end

  # -- SHA-256 computation --------------------------------------------------

  defp compute_sha256(dir_path) do
    case collect_file_paths(dir_path) do
      {:ok, paths} ->
        sorted = Enum.sort(paths)
        hash = hash_files(sorted, :crypto.hash_init(:sha256))
        {:ok, Base.encode16(hash, case: :lower)}

      {:error, _} = err ->
        err
    end
  end

  defp collect_file_paths(dir) do
    case File.ls(dir) do
      {:ok, entries} -> collect_entries(entries, dir, [])
      {:error, reason} -> {:error, {:hash_failed, "failed to list #{dir}: #{inspect(reason)}"}}
    end
  end

  defp collect_entries([], _dir, acc), do: {:ok, acc}

  defp collect_entries([entry | rest], dir, acc) do
    full = Path.join(dir, entry)

    case classify_and_collect(full) do
      {:ok, paths} -> collect_entries(rest, dir, acc ++ paths)
      {:error, _} = err -> err
    end
  end

  defp classify_and_collect(path) do
    if File.dir?(path), do: collect_file_paths(path), else: {:ok, [path]}
  end

  defp hash_files([], state), do: :crypto.hash_final(state)

  defp hash_files([path | rest], state) do
    # Hash relative path + file contents for deterministic ordering
    content = File.read!(path)
    state = :crypto.hash_update(state, path)
    state = :crypto.hash_update(state, content)
    hash_files(rest, state)
  end

  # -- Finalize staging → destination --------------------------------------

  defp finalize_staged(staged_path, %ModelManifest{model_id: model_id, version: version}, artifacts_root) do
    dest_path = Path.join([artifacts_root, model_id, version])

    with :ok <- validate_dest_contained(dest_path, artifacts_root, staged_path),
         :ok <- validate_dest_fresh(dest_path, staged_path) do
      move_staged_to_dest(staged_path, dest_path)
    end
  end

  defp validate_dest_contained(dest_path, artifacts_root, staged_path) do
    expanded_dest = Path.expand(dest_path)
    expanded_root = Path.expand(artifacts_root)

    if String.starts_with?(expanded_dest, expanded_root <> "/") do
      :ok
    else
      File.rm_rf(staged_path)
      {:error, {:path_escape, "destination escapes artifacts_root"}}
    end
  end

  defp validate_dest_fresh(dest_path, staged_path) do
    if File.exists?(dest_path) do
      File.rm_rf(staged_path)
      {:error, {:destination_exists, "artifact path already exists: #{dest_path}"}}
    else
      :ok
    end
  end

  defp move_staged_to_dest(staged_path, dest_path) do
    with :ok <- mkdir_parent(dest_path, staged_path) do
      case File.rename(staged_path, dest_path) do
        :ok -> {:ok, dest_path}
        {:error, reason} -> cleanup_and_error(staged_path, :move_failed, reason)
      end
    end
  end

  defp mkdir_parent(dest_path, staged_path) do
    case File.mkdir_p(Path.dirname(dest_path)) do
      :ok -> :ok
      {:error, reason} -> cleanup_and_error(staged_path, :mkdir_failed, reason)
    end
  end

  defp cleanup_and_error(staged_path, tag, reason) do
    File.rm_rf(staged_path)
    {:error, {tag, "#{tag}: #{inspect(reason)}"}}
  end

  # -- Catalog record -------------------------------------------------------

  defp insert_catalog_record(manifest, dest_path, computed_sha256, activate?) do
    state = if activate?, do: :active, else: :registered
    artifact_uri = "file://#{dest_path}"

    attrs = %{
      model_id: manifest.model_id,
      version: manifest.version,
      state: state,
      format: manifest.format,
      capabilities: manifest.capabilities,
      tokenizer: tokenizer_to_map(manifest.tokenizer),
      artifact_uri: artifact_uri,
      artifact_sha256: computed_sha256,
      artifact_size_bytes: manifest.size_bytes || 0,
      resident_memory_bytes: manifest.resident_memory_bytes || 0,
      kv_cache_bytes_per_token: manifest.kv_cache_bytes_per_token || 0,
      prefill_workspace_bytes_per_token: manifest.prefill_workspace_bytes_per_token || 0,
      max_context_tokens: manifest.max_context_tokens,
      default_parameters: %{},
      runtime_requirements: runtime_requirements_to_map(manifest.runtime_requirements)
    }

    Models.create_model(attrs)
  end

  defp tokenizer_to_map(%ModelManifest.Tokenizer{kind: kind, path: path}) do
    %{"kind" => kind, "path" => path}
  end

  defp runtime_requirements_to_map(%ModelManifest.RuntimeRequirements{
         adapter: adapter,
         min_agent_capability: capability
       }) do
    %{"adapter" => adapter, "min_agent_capability" => capability}
  end
end
