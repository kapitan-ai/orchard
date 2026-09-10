defmodule Orchard.Models.SafeTokenizationPreflight do
  @moduledoc """
  Runs bundle-build/import-time safe-tokenization compatibility preflight.
  """

  alias Orchard.Tokenizer.{HelperOutputCollector, HelperRequestTransport}

  @contract_version 3
  @default_timeout_ms 60_000
  @default_max_stdout_bytes 1_048_576
  @event_prefix [:orchard, :tokenizer, :bundle_preflight]
  @reason_key_atoms %{
    "category" => :category,
    "literal" => :literal,
    "leaf_class" => :leaf_class,
    "sentinel_index" => :sentinel_index,
    "first_diff_offset" => :first_diff_offset
  }
  @reason_keys Map.keys(@reason_key_atoms)
  @segmented_tokenizer_kinds ~w(huggingface_tokenizer_json tokenizer_json)
  @tokenizer_incompatibility_categories ~w(per_codepoint_decode_mismatch reserved_id_persists reserved_id_set_overlap empty_literal)
  @all_incompatibility_categories @tokenizer_incompatibility_categories ++
                                    ["dual_render_mismatch"]

  @doc false
  @spec incompatibility_reason_category_sets() :: %{
          all: [String.t()],
          tokenizer: [String.t()],
          template: [String.t()]
        }
  # Contract tests inspect preflight-owned enum strings without promoting this to product API.
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
          path: :helper_preflight_verdict,
          reason_key_encoding: :string,
          categories: %{String.t() => map()}
        }
  # Contract tests inspect preflight-owned verdict rules without making product API.
  # Success-result boolean guard keeps tokenizer-category template compatibility true.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def incompatibility_reason_rules do
    %{
      path: :helper_preflight_verdict,
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

  @type preflight_input :: %{
          required(:bundle_dir) => Path.t(),
          required(:tokenizer_kind) => String.t(),
          required(:tokenizer_path) => Path.t(),
          required(:tokenizer_config_path) => Path.t() | nil,
          required(:chat_template_path) => Path.t(),
          required(:control_tokens) => [String.t()],
          required(:catalog_sha256) => String.t()
        }

  @type incompatibility_reason :: %{
          required(:category) => String.t(),
          optional(:literal) => String.t(),
          optional(:leaf_class) => String.t(),
          optional(:sentinel_index) => non_neg_integer(),
          optional(:first_diff_offset) => non_neg_integer()
        }

  @type preflight_result ::
          :disabled
          | {:compatible, %{template_compatible: boolean()}}
          | {:incompatible,
             %{
               compatible: false,
               template_compatible: boolean(),
               incompatibility_reason: incompatibility_reason()
             }}
          | {:error, {:safe_tokenization_preflight_failed, term()}}

  @type tool_capability_preflight_input :: %{
          required(:tokenizer_config_path) => Path.t(),
          required(:chat_template_path) => Path.t(),
          required(:tool_parser_type) => String.t()
        }

  @type tool_capability_preflight_result ::
          {:ok,
           %{
             parser_recognized: boolean(),
             definition_rendered: boolean(),
             history_rendered: boolean()
           }}
          | {:error, {:tool_capability_preflight_failed, term()}}

  @spec run(preflight_input()) :: preflight_result()
  def run(input) when is_map(input) do
    cond do
      not enabled?() ->
        :disabled

      not preflightable?(input) ->
        :disabled

      true ->
        do_run(input)
    end
  end

  def run(_input), do: :disabled

  @doc false
  @spec run_tool_capability(tool_capability_preflight_input()) ::
          tool_capability_preflight_result()
  # Contract tests and BundleBuilder use this internal helper seam without making it product API.
  # credo:disable-for-next-line ExSlop.Check.Readability.DocFalseOnPublicFunction
  def run_tool_capability(input) when is_map(input) do
    cond do
      not enabled?() ->
        tool_capability_error(:disabled)

      not tool_capability_preflightable?(input) ->
        tool_capability_error(:ineligible)

      true ->
        do_run_tool_capability(input)
    end
  end

  def run_tool_capability(_input), do: tool_capability_error(:ineligible)

  @spec merge_into_safe_tokenization_map(map(), preflight_result()) :: map()
  def merge_into_safe_tokenization_map(safe_tokenization, {:compatible, result})
      when is_map(safe_tokenization) do
    safe_tokenization
    |> Map.delete("incompatibility_reason")
    |> Map.put("compatible", true)
    |> Map.put("template_compatible", Map.fetch!(result, :template_compatible))
  end

  def merge_into_safe_tokenization_map(safe_tokenization, {:incompatible, result})
      when is_map(safe_tokenization) do
    safe_tokenization
    |> Map.delete("incompatibility_reason")
    |> Map.put("compatible", false)
    |> Map.put("template_compatible", Map.fetch!(result, :template_compatible))
    |> Map.put(
      "incompatibility_reason",
      stringify_reason(Map.fetch!(result, :incompatibility_reason))
    )
  end

  def merge_into_safe_tokenization_map(safe_tokenization, _result), do: safe_tokenization

  defp do_run_tool_capability(input) do
    with {:ok, executable_path} <- resolve_executable(Orchard.Inference.tokenizer_executable()),
         payload = build_tool_capability_payload(input),
         {:ok, response_json, exit_status} <-
           run_helper(executable_path, Jason.encode!(payload), timeout_ms()),
         {:ok, response} <- decode_response(response_json) do
      classify_tool_capability_response(response, exit_status)
    else
      {:error, reason} -> tool_capability_error(reason)
    end
  end

  defp tool_capability_preflightable?(%{
         tokenizer_config_path: tokenizer_config_path,
         chat_template_path: chat_template_path,
         tool_parser_type: tool_parser_type
       }) do
    non_empty_binary?(tokenizer_config_path) and non_empty_binary?(chat_template_path) and
      non_empty_binary?(tool_parser_type)
  end

  defp tool_capability_preflightable?(_input), do: false

  defp build_tool_capability_payload(input) do
    %{
      "contract_version" => @contract_version,
      "command" => "preflight_tool_capability",
      "assets" => %{
        "tokenizer_config_path" => Map.fetch!(input, :tokenizer_config_path),
        "chat_template_path" => Map.fetch!(input, :chat_template_path)
      },
      "options" => %{"tool_parser_type" => Map.fetch!(input, :tool_parser_type)}
    }
  end

  defp classify_tool_capability_response(
         %{
           "contract_version" => @contract_version,
           "ok" => true,
           "result" => %{
             "parser_recognized" => parser_recognized,
             "definition_rendered" => definition_rendered,
             "history_rendered" => history_rendered
           }
         },
         0
       )
       when is_boolean(parser_recognized) and is_boolean(definition_rendered) and
              is_boolean(history_rendered) do
    {:ok,
     %{
       parser_recognized: parser_recognized,
       definition_rendered: definition_rendered,
       history_rendered: history_rendered
     }}
  end

  defp classify_tool_capability_response(_response, _exit_status),
    do: tool_capability_error(:invalid_response)

  defp tool_capability_error(reason), do: {:error, {:tool_capability_preflight_failed, reason}}

  defp do_run(input) do
    metadata = telemetry_metadata(input)
    start_time = System.monotonic_time()
    emit(:start, %{system_time: System.system_time()}, metadata)

    result =
      with {:ok, executable_path} <- resolve_executable(Orchard.Inference.tokenizer_executable()),
           payload = build_payload(input),
           {:ok, response_json, exit_status} <-
             run_helper(executable_path, Jason.encode!(payload), timeout_ms()),
           {:ok, response} <- decode_response(response_json) do
        classify_response(response, exit_status)
      else
        {:error, reason} -> error_result(reason)
      end

    duration_ms =
      System.monotonic_time()
      |> Kernel.-(start_time)
      |> System.convert_time_unit(:native, :millisecond)

    case result do
      {:error, {:safe_tokenization_preflight_failed, reason}} ->
        emit(:error, %{duration_ms: duration_ms}, Map.put(metadata, :reason, reason))

      _success ->
        emit(:stop, %{duration_ms: duration_ms}, Map.put(metadata, :result, result_tag(result)))
    end

    result
  end

  defp enabled? do
    Application.get_env(:orchard_controller, :bundle_build_eager_preflight_enabled, true)
  end

  defp timeout_ms do
    Application.get_env(
      :orchard_controller,
      :bundle_build_preflight_timeout_ms,
      @default_timeout_ms
    )
  end

  defp max_stdout_bytes do
    case Application.get_env(:orchard_controller, :bundle_build_preflight_max_stdout_bytes) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_stdout_bytes
    end
  end

  defp preflightable?(%{
         tokenizer_kind: tokenizer_kind,
         tokenizer_path: tokenizer_path,
         tokenizer_config_path: tokenizer_config_path,
         chat_template_path: chat_template_path,
         control_tokens: control_tokens,
         catalog_sha256: catalog_sha256
       }) do
    tokenizer_kind in @segmented_tokenizer_kinds and non_empty_binary?(tokenizer_path) and
      non_empty_binary?(tokenizer_config_path) and non_empty_binary?(chat_template_path) and
      is_list(control_tokens) and Enum.all?(control_tokens, &is_binary/1) and
      non_empty_binary?(catalog_sha256)
  end

  defp preflightable?(_input), do: false

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

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

  defp build_payload(input) do
    assets = %{
      "tokenizer_kind" => Map.fetch!(input, :tokenizer_kind),
      "tokenizer_path" => Map.fetch!(input, :tokenizer_path),
      "tokenizer_config_path" => Map.get(input, :tokenizer_config_path),
      "chat_template_path" => Map.fetch!(input, :chat_template_path)
    }

    %{
      "contract_version" => @contract_version,
      "command" => "preflight_safe_tokenization",
      "assets" => assets,
      "safe_tokenization" => %{
        "control_tokens" => Map.fetch!(input, :control_tokens),
        "catalog_sha256" => Map.fetch!(input, :catalog_sha256)
      }
    }
  end

  defp run_helper(executable_path, request_json, timeout_ms)
       when is_binary(executable_path) and is_binary(request_json) and is_integer(timeout_ms) and
              timeout_ms > 0 do
    HelperRequestTransport.with_secure_request_file(
      "orchard-tokenizer-preflight",
      request_json,
      fn request_path ->
        case open_helper_port(executable_path, request_path) do
          {:ok, port} ->
            HelperOutputCollector.collect(port, timeout_ms, max_stdout_bytes())

          {:error, reason} ->
            {:error, reason}
        end
      end
    )
  end

  defp open_helper_port(executable_path, request_path) do
    {:ok,
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
            "orchard-tokenizer-preflight",
            executable_path,
            request_path
          ]}
       ]
     )}
  rescue
    _error in [ArgumentError] -> {:error, :unavailable}
  end

  defp decode_response(response_json) when is_binary(response_json) do
    case Jason.decode(response_json) do
      {:ok, response} when is_map(response) -> {:ok, response}
      _other -> {:error, :invalid_response}
    end
  end

  defp classify_response(
         %{"contract_version" => @contract_version, "ok" => true, "result" => result},
         0
       )
       when is_map(result) do
    normalize_success_result(result)
  end

  defp classify_response(
         %{
           "contract_version" => @contract_version,
           "ok" => false,
           "error" => %{"category" => category, "message" => message} = error
         },
         _exit_status
       )
       when is_binary(category) and is_binary(message) do
    error_result({:helper_error, normalize_helper_error(error)})
  end

  defp classify_response(_response, _exit_status), do: error_result(:invalid_response)

  defp normalize_success_result(
         %{
           "compatible" => true,
           "template_compatible" => true
         } = result
       ) do
    if is_nil(Map.get(result, "incompatibility_reason")) do
      {:compatible, %{template_compatible: true}}
    else
      error_result(:invalid_response)
    end
  end

  defp normalize_success_result(%{
         "compatible" => false,
         "template_compatible" => template_compatible,
         "incompatibility_reason" => reason
       })
       when is_boolean(template_compatible) and is_map(reason) do
    case validate_reason(reason, template_compatible) do
      :ok ->
        {:incompatible,
         %{
           compatible: false,
           template_compatible: template_compatible,
           incompatibility_reason: atomize_reason(reason)
         }}

      :error ->
        error_result(:invalid_response)
    end
  end

  defp normalize_success_result(_result), do: error_result(:invalid_response)

  defp validate_reason(%{"category" => category} = reason, template_compatible)
       when category in @tokenizer_incompatibility_categories do
    if template_compatible != false and valid_tokenizer_reason?(reason, category) do
      :ok
    else
      :error
    end
  end

  defp validate_reason(%{"category" => "dual_render_mismatch"} = reason, template_compatible) do
    if template_compatible == false and valid_dual_render_reason?(reason) do
      :ok
    else
      :error
    end
  end

  defp validate_reason(%{"category" => category}, _template_compatible)
       when category in @all_incompatibility_categories,
       do: :error

  defp validate_reason(_reason, _template_compatible), do: :error

  defp valid_tokenizer_reason?(reason, "empty_literal"),
    do: Map.get(reason, "literal") == ""

  defp valid_tokenizer_reason?(reason, _category) do
    literal = Map.get(reason, "literal")
    is_binary(literal) and literal != ""
  end

  defp valid_dual_render_reason?(reason) do
    non_empty_binary?(Map.get(reason, "leaf_class")) and
      non_negative_integer?(Map.get(reason, "sentinel_index")) and
      non_negative_integer?(Map.get(reason, "first_diff_offset"))
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp error_result(reason), do: {:error, {:safe_tokenization_preflight_failed, reason}}

  defp normalize_helper_error(error) do
    %{
      category: Map.fetch!(error, "category"),
      message: Map.fetch!(error, "message")
    }
    |> maybe_put_details(Map.get(error, "details"))
  end

  defp maybe_put_details(error, details) when is_map(details),
    do: Map.put(error, :details, details)

  defp maybe_put_details(error, _details), do: error

  defp atomize_reason(reason) do
    Enum.reduce(@reason_keys, %{}, fn string_key, acc ->
      atom_key = Map.fetch!(@reason_key_atoms, string_key)

      case Map.fetch(reason, string_key) do
        {:ok, value} -> Map.put(acc, atom_key, value)
        :error -> acc
      end
    end)
  end

  defp stringify_reason(reason) do
    for {key, value} <- reason, into: %{} do
      {Atom.to_string(key), value}
    end
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute(@event_prefix ++ [event], measurements, metadata)
  end

  defp telemetry_metadata(input) do
    %{
      bundle_dir: Map.get(input, :bundle_dir),
      tokenizer_kind: Map.get(input, :tokenizer_kind)
    }
  end

  defp result_tag({:compatible, _result}), do: :compatible
  defp result_tag({:incompatible, _result}), do: :incompatible
end
