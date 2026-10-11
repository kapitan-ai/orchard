defmodule Orchard.Repo.Migrations.ConvertTimestampsToTimestamptz do
  use Ecto.Migration

  # SPEC.md §8.2 declares every Controller timestamp as `timestamptz`. Earlier
  # migrations created `timestamp without time zone` columns that hold UTC values,
  # so database clock comparisons depended on the session time zone.
  @columns [
    api_keys: ~w(last_used_at revoked_at inserted_at updated_at expires_at),
    audit_logs: ~w(occurred_at),
    beam_peer_grants:
      ~w(issued_at not_before_at cutover_at expires_at delivered_at activated_at superseded_at failed_at revoked_at inserted_at updated_at),
    circuit_breaker_failures: ~w(occurred_at inserted_at decision_at),
    circuit_breakers: ~w(opened_at suppressed_until last_cleared_at inserted_at updated_at),
    cluster_identities: ~w(inserted_at updated_at),
    console_settings: ~w(inserted_at updated_at),
    controller_instances:
      ~w(first_enrolled_at last_seen_at inserted_at updated_at dispatch_capacity_capability_observed_at),
    dispatch_capacity_authority: ~w(cutover_at inserted_at updated_at),
    models: ~w(inserted_at updated_at),
    node_admission_candidates: ~w(last_observed_at inserted_at updated_at),
    node_admission_decisions: ~w(decided_at inserted_at),
    node_dispatch_capacity_policies: ~w(approved_at legacy_admitted_at inserted_at updated_at),
    node_enrollments:
      ~w(issued_at expires_at consumed_at revoked_at output_failed_at inserted_at updated_at published_at),
    node_heartbeats: ~w(observed_at),
    node_runtime_capacity_evidence: ~w(observed_at inserted_at updated_at),
    node_trust_authorities: ~w(inserted_at updated_at),
    nodes: ~w(last_heartbeat_at inserted_at updated_at last_transport_failure_at),
    portal_invite_tokens: ~w(expires_at redeemed_at inserted_at),
    portal_login_throttles: ~w(blocked_until last_failed_at inserted_at updated_at),
    portal_sessions: ~w(issued_at last_seen_at absolute_expires_at inserted_at),
    portal_users: ~w(disabled_at inserted_at updated_at),
    provisioning_batches: ~w(started_at completed_at inserted_at updated_at),
    request_events: ~w(occurred_at),
    requests: ~w(first_token_at completed_at timeout_at inserted_at updated_at),
    role_bindings: ~w(inserted_at updated_at),
    routing_policies: ~w(inserted_at updated_at),
    service_accounts: ~w(disabled_at inserted_at updated_at),
    tenant_model_access: ~w(inserted_at updated_at),
    tenants: ~w(inserted_at updated_at),
    tools: ~w(inserted_at updated_at)
  ]

  def up do
    drop_api_key_overlap_constraint()
    alter_columns("timestamptz")
    add_api_key_overlap_constraint("tstzrange", "timestamptz")
  end

  def down do
    drop_api_key_overlap_constraint()
    alter_columns("timestamp(6) without time zone")
    add_api_key_overlap_constraint("tsrange", "timestamp")
  end

  defp alter_columns(type) do
    schema = quoted_schema()

    for {table, columns} <- @columns do
      clauses =
        Enum.map_join(columns, ",\n  ", fn column ->
          ~s(ALTER COLUMN "#{column}" TYPE #{type} USING "#{column}" AT TIME ZONE 'UTC')
        end)

      execute(~s(ALTER TABLE "#{schema}"."#{table}"\n  #{clauses}))
    end
  end

  # The exclusion constraint's range expression must be rebuilt for the column
  # type, because a cast between the two timestamp types is not immutable.
  defp add_api_key_overlap_constraint(range_function, infinity_type) do
    execute("""
    ALTER TABLE "#{quoted_schema()}".api_keys
    ADD CONSTRAINT api_keys_service_account_active_name_no_overlap
    EXCLUDE USING gist (
      service_account_id WITH =,
      name WITH =,
      #{range_function}(
        inserted_at,
        GREATEST(
          inserted_at,
          LEAST(
            COALESCE(revoked_at, 'infinity'::#{infinity_type}),
            COALESCE(expires_at, 'infinity'::#{infinity_type})
          )
        ),
        '[)'
      ) WITH &&
    )
    WHERE (service_account_id IS NOT NULL)
    """)
  end

  defp drop_api_key_overlap_constraint do
    execute(
      ~s(ALTER TABLE "#{quoted_schema()}".api_keys DROP CONSTRAINT api_keys_service_account_active_name_no_overlap)
    )
  end

  defp quoted_schema, do: String.replace(prefix() || "public", "\"", "\"\"")
end
