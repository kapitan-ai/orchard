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
  @step_event_types ~w(
    request_step.started
    request_step.proposed
    request_step.completed
    request_step.failed
    request_step.cancelled
    request_step.timed_out
    request_step.interrupted
    request_step.indeterminate
  )
  @step_types ~w(inference_turn tool_call tool_execution)
  @boundaries ~w(pre_side_effect post_observation)
  @finish_reasons ~w(cancelled content_filter error length stop tool_calls)
  @result_integer_keys ~w(http_status input_tokens output_tokens)
  @tool_execution_defaults %{
    "request_step.failed" => {"tool_execution_failed", "Tool execution failed"},
    "request_step.cancelled" => {"tool_execution_cancelled", "Tool execution was cancelled"},
    "request_step.timed_out" => {"tool_execution_timed_out", "Tool execution timed out"}
  }
  @indeterminate_defaults %{
    "cancel_ack_missing" =>
      {"tool_execution_indeterminate_cancel_ack_missing",
       "Tool execution cancellation acknowledgement was not observed"},
    "controller_restarted" =>
      {"tool_execution_indeterminate_controller_restarted",
       "Tool execution became indeterminate after the controller restarted"},
    "executor_unreachable" =>
      {"tool_execution_indeterminate_executor_unreachable",
       "Tool execution became indeterminate after the executor became unreachable"},
    "result_not_observed" =>
      {"tool_execution_indeterminate_result_not_observed",
       "Tool execution result was not observed"},
    "timeout_after_start" =>
      {"tool_execution_indeterminate_timeout_after_start",
       "Tool execution timed out after starting and the final outcome was not observed"}
  }

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
      AND NOT (event.event_type = ANY (#{step_event_type_array_sql()}))
    """)

    execute("""
    UPDATE request_events AS event
    SET payload = #{legacy_step_event_payload_sql()}
    FROM requests AS request
    WHERE event.request_id = request.id
      AND request.payload_capture_mode IN ('none', 'metadata')
      AND event.event_type = ANY (#{step_event_type_array_sql()})
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
  Returns the SQL expression that rebuilds a restricted `request_step.*` payload.

  Retains the typed structural fields `RequestStepEvent` readback requires while
  dropping model-generated content, raw tool arguments, and raw error text. Rows
  that cannot be reconstructed into a contract-valid skeleton collapse to `{}`.
  """
  @spec legacy_step_event_payload_sql() :: String.t()
  def legacy_step_event_payload_sql do
    """
    CASE
      WHEN #{step_id_sql()} IS NULL OR #{boundary_sql()} IS NULL THEN '{}'::jsonb
      ELSE jsonb_strip_nulls(
             jsonb_build_object(
               'step_id', to_jsonb(#{step_id_sql()}),
               'step_type', to_jsonb(#{step_type_sql()}),
               'turn_index', to_jsonb(#{turn_index_sql()}),
               'attempt', to_jsonb(#{attempt_sql()}),
               'parent_step_id', to_jsonb(#{parent_step_id_sql()}),
               'boundary', to_jsonb(#{boundary_sql()}),
               'call_id', to_jsonb(#{call_id_sql()})
             )
           ) || jsonb_build_object('result', #{step_result_sql()})
    END
    """
  end

  @doc """
  Returns the closed error-code vocabulary accepted on restricted Request rows.
  """
  @spec stable_error_codes() :: [String.t()]
  def stable_error_codes, do: @stable_error_codes

  @doc """
  Returns the `request_step.*` event-type vocabulary rebuilt by the legacy purge.
  """
  @spec step_event_types() :: [String.t()]
  def step_event_types, do: @step_event_types

  defp stable_error_code_array_sql, do: text_array_sql(@stable_error_codes)

  defp step_event_type_array_sql, do: text_array_sql(@step_event_types)

  defp text_array_sql(values) do
    "ARRAY[#{Enum.map_join(values, ", ", &"'#{&1}'")}]::text[]"
  end

  defp step_type_sql do
    "(CASE WHEN event.payload ->> 'step_type' = ANY (#{text_array_sql(@step_types)}) THEN event.payload ->> 'step_type' END)"
  end

  defp boundary_sql do
    "(CASE WHEN event.payload ->> 'boundary' = ANY (#{text_array_sql(@boundaries)}) THEN event.payload ->> 'boundary' END)"
  end

  defp turn_index_sql, do: positive_integer_sql("turn_index")

  defp attempt_sql, do: positive_integer_sql("attempt")

  defp positive_integer_sql(key) do
    """
    (CASE
       WHEN jsonb_typeof(event.payload -> '#{key}') = 'number'
         AND (event.payload ->> '#{key}') ~ '^[1-9][0-9]{0,17}$'
       THEN (event.payload ->> '#{key}')::bigint
     END)
    """
  end

  defp call_id_sql do
    """
    (CASE
       WHEN jsonb_typeof(event.payload -> 'call_id') = 'string'
       THEN 'sha256:' || encode(digest(convert_to(event.payload ->> 'call_id', 'UTF8'), 'sha256'), 'hex')
     END)
    """
  end

  defp step_id_sql do
    """
    (CASE
       WHEN #{turn_index_sql()} IS NULL OR #{attempt_sql()} IS NULL THEN NULL
       WHEN #{step_type_sql()} = 'inference_turn'
         THEN 'inference_turn:t' || #{turn_index_sql()} || ':a' || #{attempt_sql()}
       WHEN #{step_type_sql()} = 'tool_call' AND #{call_id_sql()} IS NOT NULL
         THEN 'tool_call:t' || #{turn_index_sql()} || ':c' || #{call_id_sql()}
       WHEN #{step_type_sql()} = 'tool_execution' AND #{call_id_sql()} IS NOT NULL
         THEN 'tool_execution:t' || #{turn_index_sql()} || ':c' || #{call_id_sql()} || ':a' || #{attempt_sql()}
     END)
    """
  end

  defp parent_step_id_sql do
    """
    (CASE
       WHEN #{turn_index_sql()} IS NULL OR #{call_id_sql()} IS NULL THEN NULL
       WHEN #{step_type_sql()} = 'tool_call'
         THEN 'inference_turn:t' || #{turn_index_sql()} || ':a1'
       WHEN #{step_type_sql()} = 'tool_execution'
         THEN 'tool_call:t' || #{turn_index_sql()} || ':c' || #{call_id_sql()}
     END)
    """
  end

  defp step_result_sql do
    """
    (CASE
       WHEN #{step_type_sql()} = 'tool_execution' THEN #{tool_execution_result_sql()}
       ELSE #{inference_step_result_sql()}
     END)
    """
  end

  defp inference_step_result_sql do
    integers =
      Enum.map_join(@result_integer_keys, ",\n        ", fn key ->
        """
        '#{key}',
          CASE
            WHEN jsonb_typeof(event.payload -> 'result' -> '#{key}') = 'number'
              AND (event.payload -> 'result' ->> '#{key}') ~ '^[0-9]{1,18}$'
            THEN event.payload -> 'result' -> '#{key}'
          END\
        """
      end)

    """
    jsonb_strip_nulls(
      jsonb_build_object(
        #{integers},
        'finish_reason',
          CASE
            WHEN event.payload -> 'result' ->> 'finish_reason' = ANY (#{text_array_sql(@finish_reasons)})
            THEN event.payload -> 'result' -> 'finish_reason'
          END
      )
    )
    """
  end

  defp tool_execution_result_sql do
    terminal =
      Enum.map_join(@tool_execution_defaults, "\n", fn {event_type, {code, message}} ->
        "WHEN event.event_type = '#{event_type}' THEN #{tool_execution_error_sql(code, message)}"
      end)

    """
    (CASE
       #{terminal}
       WHEN event.event_type = 'request_step.indeterminate'
         THEN #{indeterminate_result_sql()}
       ELSE '{}'::jsonb
     END)
    """
  end

  defp indeterminate_result_sql do
    branches =
      Enum.map_join(@indeterminate_defaults, "\n", fn {reason, {code, message}} ->
        """
        WHEN event.payload -> 'result' ->> 'indeterminate_reason' = '#{reason}'
          THEN #{tool_execution_error_sql(code, message)} || jsonb_build_object('indeterminate_reason', '#{reason}'::text)\
        """
      end)

    """
    (CASE
       #{branches}
       ELSE '{}'::jsonb
     END)
    """
  end

  defp tool_execution_error_sql(default_code, default_message) do
    """
    jsonb_build_object(
      'error_code',
        COALESCE(
          CASE
            WHEN event.payload -> 'result' ->> 'error_code' = ANY (#{stable_error_code_array_sql()})
            THEN event.payload -> 'result' ->> 'error_code'
          END,
          '#{default_code}'
        ),
      'error_message', '#{default_message}'::text
    )\
    """
  end
end
