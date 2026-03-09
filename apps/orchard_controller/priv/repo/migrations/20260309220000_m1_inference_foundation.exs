defmodule Orchard.Repo.Migrations.M1InferenceFoundation do
  use Ecto.Migration

  def change do
    create_enum("model_catalog_state", ["registered", "active", "deprecated", "retired"])

    create_enum("request_state", [
      "received",
      "validated",
      "admitted",
      "queued",
      "scheduled",
      "dispatching",
      "running",
      "streaming",
      "completed",
      "failed",
      "cancelled",
      "timed_out",
      "interrupted"
    ])

    create_enum("payload_capture_mode", ["none", "metadata", "full"])

    create table(:models, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :model_id, :text, null: false
      add :version, :text, null: false
      add :state, :model_catalog_state, null: false, default: "registered"
      add :format, :text, null: false
      add :capabilities, {:array, :text}, null: false, default: []
      add :tokenizer, :map, null: false, default: %{}
      add :artifact_uri, :text
      add :artifact_sha256, :text, null: false
      add :artifact_size_bytes, :bigint, null: false
      add :resident_memory_bytes, :bigint, null: false
      add :kv_cache_bytes_per_token, :bigint, null: false
      add :prefill_workspace_bytes_per_token, :bigint, null: false
      add :max_context_tokens, :integer, null: false
      add :default_parameters, :map, null: false, default: %{}
      add :runtime_requirements, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create unique_index(:models, [:model_id, :version])
    create index(:models, [:state, :inserted_at])

    create constraint(:models, :models_format_check,
             check: "format IN ('mlx', 'gguf')"
           )

    create constraint(:models, :models_artifact_sizes_non_negative,
             check: "artifact_size_bytes >= 0 AND resident_memory_bytes >= 0 AND kv_cache_bytes_per_token >= 0 AND prefill_workspace_bytes_per_token >= 0"
           )

    create constraint(:models, :models_max_context_tokens_positive,
             check: "max_context_tokens > 0"
           )

    create table(:requests, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :public_id, :text, null: false
      add :endpoint, :text, null: false
      add :tenant_id, :binary_id, null: false
      add :api_key_id, :binary_id
      add :service_account_id, :binary_id
      add :model_id, references(:models, type: :binary_id)
      add :requested_model, :text, null: false
      add :node_id, :binary_id
      add :worker_id, :binary_id
      add :retry_of_request_id, references(:requests, type: :binary_id, on_delete: :nilify_all)
      add :idempotency_key, :text
      add :body_hash, :binary
      add :state, :request_state, null: false, default: "received"
      add :stream, :boolean, null: false, default: false
      add :payload_capture_mode, :payload_capture_mode, null: false, default: "metadata"
      add :canonical_request, :map
      add :request_payload, :map
      add :response_payload, :map
      add :response_preview, :text
      add :sampling_params, :map, null: false, default: %{}
      add :response_format, :map, null: false, default: %{}
      add :scheduler_decision, :map
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :reserved_output_tokens, :integer, null: false, default: 0
      add :first_token_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :timeout_at, :utc_datetime_usec
      add :http_status, :integer
      add :error_code, :text
      add :error_message, :text
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    create unique_index(:requests, [:public_id])
    create index(:requests, [:tenant_id, :inserted_at])

    create index(:requests, [:tenant_id, :state],
             where:
               "state IN ('admitted', 'queued', 'scheduled', 'dispatching', 'running', 'streaming')",
             name: :idx_requests_active_by_tenant
           )

    create unique_index(:requests, [:tenant_id, :idempotency_key],
             where: "idempotency_key IS NOT NULL",
             name: :idx_requests_tenant_idempotency
           )

    create index(:requests, [:state, :inserted_at],
             where:
               "state IN ('received', 'validated', 'admitted', 'queued', 'scheduled', 'dispatching', 'running', 'streaming')",
             name: :idx_requests_non_terminal_state
           )

    create constraint(:requests, :requests_endpoint_check,
             check: "endpoint IN ('chat_completions', 'responses')"
           )

    create constraint(:requests, :requests_token_counters_non_negative,
             check: "input_tokens >= 0 AND output_tokens >= 0 AND reserved_output_tokens >= 0"
           )

    create table(:request_events, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :request_id, references(:requests, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :event_type, :text, null: false
      add :state, :request_state
      add :occurred_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
      add :payload, :map, null: false, default: %{}
    end

    create unique_index(:request_events, [:request_id, :seq])
    create index(:request_events, [:request_id, :occurred_at])

    create constraint(:request_events, :request_events_seq_positive,
             check: "seq > 0"
           )
  end

  defp create_enum(type_name, values) do
    values_sql = values |> Enum.map_join(", ", &"'#{&1}'")

    execute(
      "CREATE TYPE #{type_name} AS ENUM (#{values_sql})",
      "DROP TYPE IF EXISTS #{type_name}"
    )
  end
end
