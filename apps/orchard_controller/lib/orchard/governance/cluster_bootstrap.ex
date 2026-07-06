defmodule Orchard.Governance.ClusterBootstrap do
  @moduledoc """
  Local controller-runtime bootstrap for the first cluster-admin API Client.
  """

  import Ecto.Query

  alias Orchard.ControlPlane
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, AuditLog, RoleBinding, ServiceAccount}
  alias Orchard.Repo

  @default_client_name "orchard-bootstrap-admin"
  @default_token_name "bootstrap"

  @type mint_result :: %{
          api_client_id: Ecto.UUID.t(),
          api_token_id: Ecto.UUID.t(),
          api_token_prefix: String.t(),
          token: String.t(),
          recovery?: boolean()
        }

  @spec mint_first_admin(keyword()) :: {:ok, mint_result()} | {:error, term()}
  def mint_first_admin(opts \\ []) when is_list(opts) do
    mint_admin(opts, false)
  end

  @spec mint_recovery_admin(keyword()) :: {:ok, mint_result()} | {:error, term()}
  def mint_recovery_admin(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put(:client_name, recovery_client_name(opts))
    |> mint_admin(true)
  end

  @spec mark_output_failed(mint_result(), map()) ::
          {:ok, AuditLog.t()} | {:error, Ecto.Changeset.t()}
  def mark_output_failed(result, error_summary) when is_map(result) and is_map(error_summary) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      scope: "cluster",
      tenant_id: nil,
      api_key_id: nil,
      actor_type: "operator",
      actor_id: "local-orchardctl",
      action: "cluster_admin_bootstrap.output_failed",
      target_type: "service_account",
      target_id: Map.fetch!(result, :api_client_id),
      occurred_at: utc_now(),
      payload: %{
        "api_client_id" => Map.fetch!(result, :api_client_id),
        "api_token_id" => Map.fetch!(result, :api_token_id),
        "api_token_prefix" => Map.fetch!(result, :api_token_prefix),
        "error_summary" => sanitize_error_summary(error_summary)
      }
    })
    |> Repo.insert()
  end

  defp mint_admin(opts, recovery?) do
    with :ok <- ControlPlane.authorize_write_path(:cluster_init) do
      mint_admin_transaction(opts, recovery?)
    end
  end

  defp mint_admin_transaction(opts, recovery?) do
    Repo.transaction(fn ->
      with :ok <- lock_bootstrap_guard(),
           :ok <- maybe_ensure_not_initialized(recovery?),
           {:ok, api_client} <- insert_api_client(opts),
           {:ok, api_key, token} <- insert_api_key(api_client),
           {:ok, _role_binding} <- insert_admin_role_binding(api_client),
           {:ok, _audit_log} <- insert_bootstrap_audit_log(api_client, api_key, opts, recovery?) do
        {:ok, mint_result(api_client, api_key, token, recovery?)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp lock_bootstrap_guard do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext('orchard.cluster_bootstrap.first_admin'))")
    :ok
  end

  defp maybe_ensure_not_initialized(true), do: :ok

  defp maybe_ensure_not_initialized(false) do
    if initialized?(), do: {:error, :cluster_already_initialized}, else: :ok
  end

  defp initialized? do
    RoleBinding
    |> where([role_binding], role_binding.principal_type == :service_account)
    |> where([role_binding], role_binding.role == :admin)
    |> where([role_binding], is_nil(role_binding.tenant_scope_id))
    |> join(:inner, [role_binding], service_account in ServiceAccount,
      on:
        service_account.id == role_binding.principal_id and
          is_nil(service_account.disabled_at)
    )
    |> Repo.exists?()
  end

  defp insert_api_client(opts) do
    %ServiceAccount{}
    |> ServiceAccount.changeset(%{
      tenant_id: Governance.legacy_tenant_id(),
      name: client_name(opts),
      owner_contact: actor_id(opts),
      purpose: "cluster_admin_bootstrap"
    })
    |> Repo.insert()
  end

  defp insert_api_key(%ServiceAccount{} = api_client) do
    generated = ApiKeySecret.generate()

    %ApiKey{}
    |> ApiKey.service_account_owned_changeset(%{
      service_account_id: api_client.id,
      name: @default_token_name,
      token_prefix: generated.token_prefix,
      secret_hash: generated.secret_hash
    })
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {:ok, api_key, generated.token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_admin_role_binding(%ServiceAccount{} = api_client) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :admin,
      tenant_scope_id: nil
    })
    |> Repo.insert()
  end

  defp insert_bootstrap_audit_log(api_client, api_key, opts, recovery?) do
    %AuditLog{}
    |> AuditLog.changeset(%{
      scope: "cluster",
      tenant_id: nil,
      api_key_id: nil,
      actor_type: "operator",
      actor_id: actor_id(opts),
      action: "cluster_admin_bootstrap.minted",
      target_type: "service_account",
      target_id: api_client.id,
      occurred_at: utc_now(),
      payload: %{
        "api_client_id" => api_client.id,
        "api_token_id" => api_key.id,
        "api_token_prefix" => api_key.token_prefix,
        "recovery" => recovery?
      }
    })
    |> Repo.insert()
  end

  defp mint_result(api_client, api_key, token, recovery?) do
    %{
      api_client_id: api_client.id,
      api_token_id: api_key.id,
      api_token_prefix: api_key.token_prefix,
      token: token,
      recovery?: recovery?
    }
  end

  defp client_name(opts) do
    opts
    |> Keyword.get(:client_name, @default_client_name)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @default_client_name
      name -> name
    end
  end

  defp recovery_client_name(opts) do
    case Keyword.fetch(opts, :client_name) do
      {:ok, name} -> name
      :error -> "#{@default_client_name}-recovery-#{System.unique_integer([:positive])}"
    end
  end

  defp actor_id(opts) do
    opts
    |> Keyword.get(:actor_id, "local-orchardctl")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "local-orchardctl"
      actor_id -> actor_id
    end
  end

  defp sanitize_error_summary(summary) do
    summary
    |> Map.take(["reason", "api_token_prefix"])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp unwrap_transaction_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
