defmodule Orchard.Models.Access do
  @moduledoc """
  Tenant-scoped Model access and routing-policy lifecycle.

  Access checks are deny-by-default and query Postgres on every operation.
  Mutations and their audit records commit atomically.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.Governance.{AuditLog, AuditWriter, Tenant}
  alias Orchard.Inference.AdmissionPolicy
  alias Orchard.Models.{Model, RoutingPolicy, TenantModelAccess}
  alias Orchard.Repo
  alias Orchard.SchemaSupport

  @type mutation_outcome ::
          :created
          | :enabled
          | :policy_changed
          | :unchanged
          | :disabled
          | :already_disabled
          | :revoked
          | :not_granted

  @type mutation_result :: %{
          access: TenantModelAccess.t() | nil,
          outcome: mutation_outcome()
        }

  @type routing_resolution :: keyword()

  @spec create_routing_policy(map() | keyword(), keyword()) ::
          {:ok, RoutingPolicy.t()} | {:error, Changeset.t()}
  def create_routing_policy(attrs, opts \\ []) do
    attrs = SchemaSupport.normalize_attrs(attrs)

    AuditWriter.transaction(fn ->
      with {:ok, policy} <- %RoutingPolicy{} |> RoutingPolicy.changeset(attrs) |> Repo.insert(),
           {:ok, _audit_log} <- insert_routing_policy_audit(policy, opts) do
        policy
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec list_routing_policies(:global | Tenant.t() | Ecto.UUID.t()) ::
          {:ok, [RoutingPolicy.t()]} | {:error, :tenant_not_found}
  def list_routing_policies(:global) do
    {:ok,
     RoutingPolicy
     |> where([policy], is_nil(policy.tenant_id))
     |> order_by([policy], asc: policy.name, asc: policy.id)
     |> Repo.all()}
  end

  def list_routing_policies(tenant_or_id) do
    with {:ok, tenant} <- resolve_tenant(tenant_or_id) do
      {:ok,
       RoutingPolicy
       |> where([policy], policy.tenant_id == ^tenant.id)
       |> order_by([policy], asc: policy.name, asc: policy.id)
       |> Repo.all()}
    end
  end

  @spec get_routing_policy(Ecto.UUID.t()) ::
          {:ok, RoutingPolicy.t()} | {:error, :routing_policy_not_found}
  def get_routing_policy(id) do
    with {:ok, id} <- normalize_uuid(id),
         %RoutingPolicy{} = policy <- Repo.get(RoutingPolicy, id) do
      {:ok, policy}
    else
      _reason -> {:error, :routing_policy_not_found}
    end
  end

  @spec grant_model_access(
          Tenant.t() | Ecto.UUID.t(),
          Model.t() | Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          keyword()
        ) ::
          {:ok, mutation_result()}
          | {:error,
             Changeset.t()
             | :tenant_not_found
             | :model_not_found
             | :routing_policy_not_found
             | :routing_policy_scope_mismatch}
  def grant_model_access(tenant_or_id, model_or_id, routing_policy_id \\ nil, opts \\ []) do
    with {:ok, tenant_id} <- tenant_id(tenant_or_id),
         {:ok, model_id} <- model_id(model_or_id) do
      mutate_access(tenant_id, model_id, fn ->
        grant_model_access_by_id(tenant_id, model_id, routing_policy_id, opts)
      end)
    end
  end

  @spec disable_model_access(
          Tenant.t() | Ecto.UUID.t(),
          Model.t() | Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, mutation_result()}
          | {:error, Changeset.t() | :tenant_not_found | :model_not_found}
  def disable_model_access(tenant_or_id, model_or_id, opts \\ []) do
    with {:ok, tenant_id} <- tenant_id(tenant_or_id),
         {:ok, model_id} <- model_id(model_or_id) do
      mutate_access(tenant_id, model_id, fn ->
        disable_model_access_by_id(tenant_id, model_id, opts)
      end)
    end
  end

  @spec revoke_model_access(
          Tenant.t() | Ecto.UUID.t(),
          Model.t() | Ecto.UUID.t(),
          keyword()
        ) ::
          {:ok, mutation_result()}
          | {:error, Changeset.t() | :tenant_not_found | :model_not_found}
  def revoke_model_access(tenant_or_id, model_or_id, opts \\ []) do
    with {:ok, tenant_id} <- tenant_id(tenant_or_id),
         {:ok, model_id} <- model_id(model_or_id) do
      mutate_access(tenant_id, model_id, fn ->
        revoke_model_access_by_id(tenant_id, model_id, opts)
      end)
    end
  end

  @spec list_model_access(Tenant.t() | Ecto.UUID.t()) ::
          {:ok, [TenantModelAccess.t()]} | {:error, :tenant_not_found}
  def list_model_access(tenant_or_id) do
    with {:ok, tenant} <- resolve_tenant(tenant_or_id) do
      {:ok,
       TenantModelAccess
       |> join(:inner, [access], model in assoc(access, :model))
       |> where([access], access.tenant_id == ^tenant.id)
       |> order_by([_access, model], asc: model.model_id, asc: model.version)
       |> preload([_access, model], model: model)
       |> preload(:routing_policy)
       |> Repo.all()}
    end
  end

  @spec get_model_access(Tenant.t() | Ecto.UUID.t(), Model.t() | Ecto.UUID.t()) ::
          {:ok, TenantModelAccess.t()}
          | {:error, :tenant_not_found | :model_not_found | :not_granted}
  def get_model_access(tenant_or_id, model_or_id) do
    with {:ok, tenant} <- resolve_tenant(tenant_or_id),
         {:ok, model} <- resolve_model(model_or_id),
         %TenantModelAccess{} = access <- fetch_access(tenant.id, model.id) do
      {:ok, Repo.preload(access, [:model, :routing_policy])}
    else
      nil -> {:error, :not_granted}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authorize(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, routing_resolution()} | {:error, :model_not_authorized}
  def authorize(tenant_id, model_id) do
    with {:ok, tenant_id} <- normalize_uuid(tenant_id),
         {:ok, model_id} <- normalize_uuid(model_id),
         %TenantModelAccess{enabled: true} = access <- fetch_access(tenant_id, model_id) do
      access
      |> Repo.preload(:routing_policy)
      |> routing_resolution()
      |> then(&{:ok, &1})
    else
      _reason -> {:error, :model_not_authorized}
    end
  end

  defp grant_model_access_by_id(tenant_id, model_id, routing_policy_id, opts) do
    with {:ok, tenant} <- fetch_tenant(tenant_id),
         {:ok, model} <- fetch_model(model_id),
         {:ok, policy} <- resolve_policy(routing_policy_id, tenant.id) do
      grant_locked(tenant, model, policy, opts)
    end
  end

  defp disable_model_access_by_id(tenant_id, model_id, opts) do
    with {:ok, tenant} <- fetch_tenant(tenant_id),
         {:ok, model} <- fetch_model(model_id) do
      disable_locked(tenant, model, opts)
    end
  end

  defp revoke_model_access_by_id(tenant_id, model_id, opts) do
    with {:ok, tenant} <- fetch_tenant(tenant_id),
         {:ok, model} <- fetch_model(model_id) do
      revoke_locked(tenant, model, opts)
    end
  end

  defp mutate_access(tenant_id, model_id, fun) do
    AuditWriter.transaction(fn ->
      lock_access_identity(tenant_id, model_id)

      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp grant_locked(tenant, model, policy, opts) do
    case lock_access(tenant.id, model.id) do
      nil -> create_access(tenant, model, policy, opts)
      access -> update_access(access, tenant, model, policy, opts)
    end
  end

  defp create_access(tenant, model, policy, opts) do
    attrs = %{
      tenant_id: tenant.id,
      model_id: model.id,
      routing_policy_id: policy_id(policy),
      enabled: true
    }

    with {:ok, access} <-
           %TenantModelAccess{} |> TenantModelAccess.changeset(attrs) |> Repo.insert(),
         {:ok, _audit_log} <-
           insert_access_audit(access, "tenant_model_access.granted", nil, opts) do
      {:ok, %{access: access, outcome: :created}}
    end
  end

  defp update_access(access, tenant, model, policy, opts) do
    target_policy_id = policy_id(policy)

    cond do
      access.enabled and access.routing_policy_id == target_policy_id ->
        {:ok, %{access: access, outcome: :unchanged}}

      not access.enabled ->
        persist_access_change(
          access,
          tenant,
          model,
          target_policy_id,
          :enabled,
          "tenant_model_access.enabled",
          opts
        )

      true ->
        persist_access_change(
          access,
          tenant,
          model,
          target_policy_id,
          :policy_changed,
          "tenant_model_access.policy_changed",
          opts
        )
    end
  end

  defp persist_access_change(access, tenant, model, policy_id, outcome, action, opts) do
    previous_policy_id = access.routing_policy_id

    with {:ok, updated} <-
           access
           |> TenantModelAccess.changeset(%{enabled: true, routing_policy_id: policy_id})
           |> Repo.update(),
         {:ok, _audit_log} <- insert_access_audit(updated, action, previous_policy_id, opts) do
      {:ok, %{access: %{updated | tenant: tenant, model: model}, outcome: outcome}}
    end
  end

  defp disable_locked(tenant, model, opts) do
    case lock_access(tenant.id, model.id) do
      nil ->
        {:ok, %{access: nil, outcome: :not_granted}}

      %TenantModelAccess{enabled: false} = access ->
        {:ok, %{access: access, outcome: :already_disabled}}

      access ->
        with {:ok, disabled} <-
               access |> TenantModelAccess.changeset(%{enabled: false}) |> Repo.update(),
             {:ok, _audit_log} <-
               insert_access_audit(
                 disabled,
                 "tenant_model_access.disabled",
                 access.routing_policy_id,
                 opts
               ) do
          {:ok, %{access: disabled, outcome: :disabled}}
        end
    end
  end

  defp revoke_locked(tenant, model, opts) do
    case lock_access(tenant.id, model.id) do
      nil ->
        {:ok, %{access: nil, outcome: :not_granted}}

      access ->
        with {:ok, deleted} <- Repo.delete(access),
             {:ok, _audit_log} <-
               insert_access_audit(
                 deleted,
                 "tenant_model_access.revoked",
                 access.routing_policy_id,
                 opts
               ) do
          {:ok, %{access: deleted, outcome: :revoked}}
        end
    end
  end

  defp routing_resolution(%TenantModelAccess{routing_policy: nil}) do
    AdmissionPolicy.default_routing_opts()
  end

  defp routing_resolution(%TenantModelAccess{routing_policy: %RoutingPolicy{} = policy}) do
    [
      routing_policy_id: policy.id,
      allowed_pool_ids: policy.allowed_pool_ids,
      residency_preference: policy.residency_preference,
      max_cold_start_ms: policy.max_cold_start_ms,
      queue_wait_ms: policy.max_queue_wait_ms
    ]
  end

  defp resolve_policy(nil, _tenant_id), do: {:ok, nil}

  defp resolve_policy(policy_id, tenant_id) do
    with {:ok, policy} <- get_routing_policy(policy_id),
         true <- is_nil(policy.tenant_id) or policy.tenant_id == tenant_id do
      {:ok, policy}
    else
      false -> {:error, :routing_policy_scope_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_tenant(%Tenant{} = tenant), do: fetch_tenant(tenant.id)

  defp resolve_tenant(id) do
    with {:ok, id} <- tenant_id(id), do: fetch_tenant(id)
  end

  defp fetch_tenant(id) do
    case Repo.get(Tenant, id) do
      %Tenant{} = tenant -> {:ok, tenant}
      nil -> {:error, :tenant_not_found}
    end
  end

  defp resolve_model(%Model{} = model), do: fetch_model(model.id)

  defp resolve_model(id) do
    with {:ok, id} <- model_id(id), do: fetch_model(id)
  end

  defp fetch_model(id) do
    case Repo.get(Model, id) do
      %Model{} = model -> {:ok, model}
      nil -> {:error, :model_not_found}
    end
  end

  defp tenant_id(%Tenant{id: id}), do: normalize_entity_id(id, :tenant_not_found)
  defp tenant_id(id), do: normalize_entity_id(id, :tenant_not_found)
  defp model_id(%Model{id: id}), do: normalize_entity_id(id, :model_not_found)
  defp model_id(id), do: normalize_entity_id(id, :model_not_found)

  defp normalize_entity_id(id, error) do
    case normalize_uuid(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error}
    end
  end

  defp normalize_uuid(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp normalize_uuid(_id), do: :error

  defp fetch_access(tenant_id, model_id) do
    Repo.get_by(TenantModelAccess, tenant_id: tenant_id, model_id: model_id)
  end

  defp lock_access(tenant_id, model_id) do
    TenantModelAccess
    |> where([access], access.tenant_id == ^tenant_id and access.model_id == ^model_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_access_identity(tenant_id, model_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "tenant_model_access:#{tenant_id}:#{model_id}"
    ])

    :ok
  end

  defp insert_routing_policy_audit(policy, opts) do
    scope_attrs =
      if is_nil(policy.tenant_id),
        do: %{scope: "cluster", tenant_id: nil},
        else: %{scope: "tenant", tenant_id: policy.tenant_id}

    attrs =
      Map.merge(scope_attrs, %{
        api_key_id: nil,
        actor_type: audit_actor_type(opts),
        actor_id: audit_actor_id(opts),
        action: "routing_policy.created",
        target_type: "routing_policy",
        target_id: policy.id,
        occurred_at: utc_now(),
        payload:
          %{
            "name" => policy.name,
            "tenant_id" => policy.tenant_id,
            "residency_preference" => Atom.to_string(policy.residency_preference),
            "max_cold_start_ms" => policy.max_cold_start_ms,
            "max_queue_wait_ms" => policy.max_queue_wait_ms
          }
          |> put_surface(opts)
      })

    %AuditLog{}
    |> audit_log_impl().changeset(attrs)
    |> AuditWriter.insert()
  end

  defp insert_access_audit(access, action, previous_policy_id, opts) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      scope: "tenant",
      tenant_id: access.tenant_id,
      api_key_id: nil,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: action,
      target_type: "tenant_model_access",
      target_id: "#{access.tenant_id}:#{access.model_id}",
      occurred_at: utc_now(),
      payload:
        %{
          "tenant_id" => access.tenant_id,
          "model_id" => access.model_id,
          "previous_routing_policy_id" => previous_policy_id,
          "routing_policy_id" => access.routing_policy_id,
          "enabled" => access.enabled
        }
        |> put_surface(opts)
    })
    |> AuditWriter.insert()
  end

  defp policy_id(nil), do: nil
  defp policy_id(%RoutingPolicy{id: id}), do: id

  defp audit_actor_type(opts), do: opts |> Keyword.get(:actor_type, "operator") |> to_string()
  defp audit_actor_id(opts), do: Keyword.get(opts, :actor_id)

  defp put_surface(payload, opts) do
    case Keyword.get(opts, :surface) do
      nil -> payload
      surface -> Map.put(payload, "surface", to_string(surface))
    end
  end

  defp audit_log_impl do
    Application.get_env(:orchard_controller, :governance_audit_log_impl, AuditLog)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
