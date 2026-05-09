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

  alias Orchard.ArtifactBundle
  alias Orchard.ModelManifest
  alias Orchard.Models
  alias Orchard.Models.ManifestParser
  alias Orchard.Models.MemoryEstimator
  alias Orchard.Models.SafeTokenizationPreflight

  require Logger

  @bundle_preflight_error_event [:orchard, :tokenizer, :bundle_preflight, :error]

  @type import_opts :: [activate: boolean(), artifacts_root: String.t()]

  @doc """
  Returns the configured artifacts root from inference config.

  Convenience so callers (e.g. CLI) don't couple to `Orchard.Inference` directly.
  """
  @spec default_artifacts_root() :: String.t()
  def default_artifacts_root do
    Orchard.Inference.artifacts_root()
  end

  @doc """
  Returns the canonical controller-side artifact directory path for a model.

  This is a pure path computation — no filesystem access or validation.
  The layout is `artifacts_root/model_id/version`.
  """
  @spec artifact_destination_path(String.t(), String.t(), String.t()) :: String.t()
  def artifact_destination_path(artifacts_root, model_id, version) do
    Path.join([artifacts_root, model_id, version])
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
         {:ok, source_manifest} <- ManifestParser.parse_from_bundle(source_path),
         :ok <- validate_identity_safe(source_manifest),
         :ok <- check_no_duplicate(source_manifest),
         {:ok, staged_path} <- stage_bundle(source_path, artifacts_root),
         {:ok, manifest} <- maybe_top_up_resident_memory(staged_path, source_manifest),
         {:ok, manifest} <- maybe_run_eager_preflight(staged_path, manifest),
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
        case ArtifactBundle.copy_directory(source_path, staging_dir) do
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

  # -- Manifest top-up ------------------------------------------------------

  defp maybe_top_up_resident_memory(staged_path, %ModelManifest{} = manifest) do
    if resident_memory_present?(manifest.resident_memory_bytes) do
      {:ok, manifest}
    else
      maybe_write_estimated_resident_memory(staged_path, manifest)
    end
  end

  defp resident_memory_present?(value) when is_integer(value) and value > 0, do: true
  defp resident_memory_present?(_value), do: false

  defp maybe_write_estimated_resident_memory(staged_path, manifest) do
    case MemoryEstimator.resident_memory_bytes_from_bundle(staged_path) do
      {:ok, resident_memory_bytes}
      when is_integer(resident_memory_bytes) and resident_memory_bytes > 0 ->
        write_resident_memory_or_original(staged_path, manifest, resident_memory_bytes)

      :unknown ->
        maybe_write_unknown_resident_memory(staged_path, manifest)
    end
  end

  defp maybe_write_unknown_resident_memory(staged_path, manifest) do
    # Estimator returned :unknown. Normalize missing/nil resident_memory_bytes
    # to 0 on disk so the DB row (which uses manifest.resident_memory_bytes || 0)
    # stays aligned with the persisted manifest file.
    if is_nil(manifest.resident_memory_bytes) do
      write_resident_memory_or_original(staged_path, manifest, 0)
    else
      {:ok, manifest}
    end
  end

  defp write_resident_memory_or_original(staged_path, manifest, resident_memory_bytes) do
    with {:ok, manifest_map} <- read_manifest_map(staged_path),
         :ok <-
           write_manifest_map(
             staged_path,
             Map.put(manifest_map, "resident_memory_bytes", resident_memory_bytes)
           ),
         {:ok, reparsed} <- ManifestParser.parse_from_bundle(staged_path) do
      {:ok, reparsed}
    else
      _error ->
        # Fail-open: if manifest read/write/re-parse fails, use original manifest.
        # This also prevents staged-directory cleanup leaks: the function never
        # returns an error, so the outer with/else in import_bundle/2 does not
        # need to handle top-up failures separately.
        {:ok, manifest}
    end
  end

  defp read_manifest_map(staged_path) do
    manifest_path = Path.join(staged_path, "manifest.json")

    case File.read(manifest_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, manifest_map} when is_map(manifest_map) ->
            {:ok, manifest_map}

          {:ok, _other} ->
            {:error, {:manifest_json, "manifest must decode to a JSON object"}}

          {:error, %Jason.DecodeError{} = err} ->
            {:error, {:manifest_json, Exception.message(err)}}
        end

      {:error, reason} ->
        {:error, {:manifest_read, "failed to read #{manifest_path}: #{inspect(reason)}"}}
    end
  end

  defp write_manifest_map(staged_path, manifest_map) do
    manifest_path = Path.join(staged_path, "manifest.json")

    case File.write(manifest_path, Jason.encode!(manifest_map)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:manifest_write, "failed to write #{manifest_path}: #{inspect(reason)}"}}
    end
  end

  # -- Eager Safe Tokenization Preflight ------------------------------------

  defp maybe_run_eager_preflight(staged_path, %ModelManifest{} = manifest) do
    cond do
      importer_preflight_skip?(manifest) ->
        {:ok, manifest}

      not eager_preflight_enabled?() ->
        maybe_strip_untrusted_positive_verdict(staged_path, manifest)

      true ->
        run_import_preflight(staged_path, manifest)
    end
  end

  defp eager_preflight_enabled? do
    Application.get_env(:orchard_controller, :bundle_build_eager_preflight_enabled, true)
  end

  defp trust_manifest_compatibility_declarations? do
    Application.get_env(:orchard_controller, :trust_manifest_compatibility_declarations, true)
  end

  defp importer_preflight_skip?(%ModelManifest{safe_tokenization: nil}), do: true

  # Positive manifest declarations are trusted only after import identity validation;
  # operators can disable that compatibility shortcut to force helper revalidation.
  defp importer_preflight_skip?(%ModelManifest{safe_tokenization: safe}) do
    safe.compatible == false or safe.template_compatible == false or
      (safe.preflight_compatible_declared? == true and
         trust_manifest_compatibility_declarations?())
  end

  defp run_import_preflight(staged_path, manifest) do
    case import_preflight_input(staged_path, manifest) do
      {:ok, input} ->
        run_import_preflight_with_manifest_snapshot(staged_path, manifest, input)

      :skip ->
        maybe_strip_untrusted_positive_verdict(staged_path, manifest)
    end
  end

  defp import_preflight_input(
         staged_path,
         %ModelManifest{
           tokenizer: tokenizer,
           chat_template: chat_template,
           safe_tokenization: safe
         }
       ) do
    with {:ok, tokenizer_kind} <- non_empty_asset(tokenizer.kind),
         {:ok, tokenizer_path} <- resolve_required_bundle_file(staged_path, tokenizer.path),
         {:ok, tokenizer_config_path} <-
           resolve_tokenizer_config_file(staged_path, tokenizer.path, tokenizer.config_path),
         {:ok, chat_template_path} <-
           resolve_required_bundle_file(staged_path, chat_template && chat_template.path) do
      {:ok,
       %{
         bundle_dir: staged_path,
         tokenizer_kind: tokenizer_kind,
         tokenizer_path: tokenizer_path,
         tokenizer_config_path: tokenizer_config_path,
         chat_template_path: chat_template_path,
         control_tokens: safe.control_tokens,
         catalog_sha256: safe.catalog_sha256
       }}
    end
  end

  defp non_empty_asset(value) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_asset(_value), do: :skip

  defp resolve_required_bundle_file(staged_path, relative_path) do
    case resolve_optional_bundle_file(staged_path, relative_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> :skip
    end
  end

  # An explicit manifest config_path is an authorial asset claim. If that exact
  # file cannot be resolved, skip preflight rather than silently validating a
  # different sibling tokenizer_config.json.
  defp resolve_tokenizer_config_file(staged_path, _tokenizer_path, config_path)
       when is_binary(config_path) and config_path != "" do
    require_optional_bundle_file(staged_path, config_path)
  end

  defp resolve_tokenizer_config_file(staged_path, tokenizer_path, _config_path) do
    case resolve_sibling_tokenizer_config_file(staged_path, tokenizer_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> :skip
    end
  end

  defp require_optional_bundle_file(staged_path, relative_path) do
    case resolve_optional_bundle_file(staged_path, relative_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> :skip
    end
  end

  defp resolve_sibling_tokenizer_config_file(staged_path, tokenizer_path)
       when is_binary(tokenizer_path) and tokenizer_path != "" do
    tokenizer_path
    |> Path.dirname()
    |> Path.join("tokenizer_config.json")
    |> then(&resolve_optional_bundle_file(staged_path, &1))
  end

  defp resolve_sibling_tokenizer_config_file(_staged_path, _tokenizer_path), do: nil

  defp resolve_optional_bundle_file(_staged_path, nil), do: nil

  defp resolve_optional_bundle_file(staged_path, relative_path)
       when is_binary(relative_path) and relative_path != "" do
    path = Path.expand(relative_path, staged_path)
    expanded_root = Path.expand(staged_path)

    if String.starts_with?(path, expanded_root <> "/") and File.regular?(path) do
      path
    end
  end

  defp resolve_optional_bundle_file(_staged_path, _relative_path), do: nil

  defp run_import_preflight_with_manifest_snapshot(staged_path, manifest, input) do
    case read_manifest_map(staged_path) do
      {:ok, manifest_map} ->
        input
        |> SafeTokenizationPreflight.run()
        |> handle_import_preflight_result(staged_path, manifest, manifest_map)

      {:error, reason} ->
        Logger.warning(
          "Importer safe-tokenization preflight manifest snapshot failed: #{inspect(reason)}"
        )

        if untrusted_positive_declaration?(manifest) do
          handle_untrusted_verdict_strip_failure(staged_path, :read_manifest, reason, nil)
        else
          {:ok, manifest}
        end
    end
  end

  defp handle_import_preflight_result(
         {:compatible, _} = result,
         staged_path,
         manifest,
         manifest_map
       ) do
    merge_import_preflight_result(staged_path, manifest, manifest_map, result)
  end

  defp handle_import_preflight_result(
         {:incompatible, _} = result,
         staged_path,
         manifest,
         manifest_map
       ) do
    merge_import_preflight_result(staged_path, manifest, manifest_map, result)
  end

  defp handle_import_preflight_result({:error, reason}, staged_path, manifest, manifest_map) do
    Logger.warning("Importer safe-tokenization preflight failed: #{inspect(reason)}")
    maybe_strip_or_restore_untrusted_positive_verdict(staged_path, manifest, manifest_map)
  end

  defp handle_import_preflight_result(_result, staged_path, manifest, manifest_map) do
    maybe_strip_or_restore_untrusted_positive_verdict(staged_path, manifest, manifest_map)
  end

  defp maybe_strip_untrusted_positive_verdict(staged_path, manifest) do
    if untrusted_positive_declaration?(manifest) do
      case read_manifest_map(staged_path) do
        {:ok, manifest_map} ->
          strip_untrusted_positive_verdict(staged_path, manifest, manifest_map)

        {:error, reason} ->
          handle_untrusted_verdict_strip_failure(staged_path, :read_manifest, reason, nil)
      end
    else
      {:ok, manifest}
    end
  end

  defp maybe_strip_or_restore_untrusted_positive_verdict(staged_path, manifest, manifest_map) do
    if untrusted_positive_declaration?(manifest) do
      strip_untrusted_positive_verdict(staged_path, manifest, manifest_map)
    else
      restore_manifest_if_changed(staged_path, manifest, manifest_map)
    end
  end

  defp untrusted_positive_declaration?(%ModelManifest{safe_tokenization: safe}) do
    authored_positive_verdict_field?(safe) and not trust_manifest_compatibility_declarations?()
  end

  defp authored_positive_verdict_field?(%{compatible_declared?: true, compatible: true}), do: true

  defp authored_positive_verdict_field?(%{
         compatible_declared?: false,
         template_compatible_declared?: true,
         template_compatible: true
       }),
       do: true

  defp authored_positive_verdict_field?(_safe), do: false

  defp strip_untrusted_positive_verdict(staged_path, _manifest, manifest_map) do
    stripped_manifest = strip_preflight_verdict_fields(manifest_map)

    case ManifestParser.parse_json(Jason.encode!(stripped_manifest)) do
      {:ok, _validated} ->
        write_and_reparse_stripped_manifest(staged_path, stripped_manifest, manifest_map)

      {:error, reason} ->
        handle_untrusted_verdict_strip_failure(
          staged_path,
          :validate_manifest,
          reason,
          manifest_map
        )
    end
  end

  defp strip_preflight_verdict_fields(%{"safe_tokenization" => safe_map} = manifest_map)
       when is_map(safe_map) do
    stripped_safe =
      safe_map
      |> Map.delete("compatible")
      |> Map.delete("template_compatible")
      |> Map.delete("incompatibility_reason")

    Map.put(manifest_map, "safe_tokenization", stripped_safe)
  end

  defp strip_preflight_verdict_fields(manifest_map), do: manifest_map

  defp write_and_reparse_stripped_manifest(staged_path, stripped_manifest, rollback_manifest) do
    with :ok <- write_manifest_map(staged_path, stripped_manifest),
         {:ok, reparsed} <- ManifestParser.parse_from_bundle(staged_path) do
      {:ok, reparsed}
    else
      reason ->
        handle_untrusted_verdict_strip_failure(
          staged_path,
          :write_or_reparse,
          reason,
          rollback_manifest
        )
    end
  end

  defp handle_untrusted_verdict_strip_failure(staged_path, stage, reason, rollback_manifest) do
    Logger.warning(
      "Importer safe-tokenization untrusted verdict strip failed: #{inspect(reason)}"
    )

    if is_map(rollback_manifest) do
      write_manifest_map(staged_path, rollback_manifest)
    end

    File.rm_rf(staged_path)
    {:error, {:safe_tokenization_untrusted_verdict_strip_failed, {stage, reason}}}
  end

  defp restore_manifest_if_changed(staged_path, manifest, manifest_map) do
    case read_manifest_map(staged_path) do
      {:ok, ^manifest_map} ->
        {:ok, manifest}

      _changed_or_unreadable ->
        case write_manifest_map(staged_path, manifest_map) do
          :ok ->
            {:ok, manifest}

          {:error, reason} ->
            File.rm_rf(staged_path)
            {:error, {:safe_tokenization_preflight_rollback_failed, reason}}
        end
    end
  end

  defp merge_import_preflight_result(staged_path, manifest, manifest_map, result) do
    case Map.get(manifest_map, "safe_tokenization") do
      safe_map when is_map(safe_map) ->
        updated_safe =
          SafeTokenizationPreflight.merge_into_safe_tokenization_map(safe_map, result)

        updated_manifest = Map.put(manifest_map, "safe_tokenization", updated_safe)

        case ManifestParser.parse_json(Jason.encode!(updated_manifest)) do
          {:ok, _validated} ->
            write_and_reparse_preflight_manifest(
              staged_path,
              manifest,
              manifest_map,
              updated_manifest
            )

          {:error, _reason} = reason ->
            handle_preflight_merge_rollback(
              staged_path,
              manifest,
              :validate_manifest,
              reason,
              manifest_map,
              updated_manifest
            )
        end

      other ->
        handle_preflight_merge_rollback(
          staged_path,
          manifest,
          :safe_tokenization_shape,
          {:invalid_safe_tokenization, value_kind(other)},
          manifest_map,
          nil
        )
    end
  end

  defp write_and_reparse_preflight_manifest(
         staged_path,
         manifest,
         original_manifest,
         updated_manifest
       ) do
    with :ok <- write_manifest_map(staged_path, updated_manifest),
         {:ok, reparsed} <- ManifestParser.parse_from_bundle(staged_path) do
      {:ok, reparsed}
    else
      reason ->
        handle_preflight_merge_rollback(
          staged_path,
          manifest,
          :write_or_reparse,
          reason,
          original_manifest,
          updated_manifest
        )
    end
  end

  defp handle_preflight_merge_rollback(
         staged_path,
         manifest,
         stage,
         reason,
         rollback_manifest,
         attempted_manifest
       ) do
    emit_preflight_merge_error(staged_path, manifest, stage, reason, attempted_manifest)

    Logger.warning(
      "Importer safe-tokenization preflight manifest merge failed: #{inspect(reason)}"
    )

    if untrusted_positive_declaration?(manifest) do
      strip_untrusted_positive_verdict(staged_path, manifest, rollback_manifest)
    else
      case write_manifest_map(staged_path, rollback_manifest) do
        :ok ->
          {:ok, manifest}

        {:error, rollback_reason} ->
          File.rm_rf(staged_path)
          {:error, {:safe_tokenization_preflight_rollback_failed, rollback_reason}}
      end
    end
  end

  defp emit_preflight_merge_error(staged_path, manifest, stage, reason, attempted_manifest) do
    measurements = maybe_put_manifest_json_bytes(%{duration_ms: 0, count: 1}, attempted_manifest)

    metadata = %{
      bundle_dir: staged_path,
      tokenizer_kind: manifest_tokenizer_kind(manifest),
      reason: :merge_validation_failed,
      stage: stage,
      details: normalize_merge_failure(reason)
    }

    :telemetry.execute(@bundle_preflight_error_event, measurements, metadata)
  end

  defp maybe_put_manifest_json_bytes(measurements, attempted_manifest)
       when is_map(attempted_manifest) do
    Map.put(measurements, :manifest_json_bytes, byte_size(Jason.encode!(attempted_manifest)))
  end

  defp maybe_put_manifest_json_bytes(measurements, _attempted_manifest), do: measurements

  defp normalize_merge_failure({:error, {kind, detail}}) when is_atom(kind) do
    %{kind: kind, detail: inspect(detail)}
  end

  defp normalize_merge_failure({:invalid_safe_tokenization, kind}) do
    %{kind: :invalid_safe_tokenization, detail: kind}
  end

  defp normalize_merge_failure(other), do: %{kind: :unknown, detail: inspect(other)}

  defp manifest_tokenizer_kind(%ModelManifest{tokenizer: %{kind: kind}}), do: kind
  defp manifest_tokenizer_kind(_manifest), do: nil

  defp value_kind(nil), do: nil
  defp value_kind(value) when is_binary(value), do: :binary
  defp value_kind(value) when is_boolean(value), do: :boolean
  defp value_kind(value) when is_integer(value), do: :integer
  defp value_kind(value) when is_float(value), do: :float
  defp value_kind(value) when is_list(value), do: :list
  defp value_kind(value) when is_map(value), do: :map
  defp value_kind(_value), do: :other

  # -- SHA-256 computation --------------------------------------------------

  defp compute_sha256(dir_path) do
    ArtifactBundle.tree_sha256(dir_path)
  end

  # -- Finalize staging → destination --------------------------------------

  defp finalize_staged(
         staged_path,
         %ModelManifest{model_id: model_id, version: version},
         artifacts_root
       ) do
    dest_path = artifact_destination_path(artifacts_root, model_id, version)

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
      artifact_source_uri: artifact_uri,
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
