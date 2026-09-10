defmodule Orchard.Models.ManifestParser do
  @moduledoc """
  Parses a model bundle's `manifest.json` into an `Orchard.ModelManifest`.

  Bridges from JSON string-keyed maps to the atom-keyed domain struct,
  rejecting unknown top-level keys and normalizing nested structures
  before delegating to `ModelManifest.new/1` for domain validation.

  The manifest schema stays closed so an N-1 Worker Runtime can load it, which
  is why tool-capability evidence arrives from the bundle's optional
  `tool_capability_evidence.json` sidecar instead. Per `SPEC.md` §6.4, a
  manifest `tool_calling` capability is admitted only alongside a `declared`
  sidecar and is dropped otherwise.
  """

  alias Orchard.ModelManifest

  @manifest_filename "manifest.json"
  @tool_capability_evidence_filename "tool_capability_evidence.json"

  @top_level_key_map %{
    "model_id" => :model_id,
    "version" => :version,
    "format" => :format,
    "artifact_layout" => :artifact_layout,
    "entrypoint" => :entrypoint,
    "sha256" => :sha256,
    "size_bytes" => :size_bytes,
    "resident_memory_bytes" => :resident_memory_bytes,
    "kv_cache_bytes_per_token" => :kv_cache_bytes_per_token,
    "prefill_workspace_bytes_per_token" => :prefill_workspace_bytes_per_token,
    "max_context_tokens" => :max_context_tokens,
    "capabilities" => :capabilities,
    "tokenizer" => :tokenizer,
    "chat_template" => :chat_template,
    "safe_tokenization" => :safe_tokenization,
    "runtime_requirements" => :runtime_requirements
  }

  @tokenizer_key_map %{
    "kind" => :kind,
    "path" => :path,
    "config_path" => :config_path
  }

  @chat_template_key_map %{
    "path" => :path,
    "sha256" => :sha256
  }

  @runtime_requirements_key_map %{
    "adapter" => :adapter,
    "min_agent_capability" => :min_agent_capability
  }

  @capability_evidence_key_map %{
    "tool_calling" => :tool_calling
  }

  @tool_calling_evidence_key_map %{
    "source_repository" => :source_repository,
    "source_revision" => :source_revision,
    "base_model_refs" => :base_model_refs,
    "tokenizer_config_sha256" => :tokenizer_config_sha256,
    "chat_template_sha256" => :chat_template_sha256,
    "tool_parser_type" => :tool_parser_type,
    "preflight" => :preflight,
    "result" => :result,
    "runtime_qualification" => :runtime_qualification
  }

  @tool_calling_preflight_key_map %{
    "parser_recognized" => :parser_recognized,
    "definition_rendered" => :definition_rendered,
    "history_rendered" => :history_rendered
  }

  @safe_tokenization_key_map %{
    "control_tokens" => :control_tokens,
    "extra_control_token_strings" => :extra_control_token_strings,
    "catalog_sha256" => :catalog_sha256,
    "catalog_source" => :catalog_source,
    "compatible" => :compatible,
    "template_compatible" => :template_compatible,
    "incompatibility_reason" => :incompatibility_reason
  }

  @catalog_source_key_map %{
    "added_tokens_count" => :added_tokens_count,
    "config_singletons_count" => :config_singletons_count,
    "additional_special_tokens_count" => :additional_special_tokens_count,
    "chat_template_literals_count" => :chat_template_literals_count,
    "wrapper_tool_markers_count" => :wrapper_tool_markers_count,
    "extra_count" => :extra_count
  }

  @required_catalog_source_keys Map.values(@catalog_source_key_map)

  @incompatibility_reason_key_map %{
    "category" => :category,
    "literal" => :literal,
    "leaf_class" => :leaf_class,
    "sentinel_index" => :sentinel_index,
    "first_diff_offset" => :first_diff_offset
  }

  @tokenizer_incompatibility_categories ~w(per_codepoint_decode_mismatch reserved_id_persists reserved_id_set_overlap empty_literal)
  @all_incompatibility_categories @tokenizer_incompatibility_categories ++
                                    ["dual_render_mismatch"]

  @doc false
  @spec incompatibility_reason_category_sets() :: %{
          all: [String.t()],
          tokenizer: [String.t()],
          template: [String.t()]
        }
  # Contract tests inspect parser-owned enum strings without promoting this to product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def incompatibility_reason_category_sets do
    %{
      all: Enum.sort(@all_incompatibility_categories),
      tokenizer: Enum.sort(@tokenizer_incompatibility_categories),
      template:
        Enum.sort(@all_incompatibility_categories -- @tokenizer_incompatibility_categories)
    }
  end

  @doc false
  @spec incompatibility_reason_rules() :: %{
          path: :manifest_verdict,
          reason_key_encoding: :atom,
          categories: %{String.t() => map()}
        }
  # Contract tests inspect parser-owned verdict rules without making product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def incompatibility_reason_rules do
    %{
      path: :manifest_verdict,
      reason_key_encoding: :atom,
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
          template_compatible: :not_false
        },
        "per_codepoint_decode_mismatch" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :not_false
        },
        "reserved_id_persists" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :not_false
        },
        "reserved_id_set_overlap" => %{
          required: ["category", "literal"],
          literal: :non_empty_binary,
          template_compatible: :not_false
        }
      }
    }
  end

  @doc """
  Reads and parses `manifest.json` plus the optional
  `tool_capability_evidence.json` sidecar from a bundle directory.

  Returns `{:ok, manifest}` or `{:error, reason}` where reason is
  `{:manifest_not_found, path}`, `{:json_decode, message}`,
  `{:capability_evidence_read, message}`, or `{:validation, message}`.
  """
  @spec parse_from_bundle(String.t()) :: {:ok, ModelManifest.t()} | {:error, term()}
  def parse_from_bundle(bundle_path) when is_binary(bundle_path) do
    manifest_path = Path.join(bundle_path, @manifest_filename)

    case File.read(manifest_path) do
      {:ok, json} ->
        with {:ok, manifest_map} <- decode_manifest_json(json),
             {:ok, capability_evidence} <- read_capability_evidence(bundle_path) do
          atomize_and_build(manifest_map, capability_evidence)
        end

      {:error, :enoent} ->
        {:error, {:manifest_not_found, manifest_path}}

      {:error, reason} ->
        {:error, {:manifest_read, "failed to read #{manifest_path}: #{inspect(reason)}"}}
    end
  end

  @doc """
  Parses a JSON string into an `Orchard.ModelManifest`.

  Returns `{:ok, manifest}` or `{:error, reason}`. There is no bundle
  directory to read a capability-evidence sidecar from, so a `tool_calling`
  capability in the JSON is always dropped.
  """
  @spec parse_json(String.t()) :: {:ok, ModelManifest.t()} | {:error, term()}
  def parse_json(json) when is_binary(json) do
    with {:ok, manifest_map} <- decode_manifest_json(json) do
      atomize_and_build(manifest_map, nil)
    end
  end

  defp decode_manifest_json(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error, {:json_decode, "manifest must be a JSON object"}}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, {:json_decode, Exception.message(err)}}
    end
  end

  defp read_capability_evidence(bundle_path) do
    evidence_path = Path.join(bundle_path, @tool_capability_evidence_filename)

    case File.read(evidence_path) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, evidence} when is_map(evidence) ->
            {:ok, evidence}

          {:ok, _other} ->
            {:error, {:validation, "tool capability evidence must be a JSON object"}}

          {:error, %Jason.DecodeError{} = err} ->
            {:error,
             {:validation, "invalid tool capability evidence JSON: #{Exception.message(err)}"}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error,
         {:capability_evidence_read, "failed to read #{evidence_path}: #{inspect(reason)}"}}
    end
  end

  @doc false
  @spec schema_keys() :: map()
  # Contract tests inspect parser-owned schema keys without promoting this to product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def schema_keys do
    %{
      top_level_keys: Map.keys(@top_level_key_map) |> Enum.sort(),
      nested_keys: %{
        tokenizer: Map.keys(@tokenizer_key_map) |> Enum.sort(),
        chat_template: Map.keys(@chat_template_key_map) |> Enum.sort(),
        runtime_requirements: Map.keys(@runtime_requirements_key_map) |> Enum.sort(),
        safe_tokenization: Map.keys(@safe_tokenization_key_map) |> Enum.sort(),
        safe_tokenization_catalog_source: Map.keys(@catalog_source_key_map) |> Enum.sort(),
        safe_tokenization_incompatibility_reason:
          Map.keys(@incompatibility_reason_key_map) |> Enum.sort()
      }
    }
  end

  defp atomize_and_build(string_map, capability_evidence) do
    with :ok <- validate_legacy_sha256(string_map),
         {:ok, atom_map} <- atomize_top_level(string_map),
         {:ok, atom_map} <- atomize_nested(atom_map, :tokenizer, @tokenizer_key_map),
         {:ok, atom_map} <- atomize_nested(atom_map, :chat_template, @chat_template_key_map),
         {:ok, atom_map} <- atomize_safe_tokenization(atom_map),
         {:ok, capability_evidence} <- atomize_capability_evidence(capability_evidence),
         atom_map <- maybe_put_capability_evidence(atom_map, capability_evidence),
         {:ok, atom_map} <-
           atomize_nested(atom_map, :runtime_requirements, @runtime_requirements_key_map),
         :ok <- validate_safe_tokenization(atom_map),
         {:ok, atom_map} <- admit_tool_capability(atom_map) do
      build_manifest(atom_map)
    end
  end

  defp validate_legacy_sha256(string_map) do
    case Map.fetch(string_map, "sha256") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      {:ok, value} ->
        {:error,
         {:validation,
          "sha256 must be omitted or contain a non-empty string, got: #{inspect(value)}"}}
    end
  end

  defp atomize_top_level(string_map) do
    unknown = Map.keys(string_map) -- Map.keys(@top_level_key_map)

    if unknown != [] do
      {:error, {:validation, "unknown manifest keys: #{inspect(unknown)}"}}
    else
      atom_map =
        for {k, v} <- string_map, into: %{} do
          {Map.fetch!(@top_level_key_map, k), v}
        end

      {:ok, atom_map}
    end
  end

  defp atomize_nested(atom_map, key, key_map) do
    case Map.get(atom_map, key) do
      nil ->
        {:ok, atom_map}

      nested when is_map(nested) ->
        atomize_nested_map(atom_map, key, nested, key_map)

      _other ->
        {:ok, atom_map}
    end
  end

  defp atomize_nested_map(atom_map, key, nested, key_map) do
    unknown = Map.keys(nested) -- Map.keys(key_map)

    if unknown != [] do
      {:error, {:validation, "unknown keys in #{inspect(key)}: #{inspect(unknown)}"}}
    else
      atomized = for {k, v} <- nested, into: %{}, do: {Map.fetch!(key_map, k), v}
      {:ok, Map.put(atom_map, key, atomized)}
    end
  end

  defp atomize_safe_tokenization(atom_map) do
    with {:ok, atom_map} <-
           atomize_nested(atom_map, :safe_tokenization, @safe_tokenization_key_map) do
      atomize_safe_tokenization_nested(atom_map)
    end
  end

  defp atomize_safe_tokenization_nested(%{safe_tokenization: safe} = atom_map)
       when is_map(safe) do
    derived_fields = %{
      compatible_declared?: Map.has_key?(safe, :compatible),
      template_compatible_declared?: Map.has_key?(safe, :template_compatible),
      preflight_compatible_declared?:
        Map.get(safe, :compatible) == true and Map.get(safe, :template_compatible) == true
    }

    atom_map = update_in(atom_map, [:safe_tokenization], &Map.merge(&1, derived_fields))

    with {:ok, atom_map} <- atomize_catalog_source(atom_map) do
      atomize_incompatibility_reason(atom_map)
    end
  end

  defp atomize_safe_tokenization_nested(atom_map), do: {:ok, atom_map}

  defp atomize_capability_evidence(nil), do: {:ok, nil}

  defp atomize_capability_evidence(evidence) when is_map(evidence) do
    with {:ok, atom_map} <-
           atomize_nested(
             %{capability_evidence: evidence},
             :capability_evidence,
             @capability_evidence_key_map
           ),
         {:ok, atom_map} <- atomize_capability_evidence_tool_calling(atom_map),
         {:ok, atom_map} <- atomize_capability_evidence_preflight(atom_map) do
      {:ok, Map.fetch!(atom_map, :capability_evidence)}
    end
  end

  defp atomize_capability_evidence_tool_calling(%{capability_evidence: evidence} = atom_map)
       when is_map(evidence) do
    case Map.get(evidence, :tool_calling) do
      tool_calling when is_map(tool_calling) ->
        with {:ok, evidence} <-
               atomize_nested_map(
                 evidence,
                 :tool_calling,
                 tool_calling,
                 @tool_calling_evidence_key_map
               ) do
          {:ok, Map.put(atom_map, :capability_evidence, evidence)}
        end

      _other ->
        {:ok, atom_map}
    end
  end

  defp atomize_capability_evidence_tool_calling(atom_map), do: {:ok, atom_map}

  defp atomize_capability_evidence_preflight(
         %{capability_evidence: %{tool_calling: tool_calling}} = atom_map
       )
       when is_map(tool_calling) do
    case Map.get(tool_calling, :preflight) do
      preflight when is_map(preflight) ->
        with {:ok, tool_calling} <-
               atomize_nested_map(
                 tool_calling,
                 :preflight,
                 preflight,
                 @tool_calling_preflight_key_map
               ) do
          {:ok, put_in(atom_map, [:capability_evidence, :tool_calling], tool_calling)}
        end

      _other ->
        {:ok, atom_map}
    end
  end

  defp atomize_capability_evidence_preflight(atom_map), do: {:ok, atom_map}

  defp maybe_put_capability_evidence(atom_map, nil), do: atom_map

  defp maybe_put_capability_evidence(atom_map, capability_evidence),
    do: Map.put(atom_map, :capability_evidence, capability_evidence)

  defp admit_tool_capability(
         %{capability_evidence: %{tool_calling: %{result: "declared"}}} = atom_map
       ),
       do: {:ok, atom_map}

  defp admit_tool_capability(%{capabilities: capabilities} = atom_map)
       when is_list(capabilities) do
    {:ok, Map.put(atom_map, :capabilities, Enum.reject(capabilities, &(&1 == "tool_calling")))}
  end

  defp admit_tool_capability(atom_map), do: {:ok, atom_map}

  defp atomize_catalog_source(atom_map) do
    case get_in(atom_map, [:safe_tokenization, :catalog_source]) do
      nil ->
        {:ok, atom_map}

      catalog_source when is_map(catalog_source) ->
        with {:ok, %{safe: atomized}} <-
               atomize_nested_map(
                 %{safe: catalog_source},
                 :safe,
                 catalog_source,
                 @catalog_source_key_map
               ) do
          {:ok, put_in(atom_map, [:safe_tokenization, :catalog_source], atomized)}
        end

      _other ->
        {:ok, atom_map}
    end
  end

  defp atomize_incompatibility_reason(atom_map) do
    case get_in(atom_map, [:safe_tokenization, :incompatibility_reason]) do
      nil ->
        {:ok, atom_map}

      reason when is_map(reason) ->
        with {:ok, %{reason: atomized}} <-
               atomize_nested_map(
                 %{reason: reason},
                 :reason,
                 reason,
                 @incompatibility_reason_key_map
               ) do
          {:ok, put_in(atom_map, [:safe_tokenization, :incompatibility_reason], atomized)}
        end

      _other ->
        {:ok, atom_map}
    end
  end

  defp validate_safe_tokenization(atom_map) do
    case Map.get(atom_map, :safe_tokenization) do
      nil -> :ok
      safe -> do_validate_safe_tokenization(safe)
    end
  end

  defp do_validate_safe_tokenization(safe) when not is_map(safe),
    do: {:error, {:validation, "safe_tokenization must be an object when present"}}

  defp do_validate_safe_tokenization(safe) do
    with :ok <- validate_required_sorted_string_list(safe, :control_tokens),
         :ok <- validate_optional_sorted_string_list(safe, :extra_control_token_strings),
         :ok <- validate_catalog_sha256(safe),
         :ok <- validate_catalog_source(safe),
         :ok <- validate_extra_control_tokens(safe),
         :ok <- validate_optional_boolean(safe, :compatible),
         :ok <- validate_optional_boolean(safe, :template_compatible) do
      validate_compatibility_cohesion(safe)
    end
  end

  defp validate_required_sorted_string_list(map, key) do
    case Map.fetch(map, key) do
      :error -> {:error, {:validation, "#{key} is required when safe_tokenization is present"}}
      {:ok, value} -> validate_sorted_string_list(key, value)
    end
  end

  defp validate_optional_sorted_string_list(map, key) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} -> validate_sorted_string_list(key, value)
    end
  end

  defp validate_sorted_string_list(key, value) when is_list(value) do
    cond do
      not Enum.all?(value, &is_binary/1) ->
        {:error, {:validation, "#{key} must contain only strings"}}

      Enum.any?(value, &(&1 == "")) ->
        {:error, {:validation, "#{key} must contain only non-empty strings"}}

      Enum.uniq(value) != value ->
        {:error, {:validation, "#{key} must be deduped"}}

      Enum.sort(value) != value ->
        {:error, {:validation, "#{key} must be lexicographically sorted"}}

      true ->
        :ok
    end
  end

  defp validate_sorted_string_list(key, _value),
    do: {:error, {:validation, "#{key} must be a list"}}

  defp validate_catalog_sha256(%{control_tokens: control_tokens} = safe) do
    case Map.fetch(safe, :catalog_sha256) do
      :error ->
        {:error, {:validation, "catalog_sha256 is required when safe_tokenization is present"}}

      {:ok, sha} when is_binary(sha) ->
        validate_catalog_sha256_binary(sha, control_tokens)

      {:ok, _other} ->
        {:error, {:validation, "catalog_sha256 must be 64-character lowercase hex"}}
    end
  end

  defp validate_catalog_sha256_binary(sha, control_tokens) do
    if String.match?(sha, ~r/\A[0-9a-f]{64}\z/) do
      validate_catalog_sha256_match(sha, control_tokens)
    else
      {:error, {:validation, "catalog_sha256 must be 64-character lowercase hex"}}
    end
  end

  defp validate_catalog_sha256_match(sha, control_tokens) do
    if sha == hash_catalog(control_tokens) do
      :ok
    else
      {:error, {:validation, "catalog_sha256 does not match control_tokens"}}
    end
  end

  defp validate_catalog_source(%{catalog_source: catalog_source}) when is_map(catalog_source) do
    missing = @required_catalog_source_keys -- Map.keys(catalog_source)

    if missing != [] do
      {:error, {:validation, "catalog_source missing required keys: #{inspect(missing)}"}}
    else
      validate_catalog_source_counts(catalog_source)
    end
  end

  defp validate_catalog_source(%{catalog_source: nil}),
    do: {:error, {:validation, "catalog_source is required when safe_tokenization is present"}}

  defp validate_catalog_source(%{catalog_source: _other}),
    do: {:error, {:validation, "catalog_source must be an object"}}

  defp validate_catalog_source(%{}),
    do: {:error, {:validation, "catalog_source is required when safe_tokenization is present"}}

  defp validate_extra_control_tokens(safe) do
    extras = Map.get(safe, :extra_control_token_strings, [])
    control_tokens = Map.fetch!(safe, :control_tokens)
    extra_count = get_in(safe, [:catalog_source, :extra_count])

    cond do
      extras -- control_tokens != [] ->
        {:error,
         {:validation, "extra_control_token_strings entries must also appear in control_tokens"}}

      extra_count != length(extras) ->
        {:error,
         {:validation,
          "catalog_source.extra_count must equal length(extra_control_token_strings || [])"}}

      true ->
        :ok
    end
  end

  defp validate_optional_boolean(map, key) do
    case Map.fetch(map, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, {:validation, "#{key} must be boolean when present"}}
    end
  end

  defp validate_compatibility_cohesion(safe) do
    context = compatibility_context(safe)

    with :ok <- validate_incompatibility_presence(context),
         :ok <- validate_template_compatibility_gate(context) do
      validate_incompatibility_reason(context.incompatibility_reason, context.template_compatible)
    end
  end

  defp validate_catalog_source_counts(catalog_source) do
    Enum.reduce_while(@required_catalog_source_keys, :ok, fn key, :ok ->
      if valid_catalog_source_count?(catalog_source, key) do
        {:cont, :ok}
      else
        {:halt, {:error, {:validation, "catalog_source.#{key} must be a non-negative integer"}}}
      end
    end)
  end

  defp valid_catalog_source_count?(catalog_source, key) do
    value = Map.fetch!(catalog_source, key)
    is_integer(value) and value >= 0
  end

  defp compatibility_context(safe) do
    %{
      compatible: Map.get(safe, :compatible, true),
      compatible_present?: Map.has_key?(safe, :compatible),
      template_compatible: Map.get(safe, :template_compatible),
      incompatibility_reason: Map.get(safe, :incompatibility_reason)
    }
  end

  defp validate_incompatibility_presence(%{
         compatible: false,
         incompatibility_reason: nil
       }) do
    {:error, {:validation, "compatible=false requires incompatibility_reason"}}
  end

  defp validate_incompatibility_presence(%{
         compatible_present?: false,
         incompatibility_reason: reason
       })
       when not is_nil(reason) do
    {:error, {:validation, "incompatibility_reason is not allowed when compatible is absent"}}
  end

  defp validate_incompatibility_presence(%{
         compatible: true,
         incompatibility_reason: reason
       })
       when not is_nil(reason) do
    {:error, {:validation, "incompatibility_reason is not allowed unless compatible=false"}}
  end

  defp validate_incompatibility_presence(_context), do: :ok

  defp validate_template_compatibility_gate(%{
         template_compatible: false,
         compatible: compatible
       })
       when compatible != false do
    {:error, {:validation, "template_compatible=false requires compatible=false"}}
  end

  defp validate_template_compatibility_gate(_context), do: :ok

  defp validate_incompatibility_reason(nil, _template_compatible), do: :ok

  defp validate_incompatibility_reason(reason, template_compatible) when is_map(reason) do
    category = Map.get(reason, :category)

    cond do
      category not in @all_incompatibility_categories ->
        {:error, {:validation, "incompatibility_reason.category is invalid"}}

      category in @tokenizer_incompatibility_categories ->
        validate_tokenizer_reason(reason, template_compatible)

      category == "dual_render_mismatch" ->
        validate_dual_render_reason(reason, template_compatible)
    end
  end

  defp validate_incompatibility_reason(_reason, _template_compatible),
    do: {:error, {:validation, "incompatibility_reason must be an object"}}

  defp validate_tokenizer_reason(%{category: "empty_literal"} = reason, template_compatible) do
    case Map.get(reason, :literal) do
      "" ->
        validate_tokenizer_template_compatible(template_compatible)

      _other ->
        {:error, {:validation, "empty_literal requires literal=\"\""}}
    end
  end

  defp validate_tokenizer_reason(reason, template_compatible) do
    case Map.get(reason, :literal) do
      literal when is_binary(literal) and literal != "" ->
        validate_tokenizer_template_compatible(template_compatible)

      _other ->
        {:error, {:validation, "tokenizer incompatibility categories require non-empty literal"}}
    end
  end

  defp validate_tokenizer_template_compatible(false) do
    {:error,
     {:validation,
      "template_compatible=false is only valid with incompatibility_reason.category=dual_render_mismatch"}}
  end

  defp validate_tokenizer_template_compatible(_template_compatible), do: :ok

  defp validate_dual_render_reason(reason, template_compatible) do
    cond do
      template_compatible != false ->
        {:error, {:validation, "dual_render_mismatch requires template_compatible=false"}}

      not (is_binary(Map.get(reason, :leaf_class)) and Map.get(reason, :leaf_class) != "") ->
        {:error, {:validation, "dual_render_mismatch requires leaf_class"}}

      not (is_integer(Map.get(reason, :sentinel_index)) and Map.get(reason, :sentinel_index) >= 0) ->
        {:error, {:validation, "dual_render_mismatch requires non-negative sentinel_index"}}

      not (is_integer(Map.get(reason, :first_diff_offset)) and
               Map.get(reason, :first_diff_offset) >= 0) ->
        {:error, {:validation, "dual_render_mismatch requires non-negative first_diff_offset"}}

      true ->
        :ok
    end
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp build_manifest(atom_map) do
    {:ok, ModelManifest.new(atom_map)}
  rescue
    e in ArgumentError ->
      {:error, {:validation, Exception.message(e)}}
  end
end
