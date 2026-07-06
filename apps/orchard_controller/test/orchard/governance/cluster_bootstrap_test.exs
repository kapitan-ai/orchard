defmodule Orchard.Governance.ClusterBootstrapTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    AuditLog,
    ClusterBootstrap,
    RoleBinding,
    ServiceAccount
  }

  alias Orchard.Repo

  describe "mint_recovery_admin/1" do
    test "OpenSpec recovery mint is additive and does not mutate the existing admin" do
      assert {:ok, first} = ClusterBootstrap.mint_first_admin(client_name: "bootstrap-primary")
      first_api_key = Repo.get!(ApiKey, first.api_token_id)
      first_api_client = Repo.get!(ServiceAccount, first.api_client_id)

      assert {:ok, recovery} =
               ClusterBootstrap.mint_recovery_admin(
                 client_name: "bootstrap-recovery",
                 actor_id: "break-glass"
               )

      assert recovery.recovery? == true
      assert recovery.api_client_id != first.api_client_id
      assert recovery.api_token_id != first.api_token_id
      assert Repo.get!(ApiKey, first.api_token_id) == first_api_key
      assert Repo.get!(ServiceAccount, first.api_client_id) == first_api_client

      assert Repo.aggregate(
               from(role_binding in RoleBinding,
                 where:
                   role_binding.principal_type == :service_account and
                     role_binding.role == :admin and
                     is_nil(role_binding.tenant_scope_id)
               ),
               :count,
               :id
             ) == 2

      audit_log =
        Repo.one!(
          from(audit_log in AuditLog,
            where:
              audit_log.action == "cluster_admin_bootstrap.minted" and
                audit_log.target_id == ^recovery.api_client_id
          )
        )

      assert audit_log.scope == "cluster"
      assert audit_log.actor_id == "break-glass"
      assert audit_log.payload["recovery"] == true
    end
  end

  describe "leader-only write gate" do
    test "OpenSpec non-leader controller refuses without mutating credential state" do
      previous = Application.get_env(:orchard_controller, :control_plane)

      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-b"
      )

      try do
        assert {:error, :controller_standby} =
                 ClusterBootstrap.mint_first_admin(client_name: "standby-admin")

        assert credential_counts() == %{
                 service_accounts: 0,
                 api_keys: 0,
                 role_bindings: 0,
                 audit_logs: 0
               }
      after
        restore_control_plane(previous)
      end
    end
  end

  describe "mint_first_admin/1" do
    test "OpenSpec guard race allows only one concurrent first-admin mint" do
      start_ref = make_ref()
      parent = self()

      task = fn client_name ->
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            ^start_ref -> ClusterBootstrap.mint_first_admin(client_name: client_name)
          end
        end)
      end

      first_task = task.("bootstrap-race-one")
      second_task = task.("bootstrap-race-two")

      assert_receive {:ready, _pid}, 1_000
      assert_receive {:ready, _pid}, 1_000

      send(first_task.pid, start_ref)
      send(second_task.pid, start_ref)

      results = [Task.await(first_task, 5_000), Task.await(second_task, 5_000)]

      assert Enum.count(results, &match?({:ok, %{token: token}} when is_binary(token), &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :cluster_already_initialized})) == 1

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1

      assert Repo.aggregate(
               from(role_binding in RoleBinding,
                 where:
                   role_binding.principal_type == :service_account and
                     role_binding.role == :admin and
                     is_nil(role_binding.tenant_scope_id)
               ),
               :count,
               :id
             ) == 1
    end

    test "SPEC.md §11.9 second init refuses with cluster_already_initialized and mutates nothing" do
      assert {:ok, _first} = ClusterBootstrap.mint_first_admin(client_name: "bootstrap-one")

      counts_before = credential_counts()

      assert {:error, :cluster_already_initialized} =
               ClusterBootstrap.mint_first_admin(client_name: "bootstrap-two")

      assert credential_counts() == counts_before
      refute Repo.get_by(ServiceAccount, name: "bootstrap-two")
    end

    test "SPEC.md §11.9 fresh cluster mints first admin credential with hash-only persistence" do
      assert {:ok, result} =
               ClusterBootstrap.mint_first_admin(
                 client_name: "bootstrap-admin",
                 actor_id: "local-operator"
               )

      assert result.token =~ "orch_"
      assert result.api_token_prefix != nil
      assert result.api_token_prefix != result.token
      assert result.api_token_id != nil
      assert result.api_client_id != nil
      assert result.recovery? == false

      api_client = Repo.get!(ServiceAccount, result.api_client_id)
      api_key = Repo.get!(ApiKey, result.api_token_id)

      assert api_client.name == "bootstrap-admin"
      assert api_client.tenant_id == Orchard.Governance.legacy_tenant_id()
      assert api_client.owner_contact == "local-operator"
      assert api_key.service_account_id == api_client.id
      assert api_key.tenant_id == nil
      assert api_key.name == "bootstrap"
      assert api_key.token_prefix == result.api_token_prefix
      assert api_key.secret_hash != result.token
      assert ApiKeySecret.verify(result.token, api_key.secret_hash)

      role_binding =
        Repo.one!(
          from(role_binding in RoleBinding,
            where:
              role_binding.principal_type == :service_account and
                role_binding.principal_id == ^api_client.id and
                role_binding.role == :admin and
                is_nil(role_binding.tenant_scope_id)
          )
        )

      assert role_binding.tenant_scope_id == nil

      audit_log =
        Repo.one!(
          from(audit_log in AuditLog,
            where:
              audit_log.scope == "cluster" and
                audit_log.action == "cluster_admin_bootstrap.minted" and
                audit_log.target_id == ^api_client.id
          )
        )

      assert audit_log.actor_type == "operator"
      assert audit_log.actor_id == "local-operator"
      assert audit_log.tenant_id == nil
      assert audit_log.api_key_id == nil

      assert audit_log.payload == %{
               "api_client_id" => api_client.id,
               "api_token_id" => api_key.id,
               "api_token_prefix" => api_key.token_prefix,
               "recovery" => false
             }

      refute inspect(audit_log.payload) =~ result.token
    end
  end

  defp restore_control_plane(nil), do: Application.delete_env(:orchard_controller, :control_plane)

  defp restore_control_plane(value),
    do: Application.put_env(:orchard_controller, :control_plane, value)

  defp credential_counts do
    %{
      service_accounts: Repo.aggregate(ServiceAccount, :count, :id),
      api_keys: Repo.aggregate(ApiKey, :count, :id),
      role_bindings: Repo.aggregate(RoleBinding, :count, :id),
      audit_logs: Repo.aggregate(AuditLog, :count, :id)
    }
  end
end
