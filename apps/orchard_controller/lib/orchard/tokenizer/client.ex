defmodule Orchard.Tokenizer.Client do
  @moduledoc """
  Injectable tokenizer seam for controller-side prompt rendering and token counting.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ToolingValidation
  alias Orchard.ModelManifest
  alias Orchard.PathUtils

  alias Orchard.Tokenizer.{
    CallerStrings,
    CompatibilityCache,
    ControlTokenDetector,
    HelperOutputCollector,
    HelperRequestTransport,
    Telemetry
  }

  @render_and_count_contract_version 2
  @render_and_count_segmented_contract_version 3
  @default_timeout_ms 5_000
  @default_runtime_max_stdout_bytes 16_777_216
  @control_token_catalog_kinds ~w(huggingface_tokenizer_json tokenizer_json)
  @segmented_tokenizer_kinds ~w(huggingface_tokenizer_json tokenizer_json)
  @supported_message_roles MapSet.new(~w(system developer user assistant tool))
  @tokenizer_incompatibility_categories ~w(
    per_codepoint_decode_mismatch
    reserved_id_persists
    reserved_id_set_overlap
    empty_literal
  )
  @template_incompatibility_categories ~w(dual_render_mismatch)
  @all_incompatibility_categories @tokenizer_incompatibility_categories ++
                                    @template_incompatibility_categories
  @skip_sentinel_preflight_env "ORCHARD_TOKENIZER_SKIP_SENTINEL_PREFLIGHT"
  @sha256_hex ~r/\A[0-9a-f]{64}\z/

  @type tokenization_result :: %{
          required(:rendered_prompt) => binary(),
          required(:input_token_count) => non_neg_integer(),
          optional(:prompt_token_ids) => [non_neg_integer()]
        }

  @type error_reason ::
          {:invalid_input
           | :missing_assets
           | :unsupported_tokenizer
           | :internal_error
           | :safe_tokenization_incompatible_tokenizer
           | :safe_tokenization_incompatible_template
           | :safe_tokenization_marker_collision
           | :safe_tokenization_catalog_hash_mismatch, String.t()}
          | {:stdout_too_large, pos_integer()}
          | :invalid_response
          | :timeout
          | :unavailable
          | :not_implemented

  @callback tokenize(CanonicalRequest.t(), keyword()) ::
              {:ok, tokenization_result()} | {:error, error_reason()}

  @doc false
  @spec incompatibility_reason_category_sets() :: %{
          all: [String.t()],
          tokenizer: [String.t()],
          template: [String.t()]
        }
  # Contract tests inspect tokenizer-owned enum strings without promoting this to product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def incompatibility_reason_category_sets do
    %{
      all: Enum.sort(@all_incompatibility_categories),
      tokenizer: Enum.sort(@tokenizer_incompatibility_categories),
      template: Enum.sort(@template_incompatibility_categories)
    }
  end

  @doc false
  @spec incompatibility_reason_rules() :: %{
          path: :runtime_success_verdict,
          reason_key_encoding: :string,
          categories: %{String.t() => map()}
        }
  # Contract tests inspect tokenizer-owned semantic verdict rules without promoting this to product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def incompatibility_reason_rules do
    %{
      path: :runtime_success_verdict,
      reason_key_encoding: :string,
      categories: %{
        "dual_render_mismatch" => %{
          required: ["category", "first_diff_offset", "leaf_class", "sentinel_index"],
          template_compatible: :equals_false,
          leaf_class: :non_empty_binary,
          sentinel_index: :non_negative_integer,
          first_diff_offset: :non_negative_integer
        },
        "empty_literal" => %{
          required: ["category", "literal"],
          literal: :equals_empty_string,
          template_compatible: :equals_true
        },
        "per_codepoint_decode_mismatch" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :equals_true
        },
        "reserved_id_persists" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :equals_true
        },
        "reserved_id_set_overlap" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :equals_true
        }
      }
    }
  end

  def tokenize(%CanonicalRequest{} = request, opts \\ []) do
    with :ok <- validate_input_item_roles(request.input_items) do
      case Orchard.Inference.tokenizer_client() do
        __MODULE__ -> default_tokenize(request, opts)
        module -> module.tokenize(request, opts)
      end
    end
  end

  def mode, do: Orchard.Inference.tokenizer_mode()
  def executable, do: Orchard.Inference.tokenizer_executable()

  defp default_tokenize(%CanonicalRequest{} = request, opts) do
    case mode() do
      :fake -> fake_tokenize(request)
      :port -> port_tokenize(request, opts)
      _other -> {:error, :not_implemented}
    end
  end

  defp fake_tokenize(%CanonicalRequest{} = request) do
    if tool_calling_enabled?(request) do
      {:error,
       {:invalid_input,
        "fake tokenizer mode does not support tool-calling requests; switch to tokenizer_mode=:port"}}
    else
      with {:ok, prompt_lines} <- build_prompt_lines(request.input_items) do
        rendered_prompt = Enum.join(prompt_lines ++ ["assistant"], "\n")

        {:ok,
         %{rendered_prompt: rendered_prompt, input_token_count: fake_token_count(rendered_prompt)}}
      end
    end
  end

  defp port_tokenize(%CanonicalRequest{} = request, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_stdout_bytes = runtime_max_stdout_bytes(opts)

    with {:ok, plan} <- build_tokenization_plan(request, opts),
         :ok <- observe_control_token_inputs(request, plan.payload, opts),
         {:ok, executable_path} <- resolve_executable(executable()),
         {:ok, response_json, exit_status} <-
           run_executable(
             executable_path,
             Jason.encode!(plan.payload),
             timeout_ms,
             max_stdout_bytes,
             Map.get(plan, :helper_env, [])
           ),
         {:ok, response} <- decode_response(response_json) do
      normalize_response(response, exit_status, plan)
    end
  end

  defp build_tokenization_plan(%CanonicalRequest{} = request, opts) do
    case Orchard.Inference.tokenizer_safe_mode() do
      :off -> build_legacy_plan(request, opts)
      :on -> build_safe_plan_or_degrade(request, opts)
      :reject -> build_safe_plan_or_reject(request, opts)
    end
  end

  defp build_legacy_plan(%CanonicalRequest{} = request, opts) do
    with {:ok, assets} <- resolve_legacy_assets(opts) do
      {:ok, %{mode: :legacy, payload: legacy_payload(request, assets)}}
    end
  end

  defp build_safe_plan_or_degrade(%CanonicalRequest{} = request, opts) do
    case safe_tokenization_from_opts(opts) do
      {:ok, nil, manifest} ->
        Telemetry.emit_degraded_no_manifest_catalog(request, manifest)
        build_legacy_plan(request, opts)

      {:ok, safe_tokenization, manifest} ->
        build_segmented_plan(request, opts, manifest, safe_tokenization)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_safe_plan_or_reject(%CanonicalRequest{} = request, opts) do
    case safe_tokenization_from_opts(opts) do
      {:ok, nil, _manifest} ->
        {:error,
         {:invalid_input,
          "tokenizer_safe_mode=:reject requires a manifest safe_tokenization catalog"}}

      {:ok, safe_tokenization, manifest} ->
        build_segmented_plan(request, opts, manifest, safe_tokenization)

      {:error, _reason} = error ->
        error
    end
  end

  defp build_segmented_plan(
         %CanonicalRequest{} = request,
         opts,
         %ModelManifest{} = _manifest,
         safe_tokenization
       ) do
    with :ok <- ensure_manifest_safe_tokenization_compatible(safe_tokenization),
         {:ok, assets} <- resolve_segmented_assets(opts),
         {:ok, cache_key} <- compatibility_cache_key(opts, safe_tokenization),
         :ok <- maybe_seed_manifest_preflight_compatible(cache_key, safe_tokenization),
         {:ok, cache_metadata} <- ensure_cache_compatible(cache_key) do
      {:ok,
       %{
         mode: :segmented,
         cache_key: cache_key,
         payload: segmented_payload(request, assets, safe_tokenization),
         helper_env: segmented_helper_env(cache_metadata)
       }}
    end
  end

  defp legacy_payload(%CanonicalRequest{} = request, assets) do
    %{
      contract_version: @render_and_count_contract_version,
      command: "render_and_count",
      assets: assets,
      request: request_payload(request)
    }
  end

  defp segmented_payload(%CanonicalRequest{} = request, assets, safe_tokenization) do
    %{
      contract_version: @render_and_count_segmented_contract_version,
      command: "render_and_count_segmented",
      assets: assets,
      safe_tokenization: %{
        control_tokens: safe_tokenization.control_tokens,
        catalog_sha256: safe_tokenization.catalog_sha256
      },
      request: request_payload(request)
    }
  end

  defp request_payload(%CanonicalRequest{} = request) do
    %{
      input_items: request.input_items,
      tools: request.tooling.tools,
      tool_choice: request.tooling.tool_choice
    }
  end

  defp observe_control_token_inputs(%CanonicalRequest{} = request, payload, opts) do
    manifest = Keyword.get(opts, :manifest)

    try do
      assets = Map.get(payload, :assets, %{})
      tokenizer_kind = Map.get(assets, :tokenizer_kind)

      if tokenizer_kind in @control_token_catalog_kinds do
        assets
        |> Map.get(:tokenizer_path)
        |> observe_control_token_inputs(request, manifest, opts)
      end
    rescue
      _exception ->
        Telemetry.emit_detector_error(:detector_exception, request, manifest)
    catch
      kind, _reason ->
        Telemetry.emit_detector_error({:detector_catch, kind}, request, manifest)
    end

    :ok
  end

  defp observe_control_token_inputs(tokenizer_path, request, manifest, opts)
       when is_binary(tokenizer_path) do
    detector = Keyword.get(opts, :control_token_detector, ControlTokenDetector)

    case detector.partial_catalog(tokenizer_path) do
      {:ok, catalog, diagnostics} ->
        Enum.each(diagnostics, fn diagnostic ->
          Telemetry.emit_detector_error(diagnostic, request, manifest)
        end)

        hits =
          request.input_items
          |> CallerStrings.walk_caller_strings(request.tooling.tools, request.tooling.tool_choice)
          |> then(&detector.detect(catalog, &1))

        Telemetry.emit_control_token_hits(hits, request, manifest)
        maybe_emit_catalog_drift(catalog, manifest, request, opts)

      {:error, reason} ->
        Telemetry.emit_detector_error({:catalog_load_failed, reason}, request, manifest)
    end
  end

  defp observe_control_token_inputs(tokenizer_path, request, manifest, _opts) do
    Telemetry.emit_detector_error(
      {:missing_tokenizer_path, value_kind(tokenizer_path)},
      request,
      manifest
    )
  end

  defp maybe_emit_catalog_drift(
         _catalog,
         %ModelManifest{safe_tokenization: nil},
         _request,
         _opts
       ),
       do: :ok

  defp maybe_emit_catalog_drift(_catalog, nil, _request, _opts), do: :ok

  defp maybe_emit_catalog_drift(
         catalog,
         %ModelManifest{safe_tokenization: %{control_tokens: control_tokens} = safe_tokenization} =
           manifest,
         %CanonicalRequest{} = request,
         opts
       )
       when is_list(catalog) and is_list(control_tokens) do
    added =
      catalog
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(control_tokens))
      |> MapSet.to_list()
      |> Enum.sort()

    case added do
      [] ->
        :ok

      added ->
        Telemetry.catalog_drift(%{
          request_id: request.public_id,
          model_id: request.model_ref.model_id,
          version: request.model_ref.version,
          endpoint: request.endpoint,
          bundle_id: manifest.sha256,
          bundle_sha256: Keyword.get(opts, :bundle_sha256),
          catalog_sha256: safe_tokenization.catalog_sha256,
          added: added,
          added_count: length(added),
          partial_detection: true,
          covered_catalog_sources: [
            :tokenizer_special_added_tokens,
            :tokenizer_config_singletons,
            :additional_special_tokens
          ],
          missing_catalog_sources: [
            :tokenizer_non_special_added_tokens,
            :chat_template_literals,
            :wrapper_tool_markers
          ],
          drift_direction: :added_only
        })
    end
  end

  defp maybe_emit_catalog_drift(_catalog, _manifest, _request, _opts), do: :ok

  defp value_kind(value) when is_nil(value), do: nil
  defp value_kind(value) when is_binary(value), do: :binary
  defp value_kind(value) when is_atom(value), do: :atom
  defp value_kind(value) when is_integer(value), do: :integer
  defp value_kind(value) when is_float(value), do: :float
  defp value_kind(value) when is_list(value), do: :list
  defp value_kind(value) when is_map(value), do: :map
  defp value_kind(_value), do: :other

  defp safe_tokenization_from_opts(opts) do
    case Keyword.get(opts, :manifest) do
      %ModelManifest{safe_tokenization: safe_tokenization} = manifest ->
        {:ok, safe_tokenization, manifest}

      _other ->
        {:error,
         {:invalid_input,
          "tokenizer opts must include :manifest with an Orchard.ModelManifest and optional :bundle_root"}}
    end
  end

  defp ensure_manifest_safe_tokenization_compatible(
         %{template_compatible: false} = safe_tokenization
       ) do
    {:error,
     {:safe_tokenization_incompatible_template,
      "manifest safe_tokenization marks this chat template incompatible: #{inspect(safe_tokenization.incompatibility_reason)}"}}
  end

  defp ensure_manifest_safe_tokenization_compatible(%{compatible: false} = safe_tokenization) do
    {:error,
     {:safe_tokenization_incompatible_tokenizer,
      "manifest safe_tokenization marks this bundle incompatible: #{inspect(safe_tokenization.incompatibility_reason)}"}}
  end

  defp ensure_manifest_safe_tokenization_compatible(_safe_tokenization), do: :ok

  defp compatibility_cache_key(opts, %{catalog_sha256: catalog_sha256})
       when is_binary(catalog_sha256) and catalog_sha256 != "" do
    case Keyword.get(opts, :bundle_sha256) do
      bundle_sha256 when is_binary(bundle_sha256) ->
        if String.match?(bundle_sha256, @sha256_hex) do
          {:ok, {bundle_sha256, catalog_sha256}}
        else
          {:error,
           {:invalid_input,
            "tokenizer opts must include trusted :bundle_sha256 as 64-character lowercase hex for segmented tokenization"}}
        end

      _other ->
        {:error,
         {:invalid_input,
          "tokenizer opts must include trusted :bundle_sha256 for segmented tokenization"}}
    end
  end

  defp compatibility_cache_key(_opts, _safe_tokenization) do
    {:error,
     {:invalid_input,
      "manifest safe_tokenization must include a non-empty catalog_sha256 for segmented tokenization"}}
  end

  # Positive manifest declarations share the import-time trust boundary: they may
  # seed only when the operator accepts authored compatibility claims.
  defp maybe_seed_manifest_preflight_compatible(
         {bundle_sha256, catalog_sha256},
         %{preflight_compatible_declared?: true}
       ) do
    if trust_manifest_compatibility_declarations?() do
      CompatibilityCache.put_compatible_if_safe(bundle_sha256, catalog_sha256, %{
        template_compatible: true,
        sentinel_preflight_validated: true
      })
    else
      :ok
    end
  end

  defp maybe_seed_manifest_preflight_compatible(_cache_key, _safe_tokenization), do: :ok

  defp trust_manifest_compatibility_declarations? do
    Application.get_env(:orchard_controller, :trust_manifest_compatibility_declarations, true)
  end

  defp ensure_cache_compatible({bundle_sha256, catalog_sha256}) do
    case CompatibilityCache.get(bundle_sha256, catalog_sha256) do
      :unknown ->
        {:ok, nil}

      {:compatible, %{template_compatible: false} = metadata} ->
        {:error,
         {:safe_tokenization_incompatible_template,
          "cached safe-tokenization template incompatibility: #{inspect(metadata)}"}}

      {:compatible, metadata} ->
        {:ok, metadata}

      {:incompatible, reason} ->
        {:error, cached_incompatibility_error(reason)}
    end
  end

  defp segmented_helper_env(%{sentinel_preflight_validated: true}) do
    [{@skip_sentinel_preflight_env, "1"}]
  end

  defp segmented_helper_env(_metadata), do: [{@skip_sentinel_preflight_env, "0"}]

  defp cached_incompatibility_error(%{category: category} = reason) when is_binary(category) do
    {normalize_reason_category(reason),
     "cached safe-tokenization incompatibility: #{inspect(reason)}"}
  end

  defp cached_incompatibility_error(%{"category" => category} = reason)
       when is_binary(category) do
    {normalize_reason_category(reason),
     "cached safe-tokenization incompatibility: #{inspect(reason)}"}
  end

  defp cached_incompatibility_error(reason) do
    {:safe_tokenization_incompatible_tokenizer,
     "cached safe-tokenization incompatibility: #{inspect(reason)}"}
  end

  defp resolve_legacy_assets(opts) do
    manifest = Keyword.get(opts, :manifest)
    bundle_root = Keyword.get(opts, :bundle_root)

    with {:ok, manifest_assets} <- extract_manifest_assets(manifest),
         {:ok, resolved_tokenizer_path} <-
           resolve_asset_path(manifest_assets.tokenizer_path, bundle_root),
         {:ok, resolved_chat_template_path} <-
           resolve_asset_path(manifest_assets.chat_template_path, bundle_root) do
      {:ok,
       %{
         tokenizer_kind: manifest_assets.tokenizer_kind,
         tokenizer_path: resolved_tokenizer_path,
         chat_template_path: resolved_chat_template_path
       }}
    end
  end

  defp resolve_segmented_assets(opts) do
    manifest = Keyword.get(opts, :manifest)
    bundle_root = Keyword.get(opts, :bundle_root)

    with {:ok, manifest_assets} <- extract_manifest_assets(manifest),
         :ok <- ensure_segmented_tokenizer_kind(manifest_assets.tokenizer_kind),
         {:ok, resolved_tokenizer_path} <-
           resolve_asset_path(manifest_assets.tokenizer_path, bundle_root),
         {:ok, resolved_chat_template_path} <-
           resolve_asset_path(manifest_assets.chat_template_path, bundle_root),
         {:ok, resolved_tokenizer_config_path} <-
           resolve_tokenizer_config_asset(
             manifest_assets.tokenizer_config_path,
             manifest_assets.tokenizer_path,
             bundle_root
           ) do
      {:ok,
       %{
         tokenizer_kind: manifest_assets.tokenizer_kind,
         tokenizer_path: resolved_tokenizer_path,
         tokenizer_config_path: resolved_tokenizer_config_path,
         chat_template_path: resolved_chat_template_path
       }}
    end
  end

  defp ensure_segmented_tokenizer_kind(tokenizer_kind)
       when tokenizer_kind in @segmented_tokenizer_kinds,
       do: :ok

  defp ensure_segmented_tokenizer_kind(tokenizer_kind) do
    {:error,
     {:unsupported_tokenizer,
      "safe tokenization segmented mode requires a HuggingFace tokenizer, got: #{inspect(tokenizer_kind)}"}}
  end

  defp resolve_tokenizer_config_asset(config_path, _tokenizer_path, bundle_root)
       when is_binary(config_path) and config_path != "" do
    resolve_asset_path(config_path, bundle_root)
  end

  defp resolve_tokenizer_config_asset(_config_path, tokenizer_path, bundle_root)
       when is_binary(tokenizer_path) and tokenizer_path != "" do
    fallback_path = Path.join(Path.dirname(tokenizer_path), "tokenizer_config.json")

    case resolve_asset_path(fallback_path, bundle_root) do
      {:ok, resolved_path} ->
        {:ok, resolved_path}

      {:error, _reason} ->
        {:error,
         {:missing_assets,
          "safe tokenization requires tokenizer.config_path or sibling tokenizer_config.json"}}
    end
  end

  defp extract_manifest_assets(
         %ModelManifest{tokenizer: tokenizer, chat_template: chat_template} = manifest
       ) do
    with {:ok, tokenizer_kind, tokenizer_path, tokenizer_config_path} <-
           extract_tokenizer_asset(tokenizer),
         {:ok, chat_template_path} <- extract_chat_template_asset(chat_template) do
      {:ok,
       %{
         tokenizer_kind: tokenizer_kind,
         tokenizer_path: tokenizer_path,
         tokenizer_config_path: tokenizer_config_path,
         chat_template_path: chat_template_path,
         safe_tokenization: manifest.safe_tokenization
       }}
    end
  end

  defp extract_manifest_assets(_other) do
    {:error,
     {:invalid_input,
      "tokenizer opts must include :manifest with an Orchard.ModelManifest and optional :bundle_root"}}
  end

  defp extract_tokenizer_asset(%{kind: kind, path: path, config_path: config_path})
       when is_binary(kind) and kind != "" and is_binary(path) and path != "" do
    {:ok, kind, path, config_path}
  end

  defp extract_tokenizer_asset(%{kind: kind, path: path})
       when is_binary(kind) and kind != "" and is_binary(path) and path != "" do
    {:ok, kind, path, nil}
  end

  defp extract_tokenizer_asset(_other) do
    {:error, {:missing_assets, "model manifest tokenizer must include non-empty kind and path"}}
  end

  defp extract_chat_template_asset(nil) do
    {:error,
     {:missing_assets,
      "model manifest must include chat_template with a non-empty path for port-mode tokenization"}}
  end

  defp extract_chat_template_asset(%{path: path}) when is_binary(path) and path != "" do
    {:ok, path}
  end

  defp extract_chat_template_asset(_other) do
    {:error,
     {:missing_assets, "model manifest chat_template must include a non-empty path when present"}}
  end

  defp resolve_asset_path(path, bundle_root) when is_binary(path) and path != "" do
    case bundle_root do
      nil ->
        resolve_absolute_asset_path(path)

      bundle_root when is_binary(bundle_root) and bundle_root != "" ->
        resolve_bundle_asset_path(path, bundle_root)

      _other ->
        {:error, {:invalid_input, "bundle_root must be a non-empty binary when provided"}}
    end
  end

  defp resolve_asset_path(path, _bundle_root) do
    {:error,
     {:invalid_input, "tokenizer asset path must be a non-empty binary, got: #{inspect(path)}"}}
  end

  defp resolve_absolute_asset_path(path) do
    case Path.type(path) do
      :absolute ->
        {:ok, Path.expand(path)}

      _relative ->
        {:error,
         {:invalid_input,
          "relative tokenizer asset paths require :bundle_root, got: #{inspect(path)}"}}
    end
  end

  defp resolve_bundle_asset_path(path, bundle_root) do
    with {:ok, real_root} <- realpath_bundle_root(bundle_root) do
      expanded_path = Path.expand(path, real_root)

      case realpath_asset(expanded_path) do
        {:ok, real_asset} ->
          ensure_confined(real_asset, real_root, path)

        {:error, _posix} ->
          {:error,
           {:missing_assets, "tokenizer asset not found or inaccessible: #{inspect(path)}"}}
      end
    end
  end

  defp realpath_bundle_root(bundle_root) do
    case PathUtils.resolve_realpath(Path.expand(bundle_root)) do
      {:ok, real_root} ->
        {:ok, real_root}

      {:error, _posix} ->
        {:error,
         {:invalid_input,
          "bundle_root does not exist or is inaccessible: #{inspect(bundle_root)}"}}
    end
  end

  defp realpath_asset(expanded_path) do
    PathUtils.resolve_realpath(expanded_path)
  end

  defp ensure_confined(real_asset, real_root, original_path) do
    case Path.relative_to(real_asset, real_root) do
      <<"..", _rest::binary>> ->
        {:error,
         {:invalid_input, "tokenizer asset path escapes bundle_root: #{inspect(original_path)}"}}

      ^real_asset ->
        # Path.relative_to returns the path unchanged when it's not relative to root
        {:error,
         {:invalid_input, "tokenizer asset path escapes bundle_root: #{inspect(original_path)}"}}

      _relative_path ->
        {:ok, real_asset}
    end
  end

  defp resolve_executable(path) when is_binary(path) and path != "" do
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

  defp resolve_executable(_path), do: {:error, :unavailable}

  defp runtime_max_stdout_bytes(opts) do
    case Keyword.get(opts, :max_stdout_bytes) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        case Application.get_env(:orchard_controller, :tokenizer_runtime_max_stdout_bytes) do
          value when is_integer(value) and value > 0 -> value
          _other -> @default_runtime_max_stdout_bytes
        end
    end
  end

  defp run_executable(executable_path, request_json, timeout_ms, max_stdout_bytes, helper_env)
       when is_binary(executable_path) and is_binary(request_json) and is_integer(timeout_ms) and
              timeout_ms > 0 and is_integer(max_stdout_bytes) and max_stdout_bytes > 0 and
              is_list(helper_env) do
    HelperRequestTransport.with_secure_request_file(
      "orchard-tokenizer-request",
      request_json,
      fn request_path ->
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
                 "orchard-tokenizer-port",
                 executable_path,
                 request_path
               ]}
            ] ++ port_env_options(helper_env)
          )

        HelperOutputCollector.collect(port, timeout_ms, max_stdout_bytes)
      end
    )
    |> map_request_transport_failure()
  rescue
    ArgumentError ->
      {:error, :unavailable}
  end

  defp map_request_transport_failure({:error, {:request_transport_failed, _reason}}),
    do: {:error, :unavailable}

  defp map_request_transport_failure(result), do: result

  defp port_env_options([]), do: []

  defp port_env_options(helper_env) do
    env =
      Enum.map(helper_env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    [{:env, env}]
  end

  defp decode_response(response_json) when is_binary(response_json) do
    case Jason.decode(response_json) do
      {:ok, response} when is_map(response) -> {:ok, response}
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_contract_version,
           "ok" => true,
           "result" => %{
             "rendered_prompt" => rendered_prompt,
             "input_token_count" => input_token_count
           }
         },
         0,
         %{mode: :legacy}
       )
       when is_binary(rendered_prompt) and is_integer(input_token_count) and
              input_token_count >= 0 do
    {:ok, %{rendered_prompt: rendered_prompt, input_token_count: input_token_count}}
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_contract_version,
           "ok" => false,
           "error" => %{"category" => category, "message" => message}
         },
         _exit_status,
         %{mode: :legacy}
       )
       when is_binary(category) and is_binary(message) do
    {:error, {normalize_error_category(category), message}}
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_segmented_contract_version,
           "ok" => true,
           "result" => result
         },
         0,
         %{mode: :segmented, cache_key: cache_key}
       )
       when is_map(result) do
    normalize_segmented_success(result, cache_key)
  end

  defp normalize_response(
         %{
           "contract_version" => @render_and_count_segmented_contract_version,
           "ok" => false,
           "error" => %{"category" => category, "message" => message} = error
         },
         _exit_status,
         %{mode: :segmented, cache_key: cache_key}
       )
       when is_binary(category) and is_binary(message) do
    maybe_cache_segmented_incompatibility(cache_key, category, error)
    {:error, {normalize_error_category(category), message}}
  end

  defp normalize_response(_response, _exit_status, _plan), do: {:error, :invalid_response}

  defp normalize_segmented_success(
         %{
           "rendered_prompt" => rendered_prompt,
           "input_token_count" => input_token_count,
           "prompt_token_ids" => prompt_token_ids
         } = result,
         {bundle_sha256, catalog_sha256} = cache_key
       )
       when is_binary(rendered_prompt) and is_integer(input_token_count) and
              input_token_count >= 0 and is_list(prompt_token_ids) do
    with :ok <- ensure_segmented_result_compatible(result, cache_key),
         true <- valid_prompt_token_ids?(prompt_token_ids, input_token_count) do
      CompatibilityCache.put_compatible(bundle_sha256, catalog_sha256, %{
        template_compatible: true,
        sentinel_preflight_validated: true
      })

      {:ok,
       %{
         rendered_prompt: rendered_prompt,
         input_token_count: input_token_count,
         prompt_token_ids: prompt_token_ids
       }}
    else
      false -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_segmented_success(_result, _cache_key), do: {:error, :invalid_response}

  defp ensure_segmented_result_compatible(result, cache_key) do
    compatible? = Map.get(result, "compatible")
    template_compatible? = Map.get(result, "template_compatible")
    incompatibility_reason = Map.get(result, "incompatibility_reason")

    cond do
      not is_boolean(compatible?) ->
        {:error, :invalid_response}

      not is_boolean(template_compatible?) ->
        {:error, :invalid_response}

      compatible? == true and template_compatible? == true and is_nil(incompatibility_reason) ->
        :ok

      compatible? == false ->
        validate_incompatible_segmented_success(
          template_compatible?,
          incompatibility_reason,
          cache_key
        )

      true ->
        {:error, :invalid_response}
    end
  end

  defp validate_incompatible_segmented_success(template_compatible?, reason, cache_key) do
    case validate_segmented_incompatibility_reason(reason, template_compatible?) do
      :ok ->
        maybe_cache_segmented_incompatibility(cache_key, reason)

        {:error,
         {normalize_reason_category(reason), "safe tokenization helper returned incompatible"}}

      :error ->
        {:error, :invalid_response}
    end
  end

  defp validate_segmented_incompatibility_reason(
         %{"category" => category} = reason,
         template_compatible?
       )
       when category in @tokenizer_incompatibility_categories do
    if template_compatible? == true and valid_tokenizer_reason?(reason, category) do
      :ok
    else
      :error
    end
  end

  defp validate_segmented_incompatibility_reason(
         %{"category" => "dual_render_mismatch"} = reason,
         template_compatible?
       ) do
    if template_compatible? == false and valid_dual_render_reason?(reason) do
      :ok
    else
      :error
    end
  end

  defp validate_segmented_incompatibility_reason(_reason, _template_compatible?), do: :error

  defp valid_tokenizer_reason?(reason, "empty_literal"),
    do: Map.get(reason, "literal") == ""

  defp valid_tokenizer_reason?(reason, _category),
    do: non_empty_binary?(Map.get(reason, "literal"))

  defp valid_dual_render_reason?(reason) do
    non_empty_binary?(Map.get(reason, "leaf_class")) and
      non_negative_integer?(Map.get(reason, "sentinel_index")) and
      non_negative_integer?(Map.get(reason, "first_diff_offset"))
  end

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp valid_prompt_token_ids?(prompt_token_ids, input_token_count) do
    length(prompt_token_ids) == input_token_count and
      Enum.all?(prompt_token_ids, &(is_integer(&1) and &1 >= 0))
  end

  defp maybe_cache_segmented_incompatibility(cache_key, category, error)
       when category in [
              "safe_tokenization_incompatible_tokenizer",
              "safe_tokenization_incompatible_template"
            ] do
    maybe_cache_segmented_incompatibility(cache_key, Map.put(error, "category", category))
  end

  defp maybe_cache_segmented_incompatibility(_cache_key, _category, _error), do: :ok

  defp maybe_cache_segmented_incompatibility({bundle_sha256, catalog_sha256}, reason) do
    case normalize_reason_category(reason) do
      category
      when category in [
             :safe_tokenization_incompatible_tokenizer,
             :safe_tokenization_incompatible_template
           ] ->
        CompatibilityCache.put_incompatible(
          bundle_sha256,
          catalog_sha256,
          normalize_cache_reason(reason)
        )

      _other ->
        :ok
    end
  end

  defp normalize_cache_reason(%{"category" => category, "details" => %{"reason" => reason}})
       when is_binary(category) and is_map(reason) do
    case reason do
      %{"category" => inner} when is_binary(inner) ->
        Map.put_new(reason, "outer_category", category)

      _other ->
        reason
        |> Map.put("category", category)
        |> Map.put_new("outer_category", category)
    end
  end

  defp normalize_cache_reason(%{"category" => category} = reason) when is_binary(category),
    do: reason

  defp normalize_cache_reason(%{category: category} = reason) when is_binary(category), do: reason
  defp normalize_cache_reason(reason), do: reason

  defp normalize_reason_category(%{"category" => category, "outer_category" => outer_category})
       when is_binary(category) and is_binary(outer_category) do
    case normalize_error_category(outer_category) do
      :internal_error -> normalize_reason_category_from_category(category)
      normalized -> normalized
    end
  end

  defp normalize_reason_category(%{"outer_category" => outer_category})
       when is_binary(outer_category),
       do: normalize_error_category(outer_category)

  defp normalize_reason_category(%{"category" => category}) when is_binary(category),
    do: normalize_reason_category_from_category(category)

  defp normalize_reason_category(%{category: category}) when is_binary(category),
    do: normalize_reason_category_from_category(category)

  defp normalize_reason_category(_reason), do: :internal_error

  defp normalize_reason_category_from_category("dual_render_mismatch"),
    do: :safe_tokenization_incompatible_template

  defp normalize_reason_category_from_category(category)
       when category in @tokenizer_incompatibility_categories,
       do: :safe_tokenization_incompatible_tokenizer

  defp normalize_reason_category_from_category(category),
    do: normalize_error_category(category)

  defp normalize_error_category("invalid_input"), do: :invalid_input
  defp normalize_error_category("missing_assets"), do: :missing_assets
  defp normalize_error_category("unsupported_tokenizer"), do: :unsupported_tokenizer

  defp normalize_error_category("safe_tokenization_incompatible_tokenizer"),
    do: :safe_tokenization_incompatible_tokenizer

  defp normalize_error_category("safe_tokenization_incompatible_template"),
    do: :safe_tokenization_incompatible_template

  defp normalize_error_category("safe_tokenization_marker_collision"),
    do: :safe_tokenization_marker_collision

  defp normalize_error_category("safe_tokenization_catalog_hash_mismatch"),
    do: :safe_tokenization_catalog_hash_mismatch

  defp normalize_error_category("dual_render_mismatch"),
    do: :safe_tokenization_incompatible_template

  defp normalize_error_category(_category), do: :internal_error

  defp validate_input_item_roles(input_items) when is_list(input_items) do
    input_items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case fetch_string_field(item, [:role, "role"], "role", index) do
        {:ok, role} ->
          if MapSet.member?(@supported_message_roles, role) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              {:invalid_input, "input_items[#{index}].role is unsupported: #{inspect(role)}"}}}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp validate_input_item_roles(input_items) do
    {:error,
     {:invalid_input,
      "canonical request input_items must be a list of role/content maps, got: #{inspect(input_items)}"}}
  end

  defp build_prompt_lines(input_items) when is_list(input_items) do
    input_items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, lines} ->
      with {:ok, role} <- fetch_string_field(item, [:role, "role"], "role", index),
           {:ok, content} <-
             normalize_content(fetch_first_present(item, [:content, "content"]), index) do
        {:cont, {:ok, lines ++ [role <> " " <> content]}}
      else
        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp build_prompt_lines(input_items) do
    {:error,
     {:invalid_input,
      "canonical request input_items must be a list of role/content maps, got: #{inspect(input_items)}"}}
  end

  defp fetch_string_field(item, keys, field_name, index) when is_map(item) do
    value = fetch_first_present(item, keys)

    case value do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error,
         {:invalid_input,
          "input_items[#{index}] must include non-empty #{field_name}, got: #{inspect(item)}"}}
    end
  end

  defp fetch_string_field(item, _keys, _field_name, index) do
    {:error, {:invalid_input, "input_items[#{index}] must be maps, got: #{inspect(item)}"}}
  end

  defp fetch_first_present(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce_while(keys, nil, fn key, _acc ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp normalize_content(content, _index) when is_binary(content), do: {:ok, content}

  defp normalize_content(content_parts, index) when is_list(content_parts) do
    content_parts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {part, part_index}, {:ok, texts} ->
      case normalize_content_part(part, index, part_index) do
        {:ok, text} -> {:cont, {:ok, texts ++ [text]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.join(texts, "")}
      error -> error
    end
  end

  defp normalize_content(content, index) do
    {:error,
     {:invalid_input,
      "input_items[#{index}].content must be a string or text-part list, got: #{inspect(content)}"}}
  end

  defp normalize_content_part(part, index, part_index) do
    case part do
      %{} ->
        type = fetch_first_present(part, [:type, "type"])
        text = fetch_first_present(part, [:text, "text"])

        case {type, text} do
          {"text", text} when is_binary(text) -> {:ok, text}
          _other -> invalid_text_part_error(part, index, part_index)
        end

      _other ->
        invalid_text_part_error(part, index, part_index)
    end
  end

  defp invalid_text_part_error(part, index, part_index) do
    {:error,
     {:invalid_input,
      "input_items[#{index}].content[#{part_index}] must be text parts, got: #{inspect(part)}"}}
  end

  defp fake_token_count(rendered_prompt) do
    rendered_prompt
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end

  defp tool_calling_enabled?(%CanonicalRequest{tooling: tooling}) do
    ToolingValidation.effective_tool_calling?(tooling.tools, tooling.tool_choice)
  end
end
