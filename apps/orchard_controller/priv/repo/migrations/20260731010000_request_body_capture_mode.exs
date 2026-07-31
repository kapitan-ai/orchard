defmodule Orchard.Repo.Migrations.RequestBodyCaptureMode do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add(:request_body_capture_mode, :payload_capture_mode,
        null: false,
        default: "metadata"
      )
    end

    alter table(:requests) do
      add(:request_shape, :map)
      add(:response_hash, :binary)
    end

    execute("""
    UPDATE requests
    SET response_hash = digest(convert_to(response_payload::text, 'UTF8'), 'sha256')
    WHERE response_hash IS NULL
      AND response_payload IS NOT NULL
    """)

    execute("""
    UPDATE requests
    SET body_hash =
          CASE
            WHEN body_hash IS NULL AND canonical_request IS NOT NULL
            THEN digest(convert_to(canonical_request::text, 'UTF8'), 'sha256')
            WHEN body_hash IS NULL AND request_payload IS NOT NULL
            THEN digest(convert_to(request_payload::text, 'UTF8'), 'sha256')
            ELSE body_hash
          END,
        response_hash =
          CASE
            WHEN response_payload IS NOT NULL
            THEN digest(convert_to(response_payload::text, 'UTF8'), 'sha256')
            ELSE response_hash
          END,
        canonical_request = NULL,
        request_payload = NULL,
        response_payload = NULL,
        response_preview = NULL,
        error_message = NULL,
        sampling_params = jsonb_strip_nulls(
          jsonb_build_object(
            'temperature', sampling_params -> 'temperature',
            'top_p', sampling_params -> 'top_p',
            'max_output_tokens', sampling_params -> 'max_output_tokens',
            'seed', sampling_params -> 'seed',
            'stop_count',
              CASE
                WHEN jsonb_typeof(sampling_params -> 'stop') = 'array'
                THEN jsonb_array_length(sampling_params -> 'stop')
                WHEN sampling_params ? 'stop' THEN 1
                ELSE 0
              END
          )
        ),
        response_format = jsonb_strip_nulls(
          jsonb_build_object('type', response_format -> 'type')
        ),
        scheduler_decision =
          CASE
            WHEN scheduler_decision IS NULL THEN NULL
            WHEN jsonb_typeof(scheduler_decision) = 'object' THEN (
              SELECT COALESCE(jsonb_object_agg(entry.key, entry.value), '{}'::jsonb)
              FROM jsonb_each(scheduler_decision) AS entry
              WHERE entry.key = ANY (
                ARRAY[
                  'candidate_count',
                  'capacity_source',
                  'contract_version',
                  'fallback_used?',
                  'memory_admission_enabled',
                  'memory_admission_tier',
                  'memory_headroom_ok?',
                  'model_load_timeout_ms',
                  'node_id',
                  'object',
                  'queue_grant_id',
                  'queue_granted_at',
                  'queue_key',
                  'queue_result',
                  'queue_wait_ms',
                  'queue_wait_reason',
                  'queued_at',
                  'queueing_enabled',
                  'request_id',
                  'request_timeout_ms',
                  'selected_node_id',
                  'selected_cache_tier',
                  'selected_tier',
                  'selection_tier',
                  'selected_prefix_cache_enabled',
                  'selected_prefix_cache_entry_count',
                  'selected_prefix_cache_evictions',
                  'selected_prefix_cache_fingerprint_count',
                  'selected_prefix_cache_fingerprint_match',
                  'selected_prefix_cache_hits',
                  'selected_prefix_cache_implementation',
                  'selected_prefix_cache_misses',
                  'selected_prefix_cache_score_source',
                  'selected_prefix_cache_score_status_code',
                  'selected_prefix_cache_score_tier',
                  'selected_prefix_cache_session_started_unix_ms',
                  'selected_prefix_cache_status_code',
                  'selected_prefix_cache_stores',
                  'selected_prefix_cache_total_bytes',
                  'selected_prefix_cache_warmth_indicator',
                  'strategy'
                ]
              )
            )
            ELSE NULL
          END
    WHERE payload_capture_mode IN ('none', 'metadata')
    """)

    execute("""
    UPDATE request_events AS event
    SET payload = jsonb_strip_nulls(
      jsonb_build_object(
        'attempt', event.payload -> 'attempt',
        'attempt_index', event.payload -> 'attempt_index',
        'boundary', event.payload -> 'boundary',
        'call_id', event.payload -> 'call_id',
        'kind', event.payload -> 'kind',
        'model_id', event.payload -> 'model_id',
        'model_version', event.payload -> 'model_version',
        'parent_step_id', event.payload -> 'parent_step_id',
        'request_step_id', event.payload -> 'request_step_id',
        'sequence', event.payload -> 'sequence',
        'state', event.payload -> 'state',
        'step_id', event.payload -> 'step_id',
        'step_type', event.payload -> 'step_type',
        'turn_index', event.payload -> 'turn_index',
        'tool_name', event.payload -> 'tool_name',
        'type', event.payload -> 'type',
        'result',
          CASE
            WHEN jsonb_typeof(event.payload -> 'result') = 'object'
            THEN jsonb_strip_nulls(
              jsonb_build_object(
                'error_code', event.payload #> '{result,error_code}',
                'finish_reason', event.payload #> '{result,finish_reason}',
                'http_status', event.payload #> '{result,http_status}',
                'indeterminate_reason', event.payload #> '{result,indeterminate_reason}',
                'input_tokens', event.payload #> '{result,input_tokens}',
                'output_tokens', event.payload #> '{result,output_tokens}',
                'remote_request_id', event.payload #> '{result,remote_request_id}',
                'remote_response_id', event.payload #> '{result,remote_response_id}'
              )
            )
            ELSE NULL
          END
      )
    )
    FROM requests AS request
    WHERE event.request_id = request.id
      AND request.payload_capture_mode IN ('none', 'metadata')
    """)

    execute("""
    UPDATE requests
    SET response_preview = NULL
    WHERE response_preview IS NOT NULL
      AND char_length(response_preview) > 512
    """)

    create(
      constraint(:requests, :requests_non_full_content_absent,
        check:
          "payload_capture_mode = 'full' OR (canonical_request IS NULL AND request_payload IS NULL AND response_payload IS NULL AND error_message IS NULL)"
      )
    )

    create(
      constraint(:requests, :requests_none_shape_and_preview_absent,
        check:
          "payload_capture_mode <> 'none' OR (request_shape IS NULL AND response_preview IS NULL)"
      )
    )

    create(
      constraint(:requests, :requests_response_preview_bounded,
        check: "response_preview IS NULL OR char_length(response_preview) <= 512"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:requests, :requests_response_preview_bounded))
    drop_if_exists(constraint(:requests, :requests_none_shape_and_preview_absent))
    drop_if_exists(constraint(:requests, :requests_non_full_content_absent))

    alter table(:requests) do
      remove_if_exists(:response_hash)
      remove_if_exists(:request_shape)
    end

    alter table(:tenants) do
      remove(:request_body_capture_mode)
    end
  end
end
