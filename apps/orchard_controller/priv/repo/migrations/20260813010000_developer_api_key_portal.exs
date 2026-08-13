defmodule Orchard.Repo.Migrations.DeveloperApiKeyPortal do
  use Ecto.Migration

  def change do
    create table(:portal_users, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:email, :text, null: false)
      add(:password_hash, :text)
      add(:status, :text, null: false, default: "invited")
      add(:session_epoch, :bigint, null: false, default: 0)
      add(:disabled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:portal_users, [:tenant_id, :email]))
    create(index(:portal_users, [:tenant_id, :status]))
    create(constraint(:portal_users, :portal_users_status_closed, check: "status IN ('invited', 'active', 'disabled')"))
    create(constraint(:portal_users, :portal_users_session_epoch_non_negative, check: "session_epoch >= 0"))

    create table(:portal_invite_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:portal_user_id, references(:portal_users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:redeemed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:portal_invite_tokens, [:portal_user_id]))
    create(unique_index(:portal_invite_tokens, [:token_hash]))
    create(constraint(:portal_invite_tokens, :portal_invite_tokens_hash_length, check: "octet_length(token_hash) = 32"))

    alter table(:api_keys) do
      add(:issuance_surface, :text, null: false, default: "governance")
      add(:portal_user_id, references(:portal_users, type: :binary_id, on_delete: :nilify_all))
    end

    create(constraint(:api_keys, :api_keys_issuance_surface_closed, check: "issuance_surface IN ('governance', 'developer_portal')"))
    create(constraint(:api_keys, :api_keys_developer_portal_tenant_direct, check: "issuance_surface <> 'developer_portal' OR (tenant_id IS NOT NULL AND service_account_id IS NULL)"))
    create(index(:api_keys, [:portal_user_id, :inserted_at], name: :idx_api_keys_portal_user_active, where: "portal_user_id IS NOT NULL AND issuance_surface = 'developer_portal' AND revoked_at IS NULL"))

    create table(:portal_sessions, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false)
      add(:portal_user_id, references(:portal_users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:token_hash, :binary, null: false)
      add(:password_epoch, :bigint, null: false)
      add(:issued_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)
      add(:absolute_expires_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()"))
    end

    create(unique_index(:portal_sessions, [:token_hash]))
    create(index(:portal_sessions, [:portal_user_id]))
    create(index(:portal_sessions, [:absolute_expires_at]))
    create(constraint(:portal_sessions, :portal_sessions_token_hash_length, check: "octet_length(token_hash) = 32"))
    create(constraint(:portal_sessions, :portal_sessions_password_epoch_non_negative, check: "password_epoch >= 0"))
    create(constraint(:portal_sessions, :portal_sessions_last_seen_after_issued, check: "last_seen_at >= issued_at"))
    create(constraint(:portal_sessions, :portal_sessions_absolute_after_issued, check: "absolute_expires_at > issued_at"))

    create table(:portal_login_throttles, primary_key: false) do
      add(:organization_fingerprint, :binary, null: false, primary_key: true)
      add(:identity_fingerprint, :binary, null: false, primary_key: true)
      add(:source_fingerprint, :binary, null: false, primary_key: true)
      add(:failure_count, :integer, null: false, default: 0)
      add(:blocked_until, :utc_datetime_usec)
      add(:last_failed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:portal_login_throttles, :portal_login_throttles_org_fingerprint_length, check: "octet_length(organization_fingerprint) = 32"))
    create(constraint(:portal_login_throttles, :portal_login_throttles_identity_fingerprint_length, check: "octet_length(identity_fingerprint) = 32"))
    create(constraint(:portal_login_throttles, :portal_login_throttles_source_fingerprint_length, check: "octet_length(source_fingerprint) = 32"))
    create(constraint(:portal_login_throttles, :portal_login_throttles_failure_count_non_negative, check: "failure_count >= 0"))

    create(index(:requests, [:api_key_id], name: :idx_requests_api_key_id, where: "api_key_id IS NOT NULL"))
  end
end
