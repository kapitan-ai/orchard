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
  alias Orchard.Models.SafeTokenizationPreflight
  alias Orchard.Tokenizer.{HelperOutputCollector, HelperRequestTransport}

  @template_candidates ["chat_template.jinja", "chat_template.jinja2"]
  @generated_template_name "chat_template.jinja"
  @tokenizer_config_name "tokenizer_config.json"
  @catalog_contract_version 3
  @default_catalog_timeout_ms 30_000
  @default_catalog_max_stdout_bytes 1_048_576
  @config_singleton_token_keys ~w(bos_token eos_token pad_token unk_token cls_token sep_token mask_token)

  @spec prepare_bundle(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, {atom(), term()}}
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
         {:ok, tokenizer_json} <- read_tokenizer_json(download_dir),
         {:ok, tokenizer_config_asset} <- read_tokenizer_config_if_present(download_dir),
         {:ok, template_asset} <- resolve_chat_template(download_dir),
         {:ok, safe_tokenization} <-
           build_safe_tokenization(
             download_dir,
             tokenizer_json,
             tokenizer_config_asset,
             template_asset
           ),
         safe_tokenization =
           maybe_run_eager_preflight(
             download_dir,
             tokenizer_config_asset,
             template_asset,
             safe_tokenization
           ),
         {:ok, size_bytes} <- compute_bundle_size(download_dir),
         resident_memory_bytes = estimate_resident_memory_bytes(download_dir),
         kv_cache_bytes_per_token = estimate_kv_cache_bytes_per_token(config),
         manifest =
           build_manifest(%{
             repo_id: repo_id,
             version: version,
             max_context_tokens: max_context_tokens,
             size_bytes: size_bytes,
             resident_memory_bytes: resident_memory_bytes,
             kv_cache_bytes_per_token: kv_cache_bytes_per_token,
             template_asset: template_asset,
             tokenizer_config_asset: tokenizer_config_asset,
             safe_tokenization: safe_tokenization
           }),
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
          {:halt, parse_context_window_string(key, s)}

        {:ok, bad} ->
          {:halt,
           {:error,
            {:invalid_config,
             "config.json contains #{key} but value is not a positive integer: #{inspect(bad)}"}}}
      end
    end)
  end

  defp parse_context_window_string(key, value) do
    case parse_positive_integer(value) do
      nil ->
        {:error,
         {:invalid_config,
          "config.json contains #{key} but value is not a positive integer: #{inspect(value)}"}}

      n ->
        {:ok, n}
    end
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

  defp estimate_resident_memory_bytes(download_dir) do
    case MemoryEstimator.resident_memory_bytes_from_bundle(download_dir) do
      {:ok, value} -> value
      :unknown -> 0
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

  defp read_tokenizer_json(download_dir) do
    path = Path.join(download_dir, "tokenizer.json")

    case read_json_file(path, :missing_tokenizer, :tokenizer_read) do
      {:ok, json} -> decode_json_object(json, :invalid_tokenizer_json)
      {:error, _} = error -> error
    end
  end

  defp read_tokenizer_config_if_present(download_dir) do
    path = Path.join(download_dir, @tokenizer_config_name)

    if File.regular?(path) do
      with {:ok, json} <-
             read_json_file(path, :invalid_tokenizer_config, :invalid_tokenizer_config),
           {:ok, config} <- decode_json_object(json, :invalid_tokenizer_config) do
        {:ok, %{path: @tokenizer_config_name, absolute_path: path, config: config}}
      end
    else
      {:ok, nil}
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
    config_path = Path.join(download_dir, @tokenizer_config_name)

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

  # -- Safe Tokenization Catalog ---------------------------------------------

  defp build_safe_tokenization(
         download_dir,
         tokenizer_json,
         tokenizer_config_asset,
         template_asset
       ) do
    with {:ok, helper_catalog} <-
           maybe_extract_native_catalog(download_dir, tokenizer_config_asset, template_asset) do
      added_tokens = extract_added_tokens(tokenizer_json)
      config_singletons = extract_config_singletons(tokenizer_config_asset)
      additional_special_tokens = extract_additional_special_tokens(tokenizer_config_asset)
      extras = source_catalog([])

      control_tokens =
        merge_catalog_sources([
          added_tokens.tokens,
          config_singletons.tokens,
          additional_special_tokens.tokens,
          helper_catalog.chat_template_literals,
          helper_catalog.wrapper_tool_markers,
          extras.tokens
        ])

      {:ok,
       %{
         "control_tokens" => control_tokens,
         "catalog_sha256" => hash_catalog(control_tokens),
         "catalog_source" => %{
           "added_tokens_count" => added_tokens.count,
           "config_singletons_count" => config_singletons.count,
           "additional_special_tokens_count" => additional_special_tokens.count,
           "chat_template_literals_count" => helper_catalog.chat_template_literals_count,
           "wrapper_tool_markers_count" => helper_catalog.wrapper_tool_markers_count,
           "extra_count" => extras.count
         }
       }}
    end
  end

  defp extract_added_tokens(%{"added_tokens" => added_tokens}) when is_list(added_tokens) do
    added_tokens
    |> Enum.flat_map(fn
      %{"content" => content} when is_binary(content) -> [content]
      _other -> []
    end)
    |> source_catalog()
  end

  defp extract_added_tokens(_tokenizer_json), do: source_catalog([])

  defp extract_config_singletons(%{config: config}) do
    @config_singleton_token_keys
    |> Enum.flat_map(fn key -> extract_token_value(Map.get(config, key)) end)
    |> source_catalog()
  end

  defp extract_config_singletons(_tokenizer_config_asset), do: source_catalog([])

  defp extract_additional_special_tokens(%{config: %{"additional_special_tokens" => tokens}})
       when is_list(tokens) do
    tokens
    |> Enum.flat_map(&extract_token_value/1)
    |> source_catalog()
  end

  defp extract_additional_special_tokens(_tokenizer_config_asset), do: source_catalog([])

  defp extract_token_value(value) when is_binary(value), do: [value]
  defp extract_token_value(%{"content" => content}) when is_binary(content), do: [content]
  defp extract_token_value(_value), do: []

  defp source_catalog(tokens) do
    observations = Enum.filter(tokens, &(is_binary(&1) and &1 != ""))

    %{
      tokens: sort_unique_utf8(observations),
      count: length(observations)
    }
  end

  defp source_catalog_tokens(tokens) do
    tokens
    |> Enum.reject(&(&1 == ""))
    |> sort_unique_utf8()
  end

  defp merge_catalog_sources(sources) do
    sources
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> sort_unique_utf8()
  end

  defp sort_unique_utf8(tokens) do
    tokens
    |> MapSet.new()
    |> Enum.sort_by(&:erlang.iolist_to_binary(&1), :asc)
  end

  defp maybe_extract_native_catalog(download_dir, tokenizer_config_asset, template_asset) do
    if should_invoke_safe_helper?(download_dir, tokenizer_config_asset, template_asset) do
      extract_native_catalog(download_dir, tokenizer_config_asset, template_asset)
    else
      {:ok, empty_helper_catalog()}
    end
  end

  defp should_invoke_safe_helper?(_download_dir, tokenizer_config_asset, template_asset) do
    not is_nil(template_asset) or is_binary(tool_parser_type(tokenizer_config_asset))
  end

  defp extract_native_catalog(download_dir, tokenizer_config_asset, template_asset) do
    with {:ok, executable_path} <-
           resolve_catalog_executable(Orchard.Inference.tokenizer_executable()),
         payload = build_catalog_payload(download_dir, tokenizer_config_asset, template_asset),
         {:ok, response_json, exit_status} <-
           run_catalog_helper(
             executable_path,
             Jason.encode!(payload),
             catalog_timeout_ms(),
             catalog_max_stdout_bytes()
           ),
         {:ok, response} <- decode_json_response(response_json),
         {:ok, catalog} <- normalize_catalog_response(response, exit_status) do
      {:ok, catalog}
    else
      {:error, reason} -> {:error, {:safe_tokenization_helper_unavailable, reason}}
    end
  end

  defp build_catalog_payload(download_dir, tokenizer_config_asset, template_asset) do
    assets =
      %{}
      |> maybe_put_catalog_tokenizer_config_path(tokenizer_config_asset)
      |> maybe_put_chat_template_path(download_dir, template_asset)

    %{
      "contract_version" => @catalog_contract_version,
      "command" => "extract_safe_tokenization_catalog",
      "assets" => assets,
      "options" => catalog_options(tokenizer_config_asset)
    }
  end

  defp maybe_put_catalog_tokenizer_config_path(assets, %{absolute_path: absolute_path}) do
    Map.put(assets, "tokenizer_config_path", absolute_path)
  end

  defp maybe_put_catalog_tokenizer_config_path(assets, _tokenizer_config_asset), do: assets

  defp maybe_put_chat_template_path(assets, _download_dir, nil), do: assets

  defp maybe_put_chat_template_path(assets, download_dir, %{path: path}) do
    Map.put(assets, "chat_template_path", Path.expand(path, download_dir))
  end

  defp catalog_options(tokenizer_config_asset) do
    case tool_parser_type(tokenizer_config_asset) do
      parser_type when is_binary(parser_type) -> %{"tool_parser_type" => parser_type}
      nil -> %{}
    end
  end

  defp tool_parser_type(%{config: config}) do
    cond do
      is_binary(Map.get(config, "tool_parser_type")) and Map.get(config, "tool_parser_type") != "" ->
        Map.fetch!(config, "tool_parser_type")

      is_binary(Map.get(config, "tool_parser")) and Map.get(config, "tool_parser") != "" ->
        Map.fetch!(config, "tool_parser")

      true ->
        nil
    end
  end

  defp tool_parser_type(_tokenizer_config_asset), do: nil

  defp empty_helper_catalog do
    %{
      chat_template_literals: [],
      wrapper_tool_markers: [],
      chat_template_literals_count: 0,
      wrapper_tool_markers_count: 0
    }
  end

  defp catalog_timeout_ms do
    Application.get_env(
      :orchard_controller,
      :bundle_build_catalog_timeout_ms,
      @default_catalog_timeout_ms
    )
  end

  defp catalog_max_stdout_bytes do
    case Application.get_env(:orchard_controller, :bundle_build_catalog_max_stdout_bytes) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_catalog_max_stdout_bytes
    end
  end

  defp resolve_catalog_executable(path) when is_binary(path) and path != "" do
    case Path.type(path) do
      :absolute ->
        expanded_path = Path.expand(path)

        case File.stat(expanded_path) do
          {:ok, %File.Stat{type: :regular}} -> {:ok, expanded_path}
          _other -> {:error, :unavailable}
        end

      _relative ->
        case System.find_executable(path) do
          resolved_path when is_binary(resolved_path) -> {:ok, resolved_path}
          _other -> {:error, :unavailable}
        end
    end
  end

  defp resolve_catalog_executable(_path), do: {:error, :unavailable}

  defp run_catalog_helper(executable_path, request_json, timeout_ms, max_stdout_bytes)
       when is_binary(executable_path) and is_binary(request_json) and is_integer(timeout_ms) and
              timeout_ms > 0 and is_integer(max_stdout_bytes) and max_stdout_bytes > 0 do
    HelperRequestTransport.with_secure_request_file(
      "orchard-tokenizer-catalog",
      request_json,
      fn request_path ->
        run_catalog_port(executable_path, request_path, timeout_ms, max_stdout_bytes)
      end
    )
  end

  defp run_catalog_helper(_executable_path, _request_json, _timeout_ms, _max_stdout_bytes),
    do: {:error, :timeout}

  defp run_catalog_port(executable_path, request_path, timeout_ms, max_stdout_bytes) do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :use_stdio,
          {:args,
           [
             "-c",
             ~s(exec "$1" < "$2"),
             "orchard-tokenizer-catalog",
             executable_path,
             request_path
           ]}
        ]
      )

    HelperOutputCollector.collect(port, timeout_ms, max_stdout_bytes)
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp decode_json_response(response_json) when is_binary(response_json) do
    case Jason.decode(response_json) do
      {:ok, response} when is_map(response) -> {:ok, response}
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_catalog_response(
         %{
           "contract_version" => @catalog_contract_version,
           "ok" => true,
           "result" => result
         } = response,
         0
       )
       when is_map(result) do
    with true <- exact_keys?(response, ["contract_version", "ok", "result"]),
         true <-
           exact_keys?(result, [
             "control_tokens_chat_template",
             "control_tokens_wrapper_tool",
             "chat_template_literals_count",
             "wrapper_tool_markers_count"
           ]),
         chat_template_literals = Map.fetch!(result, "control_tokens_chat_template"),
         wrapper_tool_markers = Map.fetch!(result, "control_tokens_wrapper_tool"),
         chat_template_literals_count = Map.fetch!(result, "chat_template_literals_count"),
         wrapper_tool_markers_count = Map.fetch!(result, "wrapper_tool_markers_count"),
         :ok <- validate_helper_source(chat_template_literals, chat_template_literals_count),
         :ok <- validate_helper_source(wrapper_tool_markers, wrapper_tool_markers_count) do
      {:ok,
       %{
         chat_template_literals: chat_template_literals,
         wrapper_tool_markers: wrapper_tool_markers,
         chat_template_literals_count: chat_template_literals_count,
         wrapper_tool_markers_count: wrapper_tool_markers_count
       }}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  defp normalize_catalog_response(
         %{
           "contract_version" => @catalog_contract_version,
           "ok" => false,
           "error" => %{"category" => category, "message" => message}
         },
         _exit_status
       )
       when is_binary(category) and is_binary(message) do
    {:error, {normalize_catalog_error_category(category), message}}
  end

  defp normalize_catalog_response(_response, _exit_status), do: {:error, :invalid_response}

  defp exact_keys?(map, keys) do
    MapSet.new(Map.keys(map)) == MapSet.new(keys)
  end

  defp validate_helper_source(tokens, count)
       when is_list(tokens) and is_integer(count) and count >= 0 do
    if valid_helper_tokens?(tokens) and valid_helper_count?(tokens, count) do
      :ok
    else
      {:error, :invalid_response}
    end
  end

  defp validate_helper_source(_tokens, _count), do: {:error, :invalid_response}

  defp valid_helper_tokens?(tokens) do
    Enum.all?(tokens, &(is_binary(&1) and &1 != "")) and source_catalog_tokens(tokens) == tokens
  end

  defp valid_helper_count?([], count), do: count == 0
  defp valid_helper_count?(tokens, count), do: count >= length(tokens)

  defp normalize_catalog_error_category("invalid_input"), do: :invalid_input
  defp normalize_catalog_error_category("missing_assets"), do: :missing_assets
  defp normalize_catalog_error_category(_category), do: :internal_error

  # -- Eager Safe Tokenization Preflight --------------------------------------

  defp maybe_run_eager_preflight(
         download_dir,
         tokenizer_config_asset,
         template_asset,
         safe_tokenization
       ) do
    input = %{
      bundle_dir: download_dir,
      tokenizer_kind: "huggingface_tokenizer_json",
      tokenizer_path: Path.join(download_dir, "tokenizer.json"),
      tokenizer_config_path: tokenizer_config_path(tokenizer_config_asset),
      chat_template_path: chat_template_path(download_dir, template_asset),
      control_tokens: Map.get(safe_tokenization, "control_tokens"),
      catalog_sha256: Map.get(safe_tokenization, "catalog_sha256")
    }

    input
    |> SafeTokenizationPreflight.run()
    |> then(&SafeTokenizationPreflight.merge_into_safe_tokenization_map(safe_tokenization, &1))
  end

  defp tokenizer_config_path(%{absolute_path: absolute_path}), do: absolute_path
  defp tokenizer_config_path(_tokenizer_config_asset), do: nil

  defp chat_template_path(download_dir, %{path: path}), do: Path.expand(path, download_dir)
  defp chat_template_path(_download_dir, _template_asset), do: nil

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

  defp build_manifest(attrs) do
    tokenizer =
      %{
        "kind" => "huggingface_tokenizer_json",
        "path" => "tokenizer.json"
      }
      |> maybe_put_tokenizer_config_path(attrs.tokenizer_config_asset)

    base = %{
      "model_id" => attrs.repo_id,
      "version" => attrs.version,
      "format" => "mlx",
      "artifact_layout" => "directory",
      "entrypoint" => ".",
      "sha256" => "pending",
      "size_bytes" => attrs.size_bytes,
      "resident_memory_bytes" => attrs.resident_memory_bytes,
      "kv_cache_bytes_per_token" => attrs.kv_cache_bytes_per_token,
      "prefill_workspace_bytes_per_token" => 0,
      "max_context_tokens" => attrs.max_context_tokens,
      "capabilities" => ["chat"],
      "tokenizer" => tokenizer,
      "safe_tokenization" => attrs.safe_tokenization,
      "runtime_requirements" => %{
        "adapter" => "mlx_lm",
        "min_agent_capability" => "mlx"
      }
    }

    case attrs.template_asset do
      %{path: path, sha256: sha256} ->
        Map.put(base, "chat_template", %{"path" => path, "sha256" => sha256})

      nil ->
        base
    end
  end

  defp maybe_put_tokenizer_config_path(tokenizer, %{path: path}) do
    Map.put(tokenizer, "config_path", path)
  end

  defp maybe_put_tokenizer_config_path(tokenizer, _tokenizer_config_asset), do: tokenizer

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

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
