defmodule Orchard.Requests.CapturePolicy do
  @moduledoc """
  Applies the tenant request-body capture policy at persistence boundaries.
  """

  @preview_limit 512
  @capture_modes [:none, :metadata, :full]
  @event_integer_keys ~w(attempt attempt_index sequence turn_index)
  @step_integer_keys ~w(attempt turn_index)
  @step_types ~w(inference_turn tool_call tool_execution)
  @boundaries ~w(post_observation pre_side_effect)
  @result_integer_keys ~w(http_status input_tokens output_tokens)
  @finish_reasons ~w(cancelled content_filter error length stop tool_calls)
  @tool_execution_statuses %{
    "request_step.failed" => :failed,
    "request_step.cancelled" => :cancelled,
    "request_step.timed_out" => :timed_out,
    "request_step.indeterminate" => :indeterminate
  }
  @indeterminate_reasons ~w(
    cancel_ack_missing
    controller_restarted
    executor_unreachable
    result_not_observed
    timeout_after_start
  )
  @stable_error_codes ~w(
    acquisition_failed
    artifact_not_found
    cancelled
    checksum_mismatch
    cluster_busy
    deadline_exceeded
    insufficient_memory
    internal_error
    load_timeout
    manifest_not_found
    mlx_backend_unavailable
    model_busy
    model_invalid
    node_timeout
    node_unavailable
    orchestration_error
    queue_full
    queue_timeout
    request_cancelled
    request_caller_disconnect
    request_client_disconnect
    request_controller_restarted
    request_interrupted
    request_timeout
    resource_exhausted
    rpc_error
    rpc_resource_exhausted
    rpc_unavailable
    runtime_incompatible
    runtime_unavailable
    timed_out
    timeout
    tool_execution_cancelled
    tool_execution_failed
    tool_execution_indeterminate_cancel_ack_missing
    tool_execution_indeterminate_controller_restarted
    tool_execution_indeterminate_executor_unreachable
    tool_execution_indeterminate_result_not_observed
    tool_execution_indeterminate_timeout_after_start
    tool_execution_timed_out
    tool_failed
    tool_timeout
    tooling_not_supported
    unexpected_placement_state
    worker_down
    worker_unavailable
    worker_unloaded
  )
  @schedule_boolean_keys ~w(
    cache_affinity_enabled
    cache_affinity_hint_available
    cache_affinity_selected_match
    fallback_used?
    memory_admission_enabled
    memory_headroom_ok?
    queueing_enabled
    selected_prefix_cache_enabled
    selected_prefix_cache_fingerprint_match
    selected_prefix_cache_score_resident_fingerprint_match
    selected_prefix_cache_warmth_indicator
  )
  @schedule_numeric_keys ~w(
    candidate_count
    contract_version
    model_load_timeout_ms
    queue_wait_ms
    request_timeout_ms
    selected_prefix_cache_entry_count
    selected_prefix_cache_evictions
    selected_prefix_cache_fingerprint_count
    selected_prefix_cache_hits
    selected_prefix_cache_misses
    selected_prefix_cache_score_session_started_unix_ms
    selected_prefix_cache_session_started_unix_ms
    selected_prefix_cache_stores
    selected_prefix_cache_total_bytes
  )
  @schedule_enums %{
    "cache_affinity_source" => ~w(recent_completed_request),
    "memory_admission_tier" =>
      ~w(headroom_available headroom_ok headroom_tight headroom_unavailable headroom_unknown),
    "queue_result" =>
      ~w(immediate interrupted_before_dispatch interrupted_controller_restarted queue_full queue_timeout queued),
    "queue_wait_reason" =>
      ~w(live_node_capacity placement_capacity requested_model_path_capacity),
    "selected_cache_tier" => ~w(hint_not_selected no_hint warm_prefix),
    "selected_prefix_cache_implementation" => ~w(disabled kv unknown),
    "selected_prefix_cache_score_source" => ~w(score_prefix_cache_rpc),
    "selected_prefix_cache_score_status_code" =>
      ~w(disabled error invalid_request model_not_loaded ok timeout unavailable unsupported_version),
    "selected_prefix_cache_score_tier" =>
      ~w(no_match recent_fingerprint_only resident_fingerprint unknown),
    "selected_prefix_cache_status_code" => ~w(disabled error invalid_status ok unavailable),
    "selected_tier" => ~w(cold loaded),
    "selection_tier" => ~w(cold loaded),
    "strategy" => ~w(multi_node single_node)
  }
  @safe_score_component_keys ~w(
    cache_affinity_bonus
    capable_worker_bonus
    health_bonus
    live_fingerprint_bonus
    load_bonus
    memory_headroom_bonus
    pool_bonus
    rank_base
    residency_bonus
  )

  @type mode :: :none | :metadata | :full

  alias Orchard.ClusterManagement.ReasonCodes
  alias Orchard.Inference.ToolExecutionOutcome
  alias Orchard.Requests.RequestStepEvent

  @spec resolve(mode(), boolean()) :: mode()
  def resolve(mode, true) when mode in @capture_modes, do: mode
  def resolve(:full, false), do: :metadata
  def resolve(mode, false) when mode in [:none, :metadata], do: mode

  @doc """
  Returns the most restrictive capture mode.

  Persistence boundaries use it when a request carries no resolvable capture
  mode so unresolved rows are sanitized fail-closed rather than stored verbatim.
  """
  @spec strictest_mode() :: mode()
  def strictest_mode, do: :none

  @spec normalize_mode(term()) :: {:ok, mode()} | :error
  def normalize_mode(mode) when mode in @capture_modes, do: {:ok, mode}

  def normalize_mode(mode) when is_binary(mode) do
    case Enum.find(@capture_modes, &(Atom.to_string(&1) == mode)) do
      nil -> :error
      normalized -> {:ok, normalized}
    end
  end

  def normalize_mode(_mode), do: :error

  @spec create_attrs(mode(), map()) :: map()
  def create_attrs(:full, attrs), do: put_key(attrs, :request_shape, request_shape(:full, attrs))

  def create_attrs(:none, attrs) do
    attrs
    |> put_key(:canonical_request, nil)
    |> put_key(:request_payload, nil)
    |> put_key(:request_shape, nil)
    |> update_existing(:sampling_params, &sanitize_sampling/1)
    |> update_existing(:response_format, &sanitize_response_format/1)
    |> then(&terminal_attrs(:none, &1))
    |> sanitize_initial_schedule(:none)
  end

  def create_attrs(:metadata, attrs) do
    attrs
    |> put_key(:canonical_request, nil)
    |> put_key(:request_payload, nil)
    |> put_key(:request_shape, request_shape(:metadata, attrs))
    |> update_existing(:sampling_params, &sanitize_sampling/1)
    |> update_existing(:response_format, &sanitize_response_format/1)
    |> then(&terminal_attrs(:metadata, &1))
    |> sanitize_initial_schedule(:metadata)
  end

  @spec terminal_attrs(mode(), map()) :: map()
  def terminal_attrs(:full, attrs) do
    attrs
    |> delete_key(:response_preview_source)
    |> put_response_hash()
    |> update_existing(:response_preview, &bounded_preview/1)
  end

  def terminal_attrs(mode, attrs) when mode in [:none, :metadata] do
    attrs
    |> put_response_hash()
    |> put_restricted_preview(mode)
    |> delete_key(:response_preview_source)
    |> put_key(:response_payload, nil)
    |> update_existing(:error_code, &stable_error_code/1)
    |> put_key(:error_message, nil)
  end

  @spec event_attrs(mode(), map()) :: map()
  def event_attrs(:full, attrs), do: attrs

  def event_attrs(mode, attrs) when mode in [:none, :metadata] do
    event_type = fetch_value(attrs, :event_type)

    cond do
      Map.has_key?(attrs, :payload) ->
        Map.update!(attrs, :payload, &sanitize_event_payload(&1, event_type))

      Map.has_key?(attrs, "payload") ->
        Map.update!(attrs, "payload", &sanitize_event_payload(&1, event_type))

      true ->
        attrs
    end
  end

  @spec schedule_attrs(mode(), map()) :: map()
  def schedule_attrs(:full, attrs), do: attrs

  def schedule_attrs(mode, attrs) when mode in [:none, :metadata],
    do: schedule_attrs(mode, attrs, %{})

  @spec schedule_attrs(mode(), map(), map()) :: map()
  def schedule_attrs(:full, attrs, _approved), do: attrs

  def schedule_attrs(mode, attrs, approved) when mode in [:none, :metadata] do
    %{}
    |> put_typed_values(attrs, ~w(cache_affinity_candidate_count), &non_negative_integer?/1)
    |> put_typed_values(attrs, @schedule_numeric_keys, &number?/1)
    |> put_typed_values(attrs, @schedule_boolean_keys, &is_boolean/1)
    |> put_enum_values(attrs, @schedule_enums)
    |> put_uuid_value(attrs, "node_id")
    |> put_uuid_value(attrs, "selected_node_id")
    |> put_uuid_value(attrs, "queue_grant_id")
    |> put_datetime_value(attrs, "queue_granted_at")
    |> put_datetime_value(attrs, "queued_at")
    |> put_cache_affinity_key(attrs)
    |> put_exact_value(attrs, "queue_key", Map.get(approved, :requested_model))
    |> put_safe_candidates(attrs, "scored_candidates", :scheduler_rejection)
    |> put_safe_candidates(attrs, "rejected_candidates", :scheduler_rejection)
    |> put_safe_candidates(attrs, "skipped_candidates", :scheduler_skip)
  end

  @spec content_columns() :: %{request_events: [atom()], requests: [atom()]}
  def content_columns do
    %{
      request_events: [:payload],
      requests: [
        :canonical_request,
        :request_shape,
        :request_payload,
        :response_payload,
        :response_preview,
        :sampling_params,
        :response_format,
        :scheduler_decision,
        :error_message
      ]
    }
  end

  @doc false
  @spec stable_error_codes() :: [String.t()]
  def stable_error_codes, do: @stable_error_codes

  @spec safe_columns() :: %{request_events: [atom()], requests: [atom()]}
  def safe_columns do
    %{
      request_events: [:event_type, :id, :occurred_at, :request_id, :seq, :state],
      requests: [
        :api_key_id,
        :body_hash,
        :completed_at,
        :endpoint,
        :error_code,
        :first_token_at,
        :http_status,
        :id,
        :idempotency_key,
        :input_tokens,
        :inserted_at,
        :model_id,
        :node_id,
        :output_tokens,
        :payload_capture_mode,
        :principal_type,
        :public_id,
        :requested_model,
        :reserved_output_tokens,
        :response_hash,
        :retry_of_request_id,
        :service_account_id,
        :state,
        :stream,
        :tenant_id,
        :timeout_at,
        :updated_at,
        :worker_id
      ]
    }
  end

  defp request_shape(mode, attrs) do
    canonical = fetch_value(attrs, :canonical_request) || %{}

    rendered_prompt =
      fetch_value(canonical, :rendered_prompt) ||
        fetch_value(fetch_value(attrs, :request_payload) || %{}, :prompt)

    %{
      "capture_mode" => capture_mode_string(mode),
      "input_item_count" => input_item_count(canonical),
      "preview" => nil,
      "rendered_prompt" => content_shape(rendered_prompt)
    }
  end

  defp capture_mode_string(mode), do: Atom.to_string(mode)

  defp input_item_count(canonical) do
    (fetch_value(canonical, :input_items) || fetch_value(canonical, :input))
    |> case do
      value when is_list(value) -> length(value)
      nil -> 0
      _value -> 1
    end
  end

  defp content_shape(nil), do: nil

  defp content_shape(content) do
    encoded = encode_content(content)

    %{
      "bytes" => byte_size(encoded),
      "graphemes" => String.length(encoded),
      "sha256" => sha256_hex(encoded)
    }
  end

  defp encode_content(content) when is_binary(content), do: content
  defp encode_content(content), do: Jason.encode!(content)

  defp sanitize_sampling(nil), do: nil

  defp sanitize_sampling(params) when is_map(params) do
    params
    |> take_keys(~w(max_output_tokens seed temperature top_p))
    |> Map.put("stop_count", stop_count(params))
  end

  defp sanitize_response_format(nil), do: nil

  defp sanitize_response_format(format) when is_map(format) do
    take_keys(format, ~w(type))
  end

  defp update_existing(attrs, key, fun) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.update!(attrs, key, fun)
      Map.has_key?(attrs, string_key) -> Map.update!(attrs, string_key, fun)
      true -> attrs
    end
  end

  defp has_key?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp put_key(attrs, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      string_keyed?(attrs) -> Map.put(attrs, string_key, value)
      true -> Map.put(attrs, key, value)
    end
  end

  defp delete_key(attrs, key), do: attrs |> Map.delete(key) |> Map.delete(Atom.to_string(key))

  defp string_keyed?(attrs), do: attrs != %{} and Enum.all?(Map.keys(attrs), &is_binary/1)

  defp put_response_hash(attrs) do
    case fetch_value(attrs, :response_payload) do
      nil -> attrs
      payload -> put_key(attrs, :response_hash, payload |> encode_content() |> sha256())
    end
  end

  defp put_restricted_preview(attrs, mode) do
    if has_key?(attrs, :response_preview) do
      preview =
        case mode do
          :none -> nil
          :metadata -> metadata_preview(attrs)
        end

      put_key(attrs, :response_preview, preview)
    else
      attrs
    end
  end

  defp metadata_preview(attrs) do
    case normalize_enum(fetch_value(attrs, :response_preview_source)) do
      "assistant_text" -> metadata_preview_value(fetch_value(attrs, :response_preview))
      _source -> nil
    end
  end

  defp metadata_preview_value(nil), do: nil

  defp metadata_preview_value(preview) when is_binary(preview) do
    if codepoint_length(preview) > @preview_limit do
      truncate_preview(preview)
    end
  end

  defp metadata_preview_value(_preview), do: nil

  defp stable_error_code(nil), do: nil

  defp stable_error_code(code) when code in @stable_error_codes, do: code

  defp stable_error_code(_code), do: "internal_error"

  defp bounded_preview(nil), do: nil

  defp bounded_preview(preview) when is_binary(preview) do
    if codepoint_length(preview) > @preview_limit do
      truncate_preview(preview)
    else
      preview
    end
  end

  defp truncate_preview(preview) do
    {graphemes, _count} =
      preview
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn grapheme, {acc, count} ->
        grapheme_size = codepoint_length(grapheme)

        if count + grapheme_size <= @preview_limit - 1 do
          {:cont, {[grapheme | acc], count + grapheme_size}}
        else
          {:halt, {acc, count}}
        end
      end)

    graphemes
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Kernel.<>("…")
  end

  defp codepoint_length(value), do: value |> String.codepoints() |> length()

  defp sanitize_event_payload(payload, event_type) when is_map(payload) do
    if RequestStepEvent.request_step_event_type?(event_type) do
      sanitize_step_event_payload(payload, event_type)
    else
      %{}
      |> put_typed_values(payload, @event_integer_keys, &non_negative_integer?/1)
      |> put_enum_value(payload, "boundary", @boundaries)
      |> put_enum_value(payload, "step_type", @step_types)
      |> put_step_identity(payload)
      |> maybe_put_sanitized_result(payload)
    end
  end

  defp sanitize_event_payload(_payload, _event_type), do: %{}

  defp sanitize_step_event_payload(payload, event_type) do
    sanitized =
      %{}
      |> put_typed_values(payload, @step_integer_keys, &positive_integer?/1)
      |> put_enum_value(payload, "boundary", @boundaries)
      |> put_enum_value(payload, "step_type", @step_types)
      |> put_step_identity(payload)

    Map.put(sanitized, "result", step_result(sanitized, payload, event_type))
  end

  defp step_result(sanitized, payload, event_type) do
    result = fetch_value(payload, :result)

    case Map.get(sanitized, "step_type") do
      "tool_execution" -> tool_execution_result(result, event_type)
      _step_type -> inference_step_result(result)
    end
  end

  defp inference_step_result(result) when is_map(result) do
    %{}
    |> put_typed_values(result, @result_integer_keys, &non_negative_integer?/1)
    |> put_finish_reason_evidence(result)
    |> put_typed_value(
      "error_code",
      stable_error_code(fetch_value(result, :error_code)),
      &is_binary/1
    )
  end

  defp inference_step_result(_result), do: %{"result_invalid" => true}

  defp put_finish_reason_evidence(sanitized, result) do
    if has_key?(result, :finish_reason) do
      case normalize_enum(fetch_value(result, :finish_reason)) do
        finish_reason when finish_reason in @finish_reasons ->
          Map.put(sanitized, "finish_reason", finish_reason)

        _invalid ->
          Map.put(sanitized, "finish_reason_invalid", true)
      end
    else
      sanitized
    end
  end

  defp tool_execution_result(result, event_type) when is_map(result) do
    case Map.fetch(@tool_execution_statuses, event_type) do
      {:ok, status} -> terminal_tool_execution_result(result, status)
      :error -> %{}
    end
  end

  defp tool_execution_result(_result, _event_type), do: %{}

  defp terminal_tool_execution_result(result, status) do
    %{"status" => status}
    |> put_typed_value("error_code", stable_step_error_code(result), &is_binary/1)
    |> put_enum_value(result, "indeterminate_reason", indeterminate_reasons(status))
    |> ToolExecutionOutcome.request_step_result()
    |> case do
      {:ok, safe_result} -> safe_result
      {:error, _reason} -> %{}
    end
  end

  defp indeterminate_reasons(:indeterminate), do: @indeterminate_reasons
  defp indeterminate_reasons(_status), do: []

  defp stable_step_error_code(result) do
    case fetch_value(result, :error_code) do
      code when code in @stable_error_codes -> code
      _code -> nil
    end
  end

  defp put_safe_candidates(sanitized, attrs, key, vocabulary) do
    case fetch_value(attrs, key) do
      candidates when is_list(candidates) ->
        Map.put(sanitized, key, Enum.map(candidates, &sanitize_candidate(&1, vocabulary)))

      _candidates ->
        sanitized
    end
  end

  defp sanitize_candidate(candidate, vocabulary) when is_map(candidate) do
    %{}
    |> put_typed_values(candidate, ~w(score), &number?/1)
    |> put_typed_values(candidate, ~w(eligible), &is_boolean/1)
    |> put_enum_value(candidate, "tier", ~w(cold loaded))
    |> put_uuid_value(candidate, "node_id")
    |> put_reason_codes(candidate, vocabulary)
    |> maybe_put_score_components(candidate)
  end

  defp sanitize_candidate(_candidate, _vocabulary), do: %{}

  defp put_step_identity(sanitized, payload) do
    case Map.get(sanitized, "step_type") do
      "inference_turn" -> put_inference_turn_identity(sanitized, payload)
      "tool_call" -> put_tool_call_identity(sanitized, payload)
      "tool_execution" -> put_tool_execution_identity(sanitized, payload)
      _step_type -> sanitized
    end
  end

  defp put_inference_turn_identity(sanitized, payload) do
    turn_index = fetch_value(payload, :turn_index)
    attempt = fetch_value(payload, :attempt)

    if positive_integer?(turn_index) and positive_integer?(attempt) do
      Map.put(sanitized, "step_id", RequestStepEvent.inference_turn_step_id(turn_index, attempt))
    else
      sanitized
    end
  end

  defp put_tool_call_identity(sanitized, payload) do
    turn_index = fetch_value(payload, :turn_index)
    call_id = fetch_value(payload, :call_id)

    if positive_integer?(turn_index) and is_binary(call_id) do
      put_tool_identity(sanitized, "tool_call", turn_index, call_id, nil)
    else
      sanitized
    end
  end

  defp put_tool_execution_identity(sanitized, payload) do
    turn_index = fetch_value(payload, :turn_index)
    attempt = fetch_value(payload, :attempt)
    call_id = fetch_value(payload, :call_id)

    if positive_integer?(turn_index) and positive_integer?(attempt) and is_binary(call_id) do
      put_tool_identity(sanitized, "tool_execution", turn_index, call_id, attempt)
    else
      sanitized
    end
  end

  defp put_tool_identity(sanitized, step_type, turn_index, call_id, attempt) do
    safe_call_id = "sha256:" <> sha256_hex(call_id)
    parent_step_id = RequestStepEvent.tool_call_step_id(turn_index, safe_call_id)

    step_id =
      case step_type do
        "tool_call" ->
          parent_step_id

        "tool_execution" ->
          RequestStepEvent.tool_execution_step_id(turn_index, safe_call_id, attempt)
      end

    sanitized
    |> Map.put("call_id", safe_call_id)
    |> Map.put("step_id", step_id)
    |> Map.put(
      "parent_step_id",
      if(step_type == "tool_call",
        do: RequestStepEvent.inference_turn_step_id(turn_index, 1),
        else: parent_step_id
      )
    )
  end

  defp maybe_put_score_components(sanitized, candidate) do
    case fetch_value(candidate, :components) do
      components when is_map(components) ->
        Map.put(sanitized, "components", sanitize_score_components(components))

      _components ->
        sanitized
    end
  end

  defp sanitize_score_components(components) do
    components
    |> take_keys(@safe_score_component_keys)
    |> Map.filter(fn {_key, value} -> is_number(value) end)
  end

  defp maybe_put_sanitized_result(sanitized, payload) do
    case fetch_value(payload, :result) do
      result when is_map(result) ->
        Map.put(sanitized, "result", inference_step_result(result))

      _result ->
        sanitized
    end
  end

  defp put_typed_values(sanitized, source, keys, predicate) do
    Enum.reduce(keys, sanitized, fn key, acc ->
      put_typed_value(acc, key, fetch_value(source, key), predicate)
    end)
  end

  defp put_typed_value(sanitized, _key, nil, _predicate), do: sanitized

  defp put_typed_value(sanitized, key, value, predicate) do
    if predicate.(value), do: Map.put(sanitized, key, value), else: sanitized
  end

  defp put_enum_values(sanitized, source, enums) do
    Enum.reduce(enums, sanitized, fn {key, allowed}, acc ->
      put_enum_value(acc, source, key, allowed)
    end)
  end

  defp put_enum_value(sanitized, source, key, allowed) do
    case normalize_enum(fetch_value(source, key)) do
      value when is_binary(value) ->
        if value in allowed, do: Map.put(sanitized, key, value), else: sanitized

      nil ->
        sanitized
    end
  end

  defp put_uuid_value(sanitized, source, key) do
    case Ecto.UUID.cast(fetch_value(source, key)) do
      {:ok, uuid} -> Map.put(sanitized, key, uuid)
      :error -> sanitized
    end
  end

  defp put_datetime_value(sanitized, source, key) do
    case fetch_value(source, key) do
      %DateTime{} = datetime ->
        Map.put(sanitized, key, DateTime.to_iso8601(datetime))

      value when is_binary(value) ->
        put_iso8601_value(sanitized, key, value)

      _value ->
        sanitized
    end
  end

  defp put_iso8601_value(sanitized, key, value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> Map.put(sanitized, key, DateTime.to_iso8601(datetime))
      _result -> sanitized
    end
  end

  defp put_exact_value(sanitized, _source, _key, nil), do: sanitized

  defp put_exact_value(sanitized, source, key, expected) do
    if fetch_value(source, key) == expected do
      Map.put(sanitized, key, expected)
    else
      sanitized
    end
  end

  defp put_cache_affinity_key(sanitized, source) do
    case fetch_value(source, :cache_affinity_key) do
      "hmac-sha256:" <> digest = value when byte_size(digest) == 64 ->
        if String.match?(digest, ~r/\A[0-9a-f]{64}\z/) do
          Map.put(sanitized, "cache_affinity_key", value)
        else
          sanitized
        end

      _value ->
        sanitized
    end
  end

  defp sanitize_initial_schedule(attrs, mode) do
    if has_key?(attrs, :scheduler_decision) do
      case fetch_value(attrs, :scheduler_decision) do
        decision when is_map(decision) ->
          approved = %{requested_model: fetch_value(attrs, :requested_model)}
          put_key(attrs, :scheduler_decision, schedule_attrs(mode, decision, approved))

        _decision ->
          put_key(attrs, :scheduler_decision, nil)
      end
    else
      attrs
    end
  end

  defp put_reason_codes(sanitized, source, vocabulary) do
    case ReasonCodes.validate_codes(vocabulary, fetch_value(source, :reason_codes)) do
      {:ok, codes} -> Map.put(sanitized, "reason_codes", codes)
      {:error, _reason} -> sanitized
    end
  end

  defp normalize_enum(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalize_enum(value) when is_binary(value), do: value
  defp normalize_enum(_value), do: nil

  defp number?(value), do: is_integer(value) or is_float(value)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp stop_count(params) do
    case fetch_value(params, :stop) do
      values when is_list(values) -> length(values)
      nil -> 0
      _value -> 1
    end
  end

  defp take_keys(map, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_value(map, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp fetch_value(map, key) when is_atom(key) do
    fetch_first(map, key, Atom.to_string(key))
  end

  defp fetch_value(map, key) when is_binary(key) do
    fetch_first(map, key, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp fetch_first(map, primary, secondary) do
    case Map.fetch(map, primary) do
      {:ok, value} -> value
      :error -> Map.get(map, secondary)
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content)
  defp sha256_hex(content), do: content |> sha256() |> Base.encode16(case: :lower)
end
