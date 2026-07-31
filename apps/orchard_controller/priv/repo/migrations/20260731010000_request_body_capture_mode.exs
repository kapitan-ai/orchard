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
    scheduler_decision = NULL
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
