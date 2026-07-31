defmodule Orchard.Requests.CapturePolicy do
  @moduledoc """
  Applies the tenant request-body capture policy at persistence boundaries.
  """

  @preview_limit 512
  @capture_modes [:none, :metadata, :full]
  @safe_result_keys ~w(
    error_code
    finish_reason
    http_status
    indeterminate_reason
    input_tokens
    output_tokens
    remote_request_id
    remote_response_id
  )
  @safe_schedule_keys ~w(
    candidate_count
    capacity_source
    contract_version
    fallback_used?
    memory_admission_enabled
    memory_admission_tier
    memory_headroom_ok?
    model_load_timeout_ms
    node_id
    object
    queue_grant_id
    queue_granted_at
    queue_key
    queue_result
    queue_wait_ms
    queue_wait_reason
    queued_at
    queueing_enabled
    request_id
    request_timeout_ms
    selected_node_id
    selected_cache_tier
    selected_tier
    selection_tier
    strategy
  )
  @safe_prefix_cache_schedule_keys ~w(
    selected_prefix_cache_enabled
    selected_prefix_cache_entry_count
    selected_prefix_cache_evictions
    selected_prefix_cache_fingerprint_count
    selected_prefix_cache_fingerprint_match
    selected_prefix_cache_hits
    selected_prefix_cache_implementation
    selected_prefix_cache_misses
    selected_prefix_cache_score_source
    selected_prefix_cache_score_status_code
    selected_prefix_cache_score_tier
    selected_prefix_cache_session_started_unix_ms
    selected_prefix_cache_status_code
    selected_prefix_cache_stores
    selected_prefix_cache_total_bytes
    selected_prefix_cache_warmth_indicator
  )
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

  @spec resolve(mode(), boolean()) :: mode()
  def resolve(mode, true) when mode in @capture_modes, do: mode
  def resolve(:full, false), do: :metadata
  def resolve(mode, false) when mode in [:none, :metadata], do: mode

  @spec create_attrs(mode(), map()) :: map()
  def create_attrs(:full, attrs), do: Map.put(attrs, :request_shape, request_shape(:full, attrs))

  def create_attrs(:none, attrs) do
    attrs
    |> Map.put(:canonical_request, nil)
    |> Map.put(:request_payload, nil)
    |> Map.put(:request_shape, nil)
    |> update_existing(:sampling_params, &sanitize_sampling/1)
    |> update_existing(:response_format, &sanitize_response_format/1)
    |> then(&terminal_attrs(:none, &1))
  end

  def create_attrs(:metadata, attrs) do
    attrs
    |> Map.put(:canonical_request, nil)
    |> Map.put(:request_payload, nil)
    |> Map.put(:request_shape, request_shape(:metadata, attrs))
    |> update_existing(:sampling_params, &sanitize_sampling/1)
    |> update_existing(:response_format, &sanitize_response_format/1)
    |> then(&terminal_attrs(:metadata, &1))
  end

  @spec terminal_attrs(mode(), map()) :: map()
  def terminal_attrs(:full, attrs) do
    attrs
    |> put_response_hash()
    |> Map.update(:response_preview, nil, &bounded_preview/1)
  end

  def terminal_attrs(mode, attrs) when mode in [:none, :metadata] do
    preview =
      case mode do
        :none -> nil
        :metadata -> metadata_preview(Map.get(attrs, :response_preview))
      end

    attrs
    |> put_response_hash()
    |> Map.put(:response_payload, nil)
    |> Map.put(:response_preview, preview)
    |> Map.put(:error_message, nil)
  end

  @spec event_attrs(mode(), map()) :: map()
  def event_attrs(:full, attrs), do: attrs

  def event_attrs(mode, attrs) when mode in [:none, :metadata] do
    cond do
      Map.has_key?(attrs, :payload) -> Map.update!(attrs, :payload, &sanitize_event_payload/1)
      Map.has_key?(attrs, "payload") -> Map.update!(attrs, "payload", &sanitize_event_payload/1)
      true -> attrs
    end
  end

  @spec schedule_attrs(mode(), map()) :: map()
  def schedule_attrs(:full, attrs), do: attrs

  def schedule_attrs(mode, attrs) when mode in [:none, :metadata] do
    attrs
    |> take_keys(@safe_schedule_keys ++ @safe_prefix_cache_schedule_keys)
    |> sanitize_scalar_map()
    |> put_safe_candidates(attrs, "scored_candidates")
    |> put_safe_candidates(attrs, "rejected_candidates")
    |> put_safe_candidates(attrs, "skipped_candidates")
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
    canonical = Map.get(attrs, :canonical_request) || %{}

    rendered_prompt =
      fetch_value(canonical, :rendered_prompt) ||
        fetch_value(Map.get(attrs, :request_payload) || %{}, :prompt)

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

  defp put_response_hash(attrs) do
    case Map.get(attrs, :response_payload) do
      nil -> attrs
      payload -> Map.put(attrs, :response_hash, payload |> encode_content() |> sha256())
    end
  end

  defp metadata_preview(nil), do: nil

  defp metadata_preview(preview) when is_binary(preview) do
    if codepoint_length(preview) > @preview_limit do
      truncate_preview(preview)
    end
  end

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

  defp sanitize_event_payload(payload) when is_map(payload) do
    payload
    |> take_keys(
      ~w(attempt attempt_index boundary kind phase request_step_id sequence state step_id step_type turn_index type) ++
        ~w(call_id model_id model_version parent_step_id tool_name)
    )
    |> maybe_put_sanitized_result(payload)
  end

  defp sanitize_event_payload(_payload), do: %{}

  defp put_safe_candidates(sanitized, attrs, key) do
    case fetch_value(attrs, key) do
      candidates when is_list(candidates) ->
        Map.put(sanitized, key, Enum.map(candidates, &sanitize_candidate/1))

      _candidates ->
        sanitized
    end
  end

  defp sanitize_candidate(candidate) when is_map(candidate) do
    candidate
    |> take_keys(~w(eligible node_id reason_codes score target_ref tier))
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if scalar?(value) or (key == "reason_codes" and safe_scalar_list?(value)) do
        Map.put(acc, key, bound_scalar(value))
      else
        acc
      end
    end)
    |> maybe_put_score_components(candidate)
  end

  defp sanitize_candidate(_candidate), do: %{}

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

  defp sanitize_scalar_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      if scalar?(value), do: Map.put(acc, key, bound_scalar(value)), else: acc
    end)
  end

  defp bound_scalar(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp bound_scalar(value) when is_boolean(value) or is_nil(value), do: value
  defp bound_scalar(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp bound_scalar(value) when is_list(value), do: Enum.map(value, &bound_scalar/1)
  defp bound_scalar(value), do: value

  defp scalar?(value),
    do: is_binary(value) or is_number(value) or is_atom(value)

  defp safe_scalar_list?(values) when is_list(values), do: Enum.all?(values, &scalar?/1)
  defp safe_scalar_list?(_values), do: false

  defp maybe_put_sanitized_result(sanitized, payload) do
    case fetch_value(payload, :result) do
      result when is_map(result) ->
        Map.put(sanitized, "result", take_keys(result, @safe_result_keys))

      _result ->
        sanitized
    end
  end

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
