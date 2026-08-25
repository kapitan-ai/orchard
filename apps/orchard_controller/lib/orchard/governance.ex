defmodule Orchard.Governance do
  @moduledoc """
  Governance constants and lifecycle APIs for tenants, API Clients, API Tokens,
  role bindings, provisioning batches, and audit records.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Governance.ApiClientProvisioning
  alias Orchard.SchemaSupport

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    AuditLog,
    AuditWriter,
    ProvisioningBatch,
    RoleBinding,
    ServiceAccount,
    Tenant
  }

  alias Orchard.Repo

  @legacy_tenant_id "00000000-0000-0000-0000-000000000000"
  @legacy_tenant_slug "legacy"
  @legacy_tenant_name "Legacy Single Tenant"

  @type api_key_creation_result :: %{api_key: ApiKey.t(), token: String.t()}
  @type principal_type :: :tenant | :service_account
  @type api_key_auth_result :: %{
          tenant_id: Ecto.UUID.t(),
          principal_type: principal_type(),
          principal_id: Ecto.UUID.t(),
          service_account_id: Ecto.UUID.t() | nil,
          api_key_id: Ecto.UUID.t()
        }
  @type api_key_auth_error :: :invalid_api_key | :api_key_revoked | :api_key_expired
  @type authorization_error ::
          :api_client_disabled | :missing_inference_client_access | :admin_required
  @type auth_failure_reason :: :missing_header | :malformed_header | api_key_auth_error

  @spec legacy_tenant_id() :: Ecto.UUID.t()
  def legacy_tenant_id, do: @legacy_tenant_id

  @spec legacy_tenant_slug() :: String.t()
  def legacy_tenant_slug, do: @legacy_tenant_slug

  @spec legacy_tenant_name() :: String.t()
  def legacy_tenant_name, do: @legacy_tenant_name

  @spec create_tenant(map() | keyword()) :: {:ok, Tenant.t()} | {:error, Changeset.t()}
  def create_tenant(attrs) do
    attrs = normalize_attrs(attrs)

    AuditWriter.transaction(fn ->
      with {:ok, tenant} <- insert_tenant(attrs),
           {:ok, _audit_log} <- insert_tenant_audit_log(tenant, "tenant.created", utc_now()) do
        {:ok, tenant}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  alias Orchard.Governance.PortalGovernance

  defdelegate create_portal_invite(tenant, attrs), to: PortalGovernance, as: :create_invite
  defdelegate copy_portal_invite(tenant, user), to: PortalGovernance, as: :copy_invite

  defdelegate redeem_portal_invite(slug, token, password),
    to: PortalGovernance,
    as: :redeem_invite

  defdelegate disable_portal_user(tenant, user), to: PortalGovernance, as: :disable_user
  defdelegate list_portal_users(tenant), to: PortalGovernance, as: :list_users

  defdelegate create_portal_session(slug, email, password, source),
    to: PortalGovernance,
    as: :login

  defdelegate validate_portal_session(token, slug), to: PortalGovernance, as: :validate
  defdelegate validate_portal_session(token, slug, opts), to: PortalGovernance, as: :validate
  defdelegate logout_portal_session(token), to: PortalGovernance, as: :logout
  defdelegate create_portal_api_key(token, slug, attrs), to: PortalGovernance, as: :mint_key
  defdelegate list_portal_api_keys(token, slug), to: PortalGovernance, as: :list_keys
  defdelegate revoke_portal_api_key(token, slug, key), to: PortalGovernance, as: :revoke_key
  defdelegate prune_portal_persistence(), to: PortalGovernance, as: :prune

  @spec create_api_key(Tenant.t() | Ecto.UUID.t(), map() | keyword()) ::
          {:ok, api_key_creation_result()}
          | {:error, Changeset.t() | :tenant_not_found | :invalid_api_key_secret}
  def create_api_key(%Tenant{id: tenant_id}, attrs), do: create_api_key(tenant_id, attrs)

  def create_api_key(tenant_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, generated} <- normalize_generated_secret(api_key_secret_impl().generate()) do
      tenant_id
      |> create_api_key_transaction(attrs, generated)
      |> unwrap_transaction_result()
    end
  end

  defp create_api_key_transaction(tenant_id, attrs, generated) do
    AuditWriter.transaction(fn ->
      with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
           {:ok, tenant} <- fetch_tenant(tenant_id),
           {:ok, api_key} <- insert_api_key(tenant, attrs, generated),
           {:ok, _audit_log} <- insert_api_key_audit_log(api_key, "api_key.created", utc_now()) do
        {:ok, %{api_key: redact_api_key(api_key), token: generated.token}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec upsert_api_client(Tenant.t() | Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok, ServiceAccount.t()} | {:error, Changeset.t() | :tenant_not_found}
  def upsert_api_client(tenant_or_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    AuditWriter.transaction(fn ->
      with {:ok, tenant} <- resolve_tenant(tenant_or_id),
           {:ok, api_client, action} <- upsert_api_client_row(tenant, attrs),
           {:ok, _audit_log} <-
             insert_api_client_audit_log(
               api_client,
               api_client_audit_action(action),
               utc_now(),
               opts
             ) do
        {:ok, api_client}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec list_api_clients_for_tenant(Tenant.t() | Ecto.UUID.t()) ::
          {:ok, [ServiceAccount.t()]} | {:error, :tenant_not_found}
  def list_api_clients_for_tenant(%Tenant{id: tenant_id}),
    do: list_api_clients_for_tenant(tenant_id)

  def list_api_clients_for_tenant(tenant_id) do
    with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
         {:ok, _tenant} <- fetch_tenant(tenant_id) do
      api_clients =
        ServiceAccount
        |> where([service_account], service_account.tenant_id == ^tenant_id)
        |> order_by([service_account], asc: service_account.name, asc: service_account.id)
        |> preload(
          api_keys: ^api_keys_preload_query(),
          role_bindings: ^role_bindings_preload_query()
        )
        |> Repo.all()
        |> Enum.map(&redact_service_account_api_keys/1)

      {:ok, api_clients}
    end
  end

  @spec get_api_client(Tenant.t() | Ecto.UUID.t(), ServiceAccount.t() | Ecto.UUID.t()) ::
          {:ok, ServiceAccount.t()} | {:error, :tenant_not_found | :api_client_not_found}
  def get_api_client(tenant_or_id, %ServiceAccount{id: service_account_id}),
    do: get_api_client(tenant_or_id, service_account_id)

  def get_api_client(tenant_or_id, service_account_id) do
    with {:ok, tenant} <- resolve_tenant(tenant_or_id),
         {:ok, service_account_id} <- normalize_service_account_id(service_account_id),
         {:ok, api_client} <- fetch_api_client_for_tenant(tenant.id, service_account_id) do
      {:ok, redact_service_account_api_keys(api_client)}
    end
  end

  @spec disable_api_client(
          Tenant.t() | Ecto.UUID.t(),
          ServiceAccount.t() | Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, ServiceAccount.t()}
          | {:error, Changeset.t() | :tenant_not_found | :api_client_not_found}
  def disable_api_client(tenant_or_id, service_account_or_id, opts \\ [])

  def disable_api_client(tenant_or_id, %ServiceAccount{id: service_account_id}, opts),
    do: disable_api_client(tenant_or_id, service_account_id, opts)

  def disable_api_client(tenant_or_id, service_account_id, opts) do
    AuditWriter.transaction(fn ->
      with {:ok, tenant} <- resolve_tenant(tenant_or_id),
           {:ok, service_account_id} <- normalize_service_account_id(service_account_id),
           {:ok, api_client} <- lock_api_client_for_tenant(tenant.id, service_account_id),
           {:ok, api_client, audit?} <- disable_locked_api_client(api_client),
           {:ok, _audit_log} <- maybe_insert_disable_audit_log(api_client, audit?, opts) do
        {:ok, api_client}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec create_api_client_api_token(
          ServiceAccount.t() | Ecto.UUID.t(),
          map() | keyword(),
          keyword()
        ) ::
          {:ok, api_key_creation_result()}
          | {:error,
             Changeset.t()
             | :api_client_not_found
             | :api_client_disabled
             | :invalid_api_key_secret}
  def create_api_client_api_token(service_account_or_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    with {:ok, generated} <- normalize_generated_secret(api_key_secret_impl().generate()) do
      service_account_or_id
      |> create_api_client_api_token_transaction(attrs, generated, opts)
      |> unwrap_transaction_result()
    end
  end

  @spec rotate_api_client_api_token(
          ServiceAccount.t() | Ecto.UUID.t(),
          map() | keyword(),
          keyword()
        ) ::
          {:ok, api_key_creation_result() | map()}
          | {:error,
             Changeset.t()
             | :api_client_not_found
             | :api_client_disabled
             | :invalid_api_key_secret}
  def rotate_api_client_api_token(service_account_or_id, attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)

    with {:ok, generated} <- normalize_generated_secret(api_key_secret_impl().generate()) do
      service_account_or_id
      |> rotate_api_client_api_token_transaction(attrs, generated, opts)
      |> unwrap_transaction_result()
    end
  end

  defp create_api_client_api_token_transaction(service_account_or_id, attrs, generated, opts) do
    AuditWriter.transaction(fn ->
      with {:ok, api_client} <- resolve_api_client(service_account_or_id),
           :ok <- ensure_api_client_enabled(api_client),
           {:ok, api_key} <- insert_service_account_api_key(api_client, attrs, generated),
           {:ok, _audit_log} <-
             insert_service_account_api_key_audit_log(
               api_client,
               api_key,
               "api_key.created",
               utc_now(),
               opts
             ) do
        {:ok, %{api_key: redact_api_key(api_key), token: generated.token}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp rotate_api_client_api_token_transaction(service_account_or_id, attrs, generated, opts) do
    AuditWriter.transaction(fn ->
      with {:ok, api_client} <- resolve_api_client(service_account_or_id),
           :ok <- ensure_api_client_enabled(api_client),
           {:ok, revoked_keys} <-
             revoke_active_service_account_tokens(api_client, Map.get(attrs, "name"), opts),
           {:ok, api_key} <- insert_service_account_api_key(api_client, attrs, generated),
           {:ok, _audit_log} <-
             insert_service_account_api_key_audit_log(
               api_client,
               api_key,
               "api_key.created",
               utc_now(),
               opts
             ),
           {:ok, _audit_log} <-
             maybe_insert_key_rotation_audit_log(
               api_client,
               api_key,
               revoked_keys,
               utc_now(),
               opts
             ) do
        {:ok,
         %{
           api_key: redact_api_key(api_key),
           token: generated.token,
           revoked_api_keys: Enum.map(revoked_keys, &redact_api_key/1)
         }}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec ensure_inference_client_access(
          ServiceAccount.t() | Ecto.UUID.t(),
          Tenant.t() | Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, RoleBinding.t()}
          | {:error, Changeset.t() | :api_client_not_found | :tenant_not_found}
  def ensure_inference_client_access(service_account_or_id, tenant_or_id, opts \\ []) do
    AuditWriter.transaction(fn ->
      with {:ok, api_client} <- resolve_api_client(service_account_or_id),
           {:ok, tenant} <- resolve_tenant(tenant_or_id),
           {:ok, role_binding, created?} <-
             ensure_inference_client_role_binding(api_client, tenant),
           {:ok, _audit_log} <-
             maybe_insert_role_binding_audit_log(api_client, role_binding, created?, opts) do
        {:ok, role_binding}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec ensure_cluster_admin_access(ServiceAccount.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, RoleBinding.t()} | {:error, Changeset.t() | :api_client_not_found}
  def ensure_cluster_admin_access(service_account_or_id, opts \\ []) do
    AuditWriter.transaction(fn ->
      with {:ok, api_client} <- resolve_api_client(service_account_or_id),
           {:ok, role_binding, created?} <- ensure_cluster_admin_role_binding(api_client),
           {:ok, _audit_log} <-
             maybe_insert_role_binding_audit_log(api_client, role_binding, created?, opts) do
        {:ok, role_binding}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec has_inference_client_access?(
          ServiceAccount.t() | Ecto.UUID.t(),
          Tenant.t() | Ecto.UUID.t()
        ) ::
          boolean()
  def has_inference_client_access?(service_account_or_id, tenant_or_id) do
    with {:ok, api_client} <- resolve_api_client(service_account_or_id),
         {:ok, tenant} <- resolve_tenant(tenant_or_id) do
      inference_client_role_binding_exists?(api_client.id, tenant.id)
    else
      _ -> false
    end
  end

  @spec has_cluster_admin_access?(ServiceAccount.t() | Ecto.UUID.t()) :: boolean()
  def has_cluster_admin_access?(service_account_or_id) do
    case resolve_api_client(service_account_or_id) do
      {:ok, api_client} -> cluster_admin_role_binding_exists?(api_client.id)
      {:error, _reason} -> false
    end
  end

  @spec authorize_public_inference(api_key_auth_result()) :: :ok | {:error, authorization_error()}
  def authorize_public_inference(%{principal_type: :tenant}), do: :ok

  def authorize_public_inference(%{
        principal_type: :service_account,
        principal_id: service_account_id,
        tenant_id: tenant_id
      }) do
    with {:ok, api_client} <- resolve_api_client(service_account_id),
         false <- ServiceAccount.disabled?(api_client),
         true <- inference_client_role_binding_exists?(api_client.id, tenant_id) do
      :ok
    else
      true -> {:error, :api_client_disabled}
      false -> {:error, :missing_inference_client_access}
      {:error, _reason} -> {:error, :missing_inference_client_access}
    end
  end

  @spec authorize_admin_api(api_key_auth_result()) :: :ok | {:error, :admin_required}
  def authorize_admin_api(%{
        principal_type: :service_account,
        principal_id: service_account_id
      }) do
    with {:ok, api_client} <- resolve_api_client(service_account_id),
         false <- ServiceAccount.disabled?(api_client),
         true <- cluster_admin_role_binding_exists?(api_client.id) do
      :ok
    else
      _ -> {:error, :admin_required}
    end
  end

  def authorize_admin_api(_auth_context), do: {:error, :admin_required}

  @spec authorize_operator_api(api_key_auth_result()) :: :ok | {:error, :operator_required}
  def authorize_operator_api(%{
        principal_type: :service_account,
        principal_id: service_account_id
      }) do
    with {:ok, api_client} <- resolve_api_client(service_account_id),
         false <- ServiceAccount.disabled?(api_client),
         true <- cluster_operator_or_admin_role_binding_exists?(api_client.id) do
      :ok
    else
      _ -> {:error, :operator_required}
    end
  end

  def authorize_operator_api(_auth_context), do: {:error, :operator_required}

  @spec bulk_validate_api_clients([map()], keyword()) ::
          {:ok, ApiClientProvisioning.plan()}
          | {:error, [ApiClientProvisioning.validation_error()]}
  def bulk_validate_api_clients(rows, opts \\ []), do: ApiClientProvisioning.validate(rows, opts)

  @spec bulk_apply_api_clients([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def bulk_apply_api_clients(rows, opts \\ []), do: ApiClientProvisioning.apply(rows, opts)

  @spec mark_provisioning_batch_output_failed(Ecto.UUID.t(), map()) ::
          {:ok, ProvisioningBatch.t()} | {:error, Changeset.t() | :provisioning_batch_not_found}
  def mark_provisioning_batch_output_failed(batch_id, error_summary),
    do: ApiClientProvisioning.mark_output_failed(batch_id, error_summary)

  @spec authenticate_api_key(String.t()) ::
          {:ok, api_key_auth_result()} | {:error, api_key_auth_error()}
  def authenticate_api_key(token) when is_binary(token) do
    with {:ok, token_prefix} <- ApiKeySecret.token_prefix(token),
         %ApiKey{} = api_key <- fetch_api_key_by_prefix(token_prefix),
         true <- ApiKeySecret.verify(token, api_key.secret_hash) do
      authenticate_active_api_key(api_key)
    else
      :error -> {:error, :invalid_api_key}
      nil -> {:error, :invalid_api_key}
      false -> {:error, :invalid_api_key}
    end
  end

  def authenticate_api_key(_token), do: {:error, :invalid_api_key}

  @spec touch_api_key_last_used(Ecto.UUID.t()) :: :ok | {:error, :api_key_not_found}
  def touch_api_key_last_used(api_key_id) do
    touched_at = utc_now()

    case Repo.update_all(from(api_key in ApiKey, where: api_key.id == ^api_key_id),
           set: [last_used_at: touched_at]
         ) do
      {1, _} -> :ok
      _ -> {:error, :api_key_not_found}
    end
  end

  @spec audit_api_key_auth_failure(String.t() | nil, auth_failure_reason()) ::
          :ok | :skipped | {:error, Changeset.t()}
  def audit_api_key_auth_failure(token, reason) do
    case fetch_api_key_for_audit(token) do
      {:ok, api_key, token_prefix} ->
        %AuditLog{}
        |> audit_log_impl().changeset(%{
          tenant_id: api_key_effective_tenant_id(api_key),
          api_key_id: api_key.id,
          actor_type: "system",
          actor_id: nil,
          action: "api_key.auth_failed",
          target_type: "api_key",
          target_id: api_key.id,
          occurred_at: utc_now(),
          payload: %{"reason" => Atom.to_string(reason), "token_prefix" => token_prefix}
        })
        |> AuditWriter.insert()
        |> case do
          {:ok, _audit_log} -> :ok
          {:error, changeset} -> {:error, sanitize_changeset(changeset)}
        end

      :skip ->
        :skipped
    end
  end

  @doc """
  Records a best-effort `support_bundle.generated` audit event when the Repo is running.

  The payload is intentionally limited to bundle metadata and excludes local
  support-root paths.
  """
  @spec audit_support_bundle_generated(map()) :: :ok | :skipped | {:error, Changeset.t()}
  def audit_support_bundle_generated(attrs) when is_map(attrs) do
    if repo_started?() do
      attrs = normalize_attrs(attrs)

      %AuditLog{}
      |> audit_log_impl().changeset(%{
        tenant_id: legacy_tenant_id(),
        api_key_id: nil,
        actor_type: "operator",
        actor_id: nil,
        action: "support_bundle.generated",
        target_type: "support_bundle",
        target_id: Map.get(attrs, "archive_name"),
        occurred_at: utc_now(),
        payload: support_bundle_audit_payload(attrs)
      })
      |> AuditWriter.insert()
      |> case do
        {:ok, _audit_log} -> :ok
        {:error, changeset} -> {:error, sanitize_changeset(changeset)}
      end
    else
      :skipped
    end
  end

  def audit_support_bundle_generated(_attrs), do: audit_support_bundle_generated(%{})

  @spec insert_cluster_audit_log(map() | keyword()) ::
          {:ok, AuditLog.t()} | {:error, Changeset.t()}
  def insert_cluster_audit_log(attrs) do
    attrs = normalize_attrs(attrs)

    %AuditLog{}
    |> audit_log_impl().changeset(%{
      scope: "cluster",
      tenant_id: nil,
      api_key_id: nil,
      actor_type: Map.get(attrs, "actor_type", "operator"),
      actor_id: Map.get(attrs, "actor_id"),
      action: Map.get(attrs, "action"),
      target_type: Map.get(attrs, "target_type"),
      target_id: Map.get(attrs, "target_id"),
      occurred_at: Map.get(attrs, "occurred_at", utc_now()),
      payload: Map.get(attrs, "payload", %{})
    })
    |> AuditWriter.insert()
  end

  @spec revoke_api_key(ApiKey.t() | Ecto.UUID.t()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :api_key_not_found}
  @spec revoke_api_key(ApiKey.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :api_key_not_found}
  def revoke_api_key(api_key_or_id, opts \\ [])

  def revoke_api_key(%ApiKey{id: api_key_id}, opts), do: revoke_api_key(api_key_id, opts)

  def revoke_api_key(api_key_id, opts) when is_list(opts) do
    AuditWriter.transaction(fn ->
      with {:ok, api_key_id} <- normalize_api_key_id(api_key_id),
           {:ok, api_key} <- lock_api_key(api_key_id),
           {:ok, api_key} <- revoke_locked_api_key(api_key, opts) do
        {:ok, redact_api_key(api_key)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec revoke_api_key(Tenant.t() | Ecto.UUID.t(), ApiKey.t() | Ecto.UUID.t()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :tenant_not_found | :api_key_not_found}
  @spec revoke_api_key(Tenant.t() | Ecto.UUID.t(), ApiKey.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :tenant_not_found | :api_key_not_found}

  def revoke_api_key(%Tenant{id: tenant_id}, api_key_or_id),
    do: revoke_api_key(tenant_id, api_key_or_id, [])

  def revoke_api_key(tenant_id, %ApiKey{id: api_key_id}),
    do: revoke_api_key(tenant_id, api_key_id, [])

  def revoke_api_key(tenant_id, api_key_id) when is_binary(tenant_id) and is_binary(api_key_id),
    do: revoke_api_key(tenant_id, api_key_id, [])

  def revoke_api_key(%Tenant{id: tenant_id}, api_key_or_id, opts),
    do: revoke_api_key(tenant_id, api_key_or_id, opts)

  def revoke_api_key(tenant_id, %ApiKey{id: api_key_id}, opts),
    do: revoke_api_key(tenant_id, api_key_id, opts)

  def revoke_api_key(tenant_id, api_key_id, opts)
      when is_binary(tenant_id) and is_binary(api_key_id) do
    AuditWriter.transaction(fn ->
      with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
           {:ok, _tenant} <- fetch_tenant(tenant_id),
           {:ok, api_key_id} <- normalize_api_key_id(api_key_id),
           {:ok, api_key} <- lock_api_key_for_tenant(api_key_id, tenant_id),
           {:ok, api_key} <- revoke_locked_api_key(api_key, opts) do
        {:ok, redact_api_key(api_key)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  def revoke_api_key(_tenant_id, _api_key_id, _opts), do: {:error, :tenant_not_found}

  @spec list_tenants() :: [Tenant.t()]
  def list_tenants do
    Tenant
    |> order_by([tenant], asc: tenant.slug)
    |> Repo.all()
  end

  @spec has_active_api_keys?() :: boolean()
  def has_active_api_keys? do
    now = utc_now()

    tenant_direct_active_api_keys?(now) or service_account_inference_tokens?(now)
  end

  defp tenant_direct_active_api_keys?(now) do
    ApiKey
    |> active_api_key_query(now)
    |> where([api_key], not is_nil(api_key.tenant_id))
    |> where([api_key], is_nil(api_key.service_account_id))
    |> Repo.exists?()
  end

  defp service_account_inference_tokens?(now) do
    ApiKey
    |> active_api_key_query(now)
    |> where([api_key], is_nil(api_key.tenant_id))
    |> where([api_key], not is_nil(api_key.service_account_id))
    |> join(:inner, [api_key], service_account in ServiceAccount,
      on: service_account.id == api_key.service_account_id and is_nil(service_account.disabled_at)
    )
    |> join(:inner, [_api_key, service_account], role_binding in RoleBinding,
      on:
        role_binding.principal_type == :service_account and
          role_binding.principal_id == service_account.id and
          role_binding.role == :inference_client and
          role_binding.tenant_scope_id == service_account.tenant_id
    )
    |> Repo.exists?()
  end

  defp active_api_key_query(query, now) do
    query
    |> where([api_key], is_nil(api_key.revoked_at))
    |> where([api_key], is_nil(api_key.expires_at) or api_key.expires_at > ^now)
  end

  @spec get_tenant(Tenant.t() | Ecto.UUID.t()) :: {:ok, Tenant.t()} | {:error, :tenant_not_found}
  def get_tenant(%Tenant{} = tenant), do: {:ok, tenant}

  def get_tenant(tenant_id) do
    with {:ok, tenant_id} <- normalize_tenant_id(tenant_id) do
      fetch_tenant(tenant_id)
    end
  end

  @spec list_api_keys_for_tenant(Tenant.t() | Ecto.UUID.t()) ::
          {:ok, [ApiKey.t()]} | {:error, :tenant_not_found}
  def list_api_keys_for_tenant(%Tenant{id: tenant_id}),
    do: list_api_keys_for_tenant(tenant_id)

  def list_api_keys_for_tenant(tenant_id) do
    with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
         {:ok, _tenant} <- fetch_tenant(tenant_id) do
      api_keys =
        ApiKey
        |> where([k], k.tenant_id == ^tenant_id)
        |> order_by([k], desc: k.inserted_at, desc: k.id)
        |> Repo.all()
        |> Enum.map(&redact_api_key/1)

      {:ok, api_keys}
    end
  end

  defp insert_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(%{
      slug: Map.get(attrs, "slug"),
      name: Map.get(attrs, "name"),
      request_body_capture_mode: Map.get(attrs, "request_body_capture_mode", :metadata)
    })
    |> Repo.insert()
  end

  defp insert_api_key(%Tenant{} = tenant, attrs, generated) do
    %ApiKey{}
    |> ApiKey.tenant_direct_changeset(%{
      tenant_id: tenant.id,
      name: Map.get(attrs, "name"),
      token_prefix: generated.token_prefix,
      secret_hash: generated.secret_hash
    })
    |> Repo.insert()
  end

  defp fetch_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :tenant_not_found}
    end
  end

  defp resolve_tenant(%Tenant{} = tenant), do: {:ok, tenant}

  defp resolve_tenant(tenant_id) do
    with {:ok, tenant_id} <- normalize_tenant_id(tenant_id) do
      fetch_tenant(tenant_id)
    end
  end

  defp upsert_api_client_row(%Tenant{} = tenant, attrs) do
    attrs = api_client_attrs(tenant, attrs)

    with {:ok, api_client} <- find_api_client_for_upsert(tenant.id, attrs) do
      case api_client do
        nil ->
          %ServiceAccount{}
          |> ServiceAccount.changeset(attrs)
          |> Repo.insert()
          |> tag_api_client_action(:created)

        %ServiceAccount{} = api_client ->
          api_client
          |> ServiceAccount.changeset(attrs)
          |> Repo.update()
          |> tag_api_client_action(:updated)
      end
    end
  end

  defp api_client_attrs(%Tenant{} = tenant, attrs) do
    %{
      "tenant_id" => tenant.id,
      "name" => trim_string(Map.get(attrs, "name") || Map.get(attrs, "api_client")),
      "owner_contact" => trim_string(Map.get(attrs, "owner_contact")),
      "owner_name" => blank_to_nil(Map.get(attrs, "owner_name")),
      "team" => blank_to_nil(Map.get(attrs, "team")),
      "external_ref" => blank_to_nil(Map.get(attrs, "external_ref")),
      "description" => blank_to_nil(Map.get(attrs, "description")),
      "purpose" => blank_to_nil(Map.get(attrs, "purpose")),
      "metadata" => Map.get(attrs, "metadata") || %{}
    }
  end

  defp find_api_client_for_upsert(tenant_id, %{
         "external_ref" => external_ref,
         "name" => name
       })
       when is_binary(external_ref) do
    by_external_ref =
      Repo.get_by(ServiceAccount, tenant_id: tenant_id, external_ref: external_ref)

    by_name = Repo.get_by(ServiceAccount, tenant_id: tenant_id, name: name)

    resolve_api_client_for_upsert(by_external_ref, by_name)
  end

  defp find_api_client_for_upsert(tenant_id, %{"name" => name}) when is_binary(name) do
    {:ok, Repo.get_by(ServiceAccount, tenant_id: tenant_id, name: name)}
  end

  defp find_api_client_for_upsert(_tenant_id, _attrs), do: {:ok, nil}

  defp resolve_api_client_for_upsert(
         %ServiceAccount{id: external_ref_id} = by_external_ref,
         %ServiceAccount{id: name_id}
       )
       when external_ref_id == name_id do
    {:ok, by_external_ref}
  end

  defp resolve_api_client_for_upsert(%ServiceAccount{}, %ServiceAccount{}) do
    {:error, api_client_identity_conflict_changeset()}
  end

  defp resolve_api_client_for_upsert(%ServiceAccount{} = by_external_ref, nil) do
    {:ok, by_external_ref}
  end

  defp resolve_api_client_for_upsert(nil, %ServiceAccount{} = by_name) do
    {:ok, by_name}
  end

  defp resolve_api_client_for_upsert(nil, nil), do: {:ok, nil}

  defp api_client_identity_conflict_changeset do
    %ServiceAccount{}
    |> Changeset.change()
    |> Changeset.add_error(:external_ref, "and name refer to different existing API Clients")
  end

  defp tag_api_client_action({:ok, api_client}, action), do: {:ok, api_client, action}
  defp tag_api_client_action({:error, reason}, _action), do: {:error, reason}

  defp api_client_audit_action(:created), do: "service_account.created"
  defp api_client_audit_action(:updated), do: "service_account.updated"

  defp api_keys_preload_query do
    from(api_key in ApiKey, order_by: [desc: api_key.inserted_at, desc: api_key.id])
  end

  defp role_bindings_preload_query do
    from(role_binding in RoleBinding,
      order_by: [asc: role_binding.role, asc: role_binding.inserted_at, asc: role_binding.id]
    )
  end

  defp redact_service_account_api_keys(%ServiceAccount{} = api_client) do
    if Ecto.assoc_loaded?(api_client.api_keys) do
      %ServiceAccount{api_client | api_keys: Enum.map(api_client.api_keys, &redact_api_key/1)}
    else
      api_client
    end
  end

  defp fetch_api_client_for_tenant(tenant_id, service_account_id) do
    api_client =
      ServiceAccount
      |> where([service_account], service_account.tenant_id == ^tenant_id)
      |> where([service_account], service_account.id == ^service_account_id)
      |> preload(
        api_keys: ^api_keys_preload_query(),
        role_bindings: ^role_bindings_preload_query()
      )
      |> Repo.one()

    case api_client do
      %ServiceAccount{} = api_client -> {:ok, api_client}
      nil -> {:error, :api_client_not_found}
    end
  end

  defp resolve_api_client(%ServiceAccount{id: service_account_id}),
    do: resolve_api_client(service_account_id)

  defp resolve_api_client(service_account_id) do
    with {:ok, service_account_id} <- normalize_service_account_id(service_account_id) do
      service_account_id
      |> fetch_api_client()
      |> case do
        {:ok, api_client} -> {:ok, api_client}
        {:error, :api_client_not_found} -> {:error, :api_client_not_found}
      end
    end
  end

  defp fetch_api_client(service_account_id) do
    case Repo.get(ServiceAccount, service_account_id) do
      %ServiceAccount{} = api_client -> {:ok, api_client}
      nil -> {:error, :api_client_not_found}
    end
  end

  defp lock_api_client_for_tenant(tenant_id, service_account_id) do
    api_client =
      ServiceAccount
      |> where([service_account], service_account.tenant_id == ^tenant_id)
      |> where([service_account], service_account.id == ^service_account_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case api_client do
      %ServiceAccount{} = api_client -> {:ok, api_client}
      nil -> {:error, :api_client_not_found}
    end
  end

  defp disable_locked_api_client(%ServiceAccount{disabled_at: %DateTime{}} = api_client),
    do: {:ok, api_client, false}

  defp disable_locked_api_client(%ServiceAccount{} = api_client) do
    api_client
    |> Changeset.change(disabled_at: utc_now())
    |> Repo.update()
    |> case do
      {:ok, api_client} -> {:ok, api_client, true}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp ensure_api_client_enabled(%ServiceAccount{} = api_client) do
    if ServiceAccount.disabled?(api_client), do: {:error, :api_client_disabled}, else: :ok
  end

  defp insert_service_account_api_key(%ServiceAccount{} = api_client, attrs, generated) do
    %ApiKey{}
    |> ApiKey.service_account_owned_changeset(%{
      service_account_id: api_client.id,
      name: Map.get(attrs, "name") || Map.get(attrs, "key_name"),
      token_prefix: generated.token_prefix,
      secret_hash: generated.secret_hash,
      expires_at: Map.get(attrs, "expires_at")
    })
    |> Repo.insert()
  end

  defp revoke_active_service_account_tokens(%ServiceAccount{} = api_client, token_name, opts)
       when is_binary(token_name) and token_name != "" do
    now = utc_now()

    api_keys =
      ApiKey
      |> where([api_key], api_key.service_account_id == ^api_client.id)
      |> where([api_key], api_key.name == ^token_name)
      |> where([api_key], is_nil(api_key.revoked_at))
      |> where([api_key], is_nil(api_key.expires_at) or api_key.expires_at > ^now)
      |> lock("FOR UPDATE")
      |> Repo.all()

    Enum.reduce_while(api_keys, {:ok, []}, fn api_key, {:ok, revoked_keys} ->
      case revoke_locked_api_key(api_key, opts) do
        {:ok, revoked} -> {:cont, {:ok, [revoked | revoked_keys]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, revoked_keys} -> {:ok, Enum.reverse(revoked_keys)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp revoke_active_service_account_tokens(_api_client, _token_name, _opts), do: {:ok, []}

  defp ensure_inference_client_role_binding(%ServiceAccount{} = api_client, %Tenant{} = tenant) do
    cond do
      api_client.tenant_id != tenant.id ->
        {:error, :tenant_not_found}

      role_binding = fetch_inference_client_role_binding(api_client.id, tenant.id) ->
        {:ok, role_binding, false}

      true ->
        insert_inference_client_role_binding(api_client, tenant)
    end
  end

  defp ensure_cluster_admin_role_binding(%ServiceAccount{} = api_client) do
    case fetch_cluster_admin_role_binding(api_client.id) do
      %RoleBinding{} = role_binding ->
        {:ok, role_binding, false}

      nil ->
        insert_cluster_admin_role_binding(api_client)
    end
  end

  defp insert_inference_client_role_binding(%ServiceAccount{} = api_client, %Tenant{} = tenant) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :inference_client,
      tenant_scope_id: tenant.id
    })
    |> Repo.insert()
    |> case do
      {:ok, role_binding} ->
        {:ok, role_binding, true}

      {:error, changeset} ->
        case fetch_inference_client_role_binding(api_client.id, tenant.id) do
          %RoleBinding{} = role_binding -> {:ok, role_binding, false}
          nil -> {:error, changeset}
        end
    end
  end

  defp insert_cluster_admin_role_binding(%ServiceAccount{} = api_client) do
    attempted =
      %RoleBinding{}
      |> RoleBinding.changeset(%{
        principal_type: :service_account,
        principal_id: api_client.id,
        role: :admin,
        tenant_scope_id: nil
      })

    attempted
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment, "(principal_type, principal_id, role) WHERE tenant_scope_id IS NULL"},
      returning: true
    )
    |> case do
      {:ok, %RoleBinding{} = attempted_role_binding} ->
        case fetch_cluster_admin_role_binding(api_client.id) do
          %RoleBinding{} = role_binding ->
            {:ok, role_binding, role_binding.id == attempted_role_binding.id}

          nil ->
            {:error, attempted}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp inference_client_role_binding_exists?(service_account_id, tenant_id) do
    case fetch_inference_client_role_binding(service_account_id, tenant_id) do
      %RoleBinding{} -> true
      nil -> false
    end
  end

  defp fetch_inference_client_role_binding(service_account_id, tenant_id) do
    Repo.get_by(RoleBinding,
      principal_type: :service_account,
      principal_id: service_account_id,
      role: :inference_client,
      tenant_scope_id: tenant_id
    )
  end

  defp cluster_admin_role_binding_exists?(service_account_id) do
    case fetch_cluster_admin_role_binding(service_account_id) do
      %RoleBinding{} -> true
      nil -> false
    end
  end

  defp cluster_operator_role_binding_exists?(service_account_id) do
    case fetch_cluster_operator_role_binding(service_account_id) do
      %RoleBinding{} -> true
      nil -> false
    end
  end

  defp cluster_operator_or_admin_role_binding_exists?(service_account_id) do
    cluster_operator_role_binding_exists?(service_account_id) or
      cluster_admin_role_binding_exists?(service_account_id)
  end

  defp fetch_cluster_admin_role_binding(service_account_id) do
    RoleBinding
    |> where([role_binding], role_binding.principal_type == :service_account)
    |> where([role_binding], role_binding.principal_id == ^service_account_id)
    |> where([role_binding], role_binding.role == :admin)
    |> where([role_binding], is_nil(role_binding.tenant_scope_id))
    |> Repo.one()
  end

  defp fetch_cluster_operator_role_binding(service_account_id) do
    RoleBinding
    |> where([role_binding], role_binding.principal_type == :service_account)
    |> where([role_binding], role_binding.principal_id == ^service_account_id)
    |> where([role_binding], role_binding.role == :operator)
    |> where([role_binding], is_nil(role_binding.tenant_scope_id))
    |> Repo.one()
  end

  defp fetch_api_key_by_prefix(token_prefix) do
    ApiKey
    |> where([api_key], api_key.token_prefix == ^token_prefix)
    |> preload(:service_account)
    |> Repo.one()
  end

  defp authenticate_active_api_key(%ApiKey{revoked_at: %DateTime{}}),
    do: {:error, :api_key_revoked}

  defp authenticate_active_api_key(%ApiKey{} = api_key) do
    if ApiKey.expired?(api_key, utc_now()) do
      {:error, :api_key_expired}
    else
      resolve_api_key_principal(api_key)
    end
  end

  defp resolve_api_key_principal(%ApiKey{tenant_id: tenant_id, service_account_id: nil} = api_key)
       when is_binary(tenant_id) do
    {:ok,
     %{
       tenant_id: tenant_id,
       principal_type: :tenant,
       principal_id: tenant_id,
       service_account_id: nil,
       api_key_id: api_key.id
     }}
  end

  defp resolve_api_key_principal(
         %ApiKey{
           tenant_id: nil,
           service_account_id: service_account_id,
           service_account: %ServiceAccount{} = service_account
         } = api_key
       )
       when is_binary(service_account_id) do
    {:ok,
     %{
       tenant_id: service_account.tenant_id,
       principal_type: :service_account,
       principal_id: service_account.id,
       service_account_id: service_account.id,
       api_key_id: api_key.id
     }}
  end

  defp resolve_api_key_principal(_api_key), do: {:error, :invalid_api_key}

  defp fetch_api_key_for_audit(token) when is_binary(token) do
    with {:ok, token_prefix} <- ApiKeySecret.token_prefix(token),
         %ApiKey{} = api_key <- fetch_api_key_by_prefix(token_prefix) do
      {:ok, api_key, token_prefix}
    else
      _ -> :skip
    end
  end

  defp fetch_api_key_for_audit(_token), do: :skip

  defp support_bundle_audit_payload(attrs) do
    attrs
    |> Map.take(["archive_name", "bundle_format", "generated_at", "max_log_bytes"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp repo_started?, do: Process.whereis(Repo) != nil

  defp normalize_generated_secret(%{token: token}) when is_binary(token),
    do: normalize_generated_secret(token)

  defp normalize_generated_secret(token) when is_binary(token) do
    case ApiKeySecret.canonical_token_prefix(token) do
      {:ok, token_prefix} ->
        {:ok, %{token: token, token_prefix: token_prefix, secret_hash: ApiKeySecret.hash(token)}}

      :error ->
        {:error, :invalid_api_key_secret}
    end
  end

  defp normalize_generated_secret(_generated), do: {:error, :invalid_api_key_secret}

  defp normalize_tenant_id(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, tenant_id} -> {:ok, tenant_id}
      :error -> {:error, :tenant_not_found}
    end
  end

  defp normalize_api_key_id(api_key_id) do
    case Ecto.UUID.cast(api_key_id) do
      {:ok, api_key_id} -> {:ok, api_key_id}
      :error -> {:error, :api_key_not_found}
    end
  end

  defp normalize_service_account_id(service_account_id) do
    case Ecto.UUID.cast(service_account_id) do
      {:ok, service_account_id} -> {:ok, service_account_id}
      :error -> {:error, :api_client_not_found}
    end
  end

  defp lock_api_key(api_key_id) do
    api_key =
      ApiKey
      |> where([api_key], api_key.id == ^api_key_id)
      |> preload(:service_account)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case api_key do
      %ApiKey{} = api_key -> {:ok, api_key}
      nil -> {:error, :api_key_not_found}
    end
  end

  defp lock_api_key_for_tenant(api_key_id, tenant_id) do
    with {:ok, api_key} <- lock_api_key(api_key_id),
         ^tenant_id <- api_key_effective_tenant_id(api_key) do
      {:ok, api_key}
    else
      {:error, reason} -> {:error, reason}
      _other_tenant -> {:error, :api_key_not_found}
    end
  end

  defp revoke_locked_api_key(%ApiKey{revoked_at: %DateTime{}} = api_key, _opts),
    do: {:ok, api_key}

  defp revoke_locked_api_key(%ApiKey{} = api_key, opts) do
    revoked_at = utc_now()

    with {:ok, api_key} <- api_key |> Changeset.change(revoked_at: revoked_at) |> Repo.update(),
         {:ok, _audit_log} <-
           insert_api_key_audit_log(api_key, "api_key.revoked", revoked_at, opts) do
      {:ok, api_key}
    end
  end

  defp insert_api_key_audit_log(%ApiKey{} = api_key, action, occurred_at, opts \\ []) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: api_key_effective_tenant_id(api_key),
      api_key_id: api_key.id,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: action,
      target_type: "api_key",
      target_id: api_key.id,
      occurred_at: occurred_at,
      payload: put_audit_context_payload(api_key_audit_payload(api_key), opts)
    })
    |> AuditWriter.insert()
  end

  defp insert_api_client_audit_log(%ServiceAccount{} = api_client, action, occurred_at, opts) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: api_client.tenant_id,
      api_key_id: nil,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: action,
      target_type: "service_account",
      target_id: api_client.id,
      occurred_at: occurred_at,
      payload: api_client_audit_payload(api_client, opts)
    })
    |> AuditWriter.insert()
  end

  defp maybe_insert_disable_audit_log(_api_client, false, _opts), do: {:ok, nil}

  defp maybe_insert_disable_audit_log(%ServiceAccount{} = api_client, true, opts) do
    insert_api_client_audit_log(
      api_client,
      "service_account.disabled",
      api_client.disabled_at,
      opts
    )
  end

  defp insert_service_account_api_key_audit_log(
         %ServiceAccount{} = api_client,
         %ApiKey{} = api_key,
         action,
         occurred_at,
         opts
       ) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: api_client.tenant_id,
      api_key_id: api_key.id,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: action,
      target_type: "api_key",
      target_id: api_key.id,
      occurred_at: occurred_at,
      payload:
        api_key_audit_payload(api_key)
        |> Map.put("service_account_id", api_client.id)
        |> put_audit_context_payload(opts)
    })
    |> AuditWriter.insert()
  end

  defp insert_key_rotation_audit_log(
         %ServiceAccount{} = api_client,
         %ApiKey{} = api_key,
         revoked_keys,
         occurred_at,
         opts
       ) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: api_client.tenant_id,
      api_key_id: api_key.id,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: "api_key.rotated",
      target_type: "api_key",
      target_id: api_key.id,
      occurred_at: occurred_at,
      payload:
        %{
          "name" => api_key.name,
          "token_prefix" => api_key.token_prefix,
          "service_account_id" => api_client.id,
          "revoked_api_key_ids" => Enum.map(revoked_keys, & &1.id),
          "revoked_token_prefixes" => Enum.map(revoked_keys, & &1.token_prefix)
        }
        |> put_audit_context_payload(opts)
    })
    |> AuditWriter.insert()
  end

  defp maybe_insert_key_rotation_audit_log(_api_client, _api_key, [], _occurred_at, _opts),
    do: {:ok, nil}

  defp maybe_insert_key_rotation_audit_log(api_client, api_key, revoked_keys, occurred_at, opts) do
    insert_key_rotation_audit_log(api_client, api_key, revoked_keys, occurred_at, opts)
  end

  defp maybe_insert_role_binding_audit_log(_api_client, _role_binding, false, _opts),
    do: {:ok, nil}

  defp maybe_insert_role_binding_audit_log(
         %ServiceAccount{} = api_client,
         %RoleBinding{} = role_binding,
         true,
         opts
       ) do
    scope_attrs = role_binding_audit_scope_attrs(role_binding)

    %AuditLog{}
    |> audit_log_impl().changeset(
      Map.merge(scope_attrs, %{
        api_key_id: nil,
        actor_type: audit_actor_type(opts),
        actor_id: audit_actor_id(opts),
        action: "role_binding.created",
        target_type: "role_binding",
        target_id: role_binding.id,
        occurred_at: utc_now(),
        payload:
          %{
            "principal_type" => "service_account",
            "principal_id" => api_client.id,
            "role" => Atom.to_string(role_binding.role),
            "tenant_scope_id" => role_binding.tenant_scope_id
          }
          |> put_audit_context_payload(opts)
      })
    )
    |> AuditWriter.insert()
  end

  defp role_binding_audit_scope_attrs(%RoleBinding{tenant_scope_id: nil}) do
    %{scope: "cluster", tenant_id: nil}
  end

  defp role_binding_audit_scope_attrs(%RoleBinding{tenant_scope_id: tenant_scope_id}) do
    %{scope: "tenant", tenant_id: tenant_scope_id}
  end

  defp insert_tenant_audit_log(%Tenant{} = tenant, action, occurred_at) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: tenant.id,
      api_key_id: nil,
      actor_type: "system",
      actor_id: nil,
      action: action,
      target_type: "tenant",
      target_id: tenant.id,
      occurred_at: occurred_at,
      payload: %{"slug" => tenant.slug, "name" => tenant.name}
    })
    |> AuditWriter.insert()
  end

  defp api_key_effective_tenant_id(%ApiKey{tenant_id: tenant_id}) when is_binary(tenant_id),
    do: tenant_id

  defp api_key_effective_tenant_id(%ApiKey{service_account: %ServiceAccount{} = api_client}),
    do: api_client.tenant_id

  defp api_key_effective_tenant_id(%ApiKey{service_account_id: service_account_id})
       when is_binary(service_account_id) do
    service_account_id
    |> then(&Repo.get!(ServiceAccount, &1))
    |> Map.fetch!(:tenant_id)
  end

  defp api_key_audit_payload(%ApiKey{} = api_key) do
    %{
      "name" => api_key.name,
      "token_prefix" => api_key.token_prefix,
      "owner_type" => api_key_owner_type(api_key)
    }
    |> maybe_put_payload("service_account_id", api_key.service_account_id)
    |> maybe_put_payload("expires_at", maybe_iso8601(api_key.expires_at))
  end

  defp api_key_owner_type(%ApiKey{tenant_id: tenant_id}) when is_binary(tenant_id), do: "tenant"

  defp api_key_owner_type(%ApiKey{service_account_id: service_account_id})
       when is_binary(service_account_id), do: "service_account"

  defp api_client_audit_payload(%ServiceAccount{} = api_client, opts) do
    %{
      "name" => api_client.name,
      "owner_contact" => api_client.owner_contact
    }
    |> maybe_put_payload("owner_name", api_client.owner_name)
    |> maybe_put_payload("team", api_client.team)
    |> maybe_put_payload("external_ref", api_client.external_ref)
    |> put_audit_context_payload(opts)
  end

  defp audit_actor_type(opts), do: opts |> Keyword.get(:actor_type, "system") |> to_string()
  defp audit_actor_id(opts), do: Keyword.get(opts, :actor_id)

  defp put_audit_context_payload(payload, opts) do
    payload
    |> maybe_put_payload("provisioning_batch_id", Keyword.get(opts, :provisioning_batch_id))
    |> maybe_put_payload("bulk_operation_ref", Keyword.get(opts, :bulk_operation_ref))
    |> maybe_put_payload("surface", Keyword.get(opts, :surface))
  end

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize_attrs(attrs), do: SchemaSupport.normalize_attrs(attrs)

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp api_key_secret_impl do
    Application.get_env(:orchard_controller, :governance_api_key_secret_impl, ApiKeySecret)
  end

  defp audit_log_impl do
    Application.get_env(:orchard_controller, :governance_audit_log_impl, AuditLog)
  end

  defp sanitize_changeset(%Changeset{} = changeset) do
    %Changeset{
      changeset
      | changes: Map.delete(changeset.changes, :secret_hash),
        params: sanitize_changeset_params(changeset.params),
        data: sanitize_changeset_data(changeset.data)
    }
  end

  defp sanitize_changeset_params(params) when is_map(params) do
    params
    |> Map.delete(:secret_hash)
    |> Map.delete("secret_hash")
  end

  defp sanitize_changeset_params(params), do: params

  defp sanitize_changeset_data(%ApiKey{} = api_key), do: redact_api_key(api_key)
  defp sanitize_changeset_data(data), do: data

  defp redact_api_key(%ApiKey{} = api_key), do: %ApiKey{api_key | secret_hash: nil}

  defp utc_now, do: SchemaSupport.utc_now()

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}

  defp unwrap_transaction_result({:error, %Changeset{} = changeset}),
    do: {:error, sanitize_changeset(changeset)}

  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
