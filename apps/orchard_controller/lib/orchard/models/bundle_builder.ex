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
         {:ok, max_context_tokens} <- read_context_window(download_dir),
         :ok <- validate_tokenizer(download_dir),
         {:ok, template_asset} <- resolve_chat_template(download_dir),
         {:ok, size_bytes} <- compute_bundle_size(download_dir),
         manifest =
           build_manifest(repo_id, version, max_context_tokens, size_bytes, template_asset),
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

  defp read_context_window(download_dir) do
    config_path = Path.join(download_dir, "config.json")

    with {:ok, json} <- read_json_file(config_path, :missing_config, :config_read),
         {:ok, config} <- decode_json_object(json, :invalid_config_json) do
      extract_context_tokens(config)
    end
  end

  defp extract_context_tokens(config) do
    value =
      find_positive_integer(config, [
        "max_position_embeddings",
        "n_positions",
        "max_sequence_length"
      ])

    case value do
      nil ->
        {:error,
         {:invalid_config,
          "config.json must contain a positive integer for max_position_embeddings, n_positions, or max_sequence_length."}}

      n ->
        {:ok, n}
    end
  end

  defp find_positive_integer(config, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(config, key) do
        n when is_integer(n) and n > 0 -> n
        s when is_binary(s) -> parse_positive_integer(s)
        _ -> nil
      end
    end)
  end

  defp parse_positive_integer(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> n
      _ -> nil
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
    end)
  end

  defp extract_template_from_tokenizer_config(download_dir) do
    config_path = Path.join(download_dir, "tokenizer_config.json")

    if File.regular?(config_path) do
      with {:ok, json} <-
             read_json_file(config_path, :invalid_tokenizer_config, :invalid_tokenizer_config),
           {:ok, config} <- decode_json_object(json, :invalid_tokenizer_config) do
        case Map.get(config, "chat_template") do
          nil ->
            warn_no_template()
            {:ok, nil}

          template when is_binary(template) and template != "" ->
            write_generated_template(download_dir, template)

          template when is_binary(template) ->
            {:error,
             {:invalid_tokenizer_config, "chat_template in tokenizer_config.json is blank."}}

          templates when is_list(templates) ->
            extract_template_from_list(download_dir, templates)

          _other ->
            {:error,
             {:invalid_tokenizer_config,
              "chat_template in tokenizer_config.json has unsupported type."}}
        end
      end
    else
      warn_no_template()
      {:ok, nil}
    end
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
          path = Path.join(dir, entry)
          relative = Path.relative_to(path, root)

          case File.lstat(path) do
            {:ok, %{type: :regular, size: size}} ->
              # Exclude manifest.json from size calculation
              if relative == "manifest.json" do
                {:cont, {:ok, acc}}
              else
                {:cont, {:ok, acc + size}}
              end

            {:ok, %{type: :directory}} ->
              case walk_size(path, root) do
                {:ok, sub_size} -> {:cont, {:ok, acc + sub_size}}
                {:error, _} = err -> {:halt, err}
              end

            {:ok, %{type: type}} ->
              {:halt,
               {:error,
                {:invalid_bundle_layout, "Unexpected file type #{inspect(type)} at #{relative}"}}}

            {:error, reason} ->
              {:halt,
               {:error,
                {:invalid_bundle_layout, "Failed to stat #{relative}: #{inspect(reason)}"}}}
          end
        end)

      {:error, reason} ->
        {:error, {:invalid_bundle_layout, "Failed to list directory #{dir}: #{inspect(reason)}"}}
    end
  end

  # -- Manifest Assembly -----------------------------------------------------

  defp build_manifest(repo_id, version, max_context_tokens, size_bytes, template_asset) do
    base = %{
      "model_id" => repo_id,
      "version" => version,
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => ".",
      "sha256" => "pending",
      "size_bytes" => size_bytes,
      "resident_memory_bytes" => 0,
      "kv_cache_bytes_per_token" => 0,
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
    # Ensure ModelManifest atoms exist in the atom table before the parser
    # tries String.to_existing_atom on manifest keys. Without this, lazy
    # module loading may not have loaded the struct atoms yet.
    Code.ensure_loaded!(Orchard.ModelManifest)

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
