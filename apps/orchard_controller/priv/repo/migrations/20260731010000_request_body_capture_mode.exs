defmodule Orchard.Repo.Migrations.RequestBodyCaptureMode do
  use Ecto.Migration

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
        error_code = #{legacy_stable_error_code_sql()},
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
        scheduler_decision = #{legacy_cache_affinity_metadata_sql()}
    WHERE payload_capture_mode IN ('none', 'metadata')
    """)

    execute("""
    UPDATE request_events AS event
    SET payload = '{}'::jsonb
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

    create(
      constraint(:requests, :requests_non_full_error_code_stable,
        check:
          "payload_capture_mode = 'full' OR error_code IS NULL OR error_code = ANY (#{stable_error_code_array_sql()})"
      )
    )
  end

  def down do
    drop_if_exists(constraint(:requests, :requests_non_full_error_code_stable))
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

  @doc """
  Returns the SQL expression that retains typed cache-affinity metadata while purging legacy scheduler content.
  """
  @spec legacy_cache_affinity_metadata_sql() :: String.t()
  def legacy_cache_affinity_metadata_sql do
    """
    jsonb_strip_nulls(
      jsonb_build_object(
        'cache_affinity_key',
          CASE
            WHEN scheduler_decision ->> 'cache_affinity_key'
                   ~ '^hmac-sha256:[0-9a-f]{64}$'
            THEN scheduler_decision -> 'cache_affinity_key'
          END,
        'cache_affinity_enabled',
          CASE
            WHEN jsonb_typeof(scheduler_decision -> 'cache_affinity_enabled') = 'boolean'
            THEN scheduler_decision -> 'cache_affinity_enabled'
          END,
        'cache_affinity_hint_available',
          CASE
            WHEN jsonb_typeof(scheduler_decision -> 'cache_affinity_hint_available') = 'boolean'
            THEN scheduler_decision -> 'cache_affinity_hint_available'
          END,
        'cache_affinity_selected_match',
          CASE
            WHEN jsonb_typeof(scheduler_decision -> 'cache_affinity_selected_match') = 'boolean'
            THEN scheduler_decision -> 'cache_affinity_selected_match'
          END,
        'cache_affinity_source',
          CASE
            WHEN scheduler_decision ->> 'cache_affinity_source' = 'recent_completed_request'
            THEN scheduler_decision -> 'cache_affinity_source'
          END,
        'cache_affinity_candidate_count',
          CASE
            WHEN jsonb_typeof(scheduler_decision -> 'cache_affinity_candidate_count') = 'number'
              AND scheduler_decision ->> 'cache_affinity_candidate_count' ~ '^[0-9]+$'
            THEN scheduler_decision -> 'cache_affinity_candidate_count'
          END
      )
    )
    """
  end

  @doc """
  Returns the SQL expression that maps unknown legacy error codes to `internal_error`.
  """
  @spec legacy_stable_error_code_sql() :: String.t()
  def legacy_stable_error_code_sql do
    """
    CASE
      WHEN error_code IS NULL OR error_code = ANY (#{stable_error_code_array_sql()})
      THEN error_code
      ELSE 'internal_error'
    END
    """
  end

  @doc """
  Returns the closed error-code vocabulary accepted on restricted Request rows.
  """
  @spec stable_error_codes() :: [String.t()]
  def stable_error_codes, do: @stable_error_codes

  defp stable_error_code_array_sql do
    values = Enum.map_join(@stable_error_codes, ", ", &"'#{&1}'")
    "ARRAY[#{values}]::text[]"
  end
end
