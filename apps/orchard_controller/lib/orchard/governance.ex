defmodule Orchard.Governance do
  @moduledoc """
  Governance constants and lifecycle APIs shared across the controller's current
  M1 compatibility path and the emerging M2 governance surface.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Governance.{ApiKey, ApiKeySecret, AuditLog, Tenant}
  alias Orchard.Repo

  @legacy_tenant_id "00000000-0000-0000-0000-000000000000"
  @legacy_tenant_slug "legacy"
  @legacy_tenant_name "Legacy Single Tenant"

  @type api_key_creation_result :: %{api_key: ApiKey.t(), token: String.t()}
  @type api_key_auth_result :: %{
          tenant_id: Ecto.UUID.t(),
          principal_id: Ecto.UUID.t(),
          api_key_id: Ecto.UUID.t()
        }
  @type api_key_auth_error :: :invalid_api_key | :api_key_revoked
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

    Repo.transaction(fn ->
      with {:ok, tenant} <- insert_tenant(attrs),
           {:ok, _audit_log} <- insert_tenant_audit_log(tenant, "tenant.created", utc_now()) do
        {:ok, tenant}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec create_api_key(Tenant.t() | Ecto.UUID.t(), map() | keyword()) ::
          {:ok, api_key_creation_result()}
          | {:error, Changeset.t() | :tenant_not_found | :invalid_api_key_secret}
  def create_api_key(%Tenant{id: tenant_id}, attrs), do: create_api_key(tenant_id, attrs)

  def create_api_key(tenant_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, generated} <- normalize_generated_secret(api_key_secret_impl().generate()) do
      Repo.transaction(fn ->
        with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
             {:ok, tenant} <- fetch_tenant(tenant_id),
             {:ok, api_key} <- insert_api_key(tenant, attrs, generated),
             {:ok, _audit_log} <- insert_api_key_audit_log(api_key, "api_key.created", utc_now()) do
          {:ok, %{api_key: redact_api_key(api_key), token: generated.token}}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> unwrap_transaction_result()
    end
  end

  @spec authenticate_api_key(String.t()) ::
          {:ok, api_key_auth_result()} | {:error, api_key_auth_error()}
  def authenticate_api_key(token) when is_binary(token) do
    with {:ok, token_prefix} <- ApiKeySecret.token_prefix(token),
         %ApiKey{} = api_key <- Repo.get_by(ApiKey, token_prefix: token_prefix),
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
          tenant_id: api_key.tenant_id,
          api_key_id: api_key.id,
          actor_type: "system",
          actor_id: nil,
          action: "api_key.auth_failed",
          target_type: "api_key",
          target_id: api_key.id,
          occurred_at: utc_now(),
          payload: %{"reason" => Atom.to_string(reason), "token_prefix" => token_prefix}
        })
        |> Repo.insert()
        |> case do
          {:ok, _audit_log} -> :ok
          {:error, changeset} -> {:error, sanitize_changeset(changeset)}
        end

      :skip ->
        :skipped
    end
  end

  @spec revoke_api_key(ApiKey.t() | Ecto.UUID.t()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :api_key_not_found}
  def revoke_api_key(%ApiKey{id: api_key_id}), do: revoke_api_key(api_key_id)

  def revoke_api_key(api_key_id) do
    Repo.transaction(fn ->
      with {:ok, api_key_id} <- normalize_api_key_id(api_key_id),
           {:ok, api_key} <- lock_api_key(api_key_id),
           {:ok, api_key} <- revoke_locked_api_key(api_key) do
        {:ok, redact_api_key(api_key)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  @spec list_tenants() :: [Tenant.t()]
  def list_tenants do
    Tenant
    |> order_by([tenant], asc: tenant.slug)
    |> Repo.all()
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

  @spec revoke_api_key(Tenant.t() | Ecto.UUID.t(), ApiKey.t() | Ecto.UUID.t()) ::
          {:ok, ApiKey.t()} | {:error, Changeset.t() | :tenant_not_found | :api_key_not_found}
  def revoke_api_key(%Tenant{id: tenant_id}, api_key_or_id),
    do: revoke_api_key(tenant_id, api_key_or_id)

  def revoke_api_key(tenant_id, %ApiKey{id: api_key_id}),
    do: revoke_api_key(tenant_id, api_key_id)

  def revoke_api_key(tenant_id, api_key_id) when is_binary(tenant_id) and is_binary(api_key_id) do
    Repo.transaction(fn ->
      with {:ok, tenant_id} <- normalize_tenant_id(tenant_id),
           {:ok, _tenant} <- fetch_tenant(tenant_id),
           {:ok, api_key_id} <- normalize_api_key_id(api_key_id),
           {:ok, api_key} <- lock_api_key_for_tenant(api_key_id, tenant_id),
           {:ok, api_key} <- revoke_locked_api_key(api_key) do
        {:ok, redact_api_key(api_key)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  def revoke_api_key(_tenant_id, _api_key_id), do: {:error, :tenant_not_found}

  defp insert_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(%{slug: Map.get(attrs, "slug"), name: Map.get(attrs, "name")})
    |> Repo.insert()
  end

  defp insert_api_key(%Tenant{} = tenant, attrs, generated) do
    %ApiKey{}
    |> ApiKey.changeset(%{
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

  defp authenticate_active_api_key(%ApiKey{revoked_at: %DateTime{}}),
    do: {:error, :api_key_revoked}

  defp authenticate_active_api_key(%ApiKey{} = api_key) do
    {:ok,
     %{tenant_id: api_key.tenant_id, principal_id: api_key.tenant_id, api_key_id: api_key.id}}
  end

  defp fetch_api_key_for_audit(token) when is_binary(token) do
    with {:ok, token_prefix} <- ApiKeySecret.token_prefix(token),
         %ApiKey{} = api_key <- Repo.get_by(ApiKey, token_prefix: token_prefix) do
      {:ok, api_key, token_prefix}
    else
      _ -> :skip
    end
  end

  defp fetch_api_key_for_audit(_token), do: :skip

  defp normalize_generated_secret(%{token: token}) when is_binary(token),
    do: normalize_generated_secret(token)

  defp normalize_generated_secret(token) when is_binary(token) do
    case ApiKeySecret.token_prefix(token) do
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

  defp lock_api_key(api_key_id) do
    api_key =
      ApiKey
      |> where([api_key], api_key.id == ^api_key_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case api_key do
      %ApiKey{} = api_key -> {:ok, api_key}
      nil -> {:error, :api_key_not_found}
    end
  end

  defp lock_api_key_for_tenant(api_key_id, tenant_id) do
    api_key =
      ApiKey
      |> where([k], k.id == ^api_key_id and k.tenant_id == ^tenant_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case api_key do
      %ApiKey{} = api_key -> {:ok, api_key}
      nil -> {:error, :api_key_not_found}
    end
  end

  defp revoke_locked_api_key(%ApiKey{revoked_at: %DateTime{}} = api_key), do: {:ok, api_key}

  defp revoke_locked_api_key(%ApiKey{} = api_key) do
    revoked_at = utc_now()

    with {:ok, api_key} <- api_key |> Changeset.change(revoked_at: revoked_at) |> Repo.update(),
         {:ok, _audit_log} <- insert_api_key_audit_log(api_key, "api_key.revoked", revoked_at) do
      {:ok, api_key}
    end
  end

  defp insert_api_key_audit_log(%ApiKey{} = api_key, action, occurred_at) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      tenant_id: api_key.tenant_id,
      api_key_id: api_key.id,
      actor_type: "system",
      actor_id: nil,
      action: action,
      target_type: "api_key",
      target_id: api_key.id,
      occurred_at: occurred_at,
      payload: %{"name" => api_key.name, "token_prefix" => api_key.token_prefix}
    })
    |> Repo.insert()
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
    |> Repo.insert()
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put_new(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: normalize_attrs(Enum.into(attrs, %{}))
  defp normalize_attrs(_attrs), do: %{}

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

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}

  defp unwrap_transaction_result({:error, %Changeset{} = changeset}),
    do: {:error, sanitize_changeset(changeset)}

  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
