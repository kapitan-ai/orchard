defmodule Orchard.Models.BundleBuilder do
  @moduledoc """
  Generates a valid Orchard bundle manifest from downloaded HuggingFace model files.

  Reads `config.json`, resolves chat templates, and writes `manifest.json` that
  passes `ManifestParser.parse_from_bundle/1` validation. Bridges the gap between
  `HubDownloader` output and `Importer.import_bundle/2` input.

  ## Chat Template Resolution Order

  1. Existing `chat_template.jinja` in download directory
  2. Existing `chat_template.jinja2` in download directory
  3. Extracted from `tokenizer_config.json` `chat_template` field (string or list)
  4. Omitted with warning (bundle valid but tokenizer port-mode will fail)
  """

  require Logger

  alias Orchard.Models.ManifestParser
  alias Orchard.Models.MemoryEstimator

  @template_candidates ["chat_template.jinja", "chat_template.jinja2"]
  @generated_template_name "chat_template.jinja"

  @spec prepare_bundle(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, {atom(), String.t()}}
  def prepare_bundle(download_dir, repo_id, detail_metadata)

  def prepare_bundle(download_dir, _repo_id, _detail_metadata)
      when not is_binary(download_dir) do
    {:error, {:invalid_download_dir, "Download directory must be a string."}}
  end

  def prepare_bundle(_download_dir, repo_id, _detail_metadata)
      when not is_binary(repo_id) do
    {:error, {:invalid_repo_id, "Model repository id must be a string."}}
  end

  def prepare_bundle(_download_dir, _repo_id, detail_metadata)
      when not is_map(detail_metadata) do
    {:error, {:invalid_detail_metadata, "Detail metadata must be a map."}}
  end

  def prepare_bundle(download_dir, repo_id, detail_metadata) do
    with :ok <- validate_directory(download_dir),
         {:ok, repo_id} <- validate_repo_id(repo_id),
         {:ok, version} <- extract_version(detail_metadata),
         {:ok, config} <- read_model_config(download_dir),
         {:ok, max_context_tokens} <- extract_context_tokens(config),
         :ok <- validate_tokenizer(download_dir),
         {:ok, template_asset} <- resolve_chat_template(download_dir),
         {:ok, size_bytes} <- compute_bundle_size(download_dir),
         kv_cache_bytes_per_token = estimate_kv_cache_bytes_per_token(config),
         manifest =
           build_manifest(
             repo_id,
             version,
             max_context_tokens,
             size_bytes,
             kv_cache_bytes_per_token,
             template_asset
           ),
         :ok <- write_and_validate_manifest(download_dir, manifest) do
      {:ok, download_dir}
    end
  end

  # -- Input Validation ------------------------------------------------------

  defp validate_directory(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, {:invalid_download_dir, "Download directory does not exist: #{path}"}}
    end
  end

  defp validate_repo_id(repo_id) do
    trimmed = String.trim(repo_id)

    if trimmed != "" do
      {:ok, trimmed}
    else
      {:error, {:invalid_repo_id, "Model repository id must not be blank."}}
    end
  end

  defp extract_version(detail_metadata) do
    case detail_metadata do
      %{revision_sha: sha} when is_binary(sha) ->
        trimmed = String.trim(sha)

        if trimmed != "" do
          {:ok, trimmed}
        else
          {:error,
           {:invalid_detail_metadata,
            "Detail metadata must include a non-empty :revision_sha for model versioning."}}
        end

      _ ->
        {:error,
         {:invalid_detail_metadata,
          "Detail metadata must include a non-empty :revision_sha for model versioning."}}
    end
  end

  # -- Config Parsing --------------------------------------------------------

  defp read_model_config(download_dir) do
    config_path = Path.join(download_dir, "config.json")

    case read_json_file(config_path, :missing_config, :config_read) do
      {:ok, json} -> decode_json_object(json, :invalid_config_json)
      {:error, _} = error -> error
    end
  end

  @context_window_keys ["max_position_embeddings", "n_positions", "max_sequence_length"]

  defp extract_context_tokens(config) do
    text_config = Map.get(config, "text_config", %{})

    case find_context_window(config, @context_window_keys) do
      {:ok, n} -> {:ok, n}
      {:error, _} = error -> error
      :not_found -> find_context_window_or_nil(text_config, @context_window_keys)
    end
  end

  # Returns {:ok, n}, {:error, ...} if key present but invalid, or :not_found if no key exists.
  defp find_context_window(config, keys) do
    Enum.reduce_while(keys, :not_found, fn key, acc ->
      case Map.fetch(config, key) do
        :error ->
          {:cont, acc}

        {:ok, n} when is_integer(n) and n > 0 ->
          {:halt, {:ok, n}}

        {:ok, s} when is_binary(s) ->
          case parse_positive_integer(s) do
            nil ->
              {:halt,
               {:error,
                {:invalid_config,
                 "config.json contains #{key} but value is not a positive integer: #{inspect(s)}"}}}

            n ->
              {:halt, {:ok, n}}
          end

        {:ok, bad} ->
          {:halt,
           {:error,
            {:invalid_config,
             "config.json contains #{key} but value is not a positive integer: #{inspect(bad)}"}}}
      end
    end)
  end

  defp find_context_window_or_nil(config, keys) do
    case find_context_window(config, keys) do
      {:ok, n} -> {:ok, n}
      {:error, _} = error -> error
      :not_found -> {:ok, nil}
    end
  end

  defp parse_positive_integer(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp estimate_kv_cache_bytes_per_token(config) do
    case MemoryEstimator.kv_cache_bytes_per_token(config) do
      {:ok, value} -> value
      :unknown -> 0
    end
  end

  # -- Tokenizer Validation --------------------------------------------------

  defp validate_tokenizer(download_dir) do
    path = Path.join(download_dir, "tokenizer.json")

    if File.regular?(path) do
      :ok
    else
      {:error, {:missing_tokenizer, "tokenizer.json is required for generated HF bundles."}}
    end
  end

  # -- Chat Template Resolution ----------------------------------------------

  defp resolve_chat_template(download_dir) do
    case find_existing_template(download_dir) do
      {:ok, _} = result ->
        result

      :none ->
        extract_template_from_tokenizer_config(download_dir)
    end
  end

  defp find_existing_template(download_dir) do
    Enum.find_value(@template_candidates, :none, fn filename ->
      path = Path.join(download_dir, filename)

      if File.regular?(path) do
        existing_template_result(path, filename)
      end
    end)
  end

  defp existing_template_result(path, filename) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 ->
        sha256 = compute_sha256(content)
        {:ok, %{path: filename, sha256: sha256}}

      {:ok, _empty} ->
        nil

      {:error, reason} ->
        {:error, {:chat_template_read, "Failed to read #{path}: #{inspect(reason)}"}}
    end
  end

  defp extract_template_from_tokenizer_config(download_dir) do
    config_path = Path.join(download_dir, "tokenizer_config.json")

    if File.regular?(config_path) do
      with {:ok, json} <-
             read_json_file(config_path, :invalid_tokenizer_config, :invalid_tokenizer_config),
           {:ok, config} <- decode_json_object(json, :invalid_tokenizer_config) do
        template_from_tokenizer_config(download_dir, Map.get(config, "chat_template"))
      end
    else
      warn_no_template()
      {:ok, nil}
    end
  end

  defp template_from_tokenizer_config(_download_dir, nil) do
    warn_no_template()
    {:ok, nil}
  end

  defp template_from_tokenizer_config(download_dir, template)
       when is_binary(template) and template != "" do
    write_generated_template(download_dir, template)
  end

  defp template_from_tokenizer_config(_download_dir, template) when is_binary(template) do
    {:error, {:invalid_tokenizer_config, "chat_template in tokenizer_config.json is blank."}}
  end

  defp template_from_tokenizer_config(download_dir, templates) when is_list(templates) do
    extract_template_from_list(download_dir, templates)
  end

  defp template_from_tokenizer_config(_download_dir, _other) do
    {:error,
     {:invalid_tokenizer_config, "chat_template in tokenizer_config.json has unsupported type."}}
  end

  defp extract_template_from_list(download_dir, templates) do
    selected =
      Enum.find(templates, fn
        %{"name" => "default"} -> true
        _ -> false
      end) || List.first(templates)

    case selected do
      %{"template" => template} when is_binary(template) and template != "" ->
        write_generated_template(download_dir, template)

      %{"template" => ""} ->
        {:error, {:invalid_tokenizer_config, "chat_template list entry has blank template."}}

      %{} ->
        {:error,
         {:invalid_tokenizer_config,
          "chat_template list entry missing or invalid template field."}}

      nil ->
        warn_no_template()
        {:ok, nil}

      _other ->
        {:error, {:invalid_tokenizer_config, "chat_template list contains non-object entries."}}
    end
  end

  defp write_generated_template(download_dir, content) do
    path = Path.join(download_dir, @generated_template_name)

    case File.write(path, content) do
      :ok ->
        sha256 = compute_sha256(content)
        {:ok, %{path: @generated_template_name, sha256: sha256}}

      {:error, reason} ->
        {:error, {:chat_template_write, "Failed to write #{path}: #{inspect(reason)}"}}
    end
  end

  defp warn_no_template do
    Logger.warning(
      "BundleBuilder: no chat template found. Bundle will import but tokenizer port-mode will fail."
    )
  end

  # -- Bundle Size Calculation -----------------------------------------------

  defp compute_bundle_size(download_dir) do
    case walk_size(download_dir, download_dir) do
      {:ok, size} -> {:ok, size}
      {:error, _} = err -> err
    end
  end

  defp walk_size(dir, root) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, acc} ->
          accumulate_entry_size(dir, root, entry, acc)
        end)

      {:error, reason} ->
        {:error, {:invalid_bundle_layout, "Failed to list directory #{dir}: #{inspect(reason)}"}}
    end
  end

  defp accumulate_entry_size(dir, root, entry, acc) do
    path = Path.join(dir, entry)
    relative = Path.relative_to(path, root)

    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} ->
        {:cont, {:ok, maybe_add_file_size(relative, size, acc)}}

      {:ok, %{type: :directory}} ->
        accumulate_directory_size(path, root, acc)

      {:ok, %{type: type}} ->
        {:halt,
         {:error,
          {:invalid_bundle_layout, "Unexpected file type #{inspect(type)} at #{relative}"}}}

      {:error, reason} ->
        {:halt,
         {:error, {:invalid_bundle_layout, "Failed to stat #{relative}: #{inspect(reason)}"}}}
    end
  end

  defp maybe_add_file_size("manifest.json", _size, acc), do: acc
  defp maybe_add_file_size(_relative, size, acc), do: acc + size

  defp accumulate_directory_size(path, root, acc) do
    case walk_size(path, root) do
      {:ok, sub_size} -> {:cont, {:ok, acc + sub_size}}
      {:error, _} = err -> {:halt, err}
    end
  end

  # -- Manifest Assembly -----------------------------------------------------

  defp build_manifest(
         repo_id,
         version,
         max_context_tokens,
         size_bytes,
         kv_cache_bytes_per_token,
         template_asset
       ) do
    base = %{
      "model_id" => repo_id,
      "version" => version,
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => ".",
      "sha256" => "pending",
      "size_bytes" => size_bytes,
      "resident_memory_bytes" => 0,
      "kv_cache_bytes_per_token" => kv_cache_bytes_per_token,
      "prefill_workspace_bytes_per_token" => 0,
      "max_context_tokens" => max_context_tokens,
      "capabilities" => ["chat"],
      "tokenizer" => %{
        "kind" => "huggingface_tokenizer_json",
        "path" => "tokenizer.json"
      },
      "runtime_requirements" => %{
        "adapter" => "mlx_lm",
        "min_agent_capability" => "mlx"
      }
    }

    case template_asset do
      %{path: path, sha256: sha256} ->
        Map.put(base, "chat_template", %{"path" => path, "sha256" => sha256})

      nil ->
        base
    end
  end

  # -- Manifest Write & Validation -------------------------------------------

  defp write_and_validate_manifest(download_dir, manifest) do
    manifest_path = Path.join(download_dir, "manifest.json")
    json = Jason.encode!(manifest, pretty: true)

    case File.write(manifest_path, json) do
      :ok ->
        case ManifestParser.parse_from_bundle(download_dir) do
          {:ok, _parsed} ->
            :ok

          {:error, reason} ->
            File.rm(manifest_path)

            {:error,
             {:invalid_generated_manifest,
              "Generated manifest failed validation: #{inspect(reason)}"}}
        end

      {:error, reason} ->
        {:error, {:manifest_write, "Failed to write #{manifest_path}: #{inspect(reason)}"}}
    end
  end

  # -- Shared Helpers --------------------------------------------------------

  defp read_json_file(path, missing_tag, read_error_tag) do
    case File.read(path) do
      {:ok, json} ->
        {:ok, json}

      {:error, :enoent} ->
        {:error, {missing_tag, "File not found: #{path}"}}

      {:error, reason} ->
        {:error, {read_error_tag, "Failed to read #{path}: #{inspect(reason)}"}}
    end
  end

  defp decode_json_object(json, error_tag) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, {error_tag, "Expected a JSON object."}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {error_tag, "Invalid JSON: #{Exception.message(err)}"}}
    end
  end

  defp compute_sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end
