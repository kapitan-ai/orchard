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

  @type api_key_creation_result :: %{api_key: %ApiKey{}, token: String.t()}

  @spec legacy_tenant_id() :: Ecto.UUID.t()
  def legacy_tenant_id, do: @legacy_tenant_id

  @spec legacy_tenant_slug() :: String.t()
  def legacy_tenant_slug, do: @legacy_tenant_slug

  @spec legacy_tenant_name() :: String.t()
  def legacy_tenant_name, do: @legacy_tenant_name

  @spec create_tenant(map() | keyword()) :: {:ok, %Tenant{}} | {:error, Changeset.t()}
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

  @spec create_api_key(%Tenant{} | Ecto.UUID.t(), map() | keyword()) ::
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

  @spec revoke_api_key(%ApiKey{} | Ecto.UUID.t()) ::
          {:ok, %ApiKey{}} | {:error, Changeset.t() | :api_key_not_found}
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

  @spec list_tenants() :: [%Tenant{}]
  def list_tenants do
    Tenant
    |> order_by([tenant], asc: tenant.slug)
    |> Repo.all()
  end

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

  defp normalize_generated_secret(%{token: token}) when is_binary(token),
    do: normalize_generated_secret(token)

  defp normalize_generated_secret(token) when is_binary(token) do
    with {:ok, token_prefix} <- ApiKeySecret.token_prefix(token) do
      {:ok, %{token: token, token_prefix: token_prefix, secret_hash: ApiKeySecret.hash(token)}}
    else
      _ -> {:error, :invalid_api_key_secret}
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
