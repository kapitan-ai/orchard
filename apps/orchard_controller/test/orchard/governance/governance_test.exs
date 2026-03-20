defmodule Orchard.GovernanceTest.CollisionSecret do
  alias Orchard.Governance.ApiKeySecret

  @token "orch_collision.fixedsecret"

  def generate do
    %{
      token: @token,
      token_prefix: "orch_collision",
      secret_hash: ApiKeySecret.hash(@token)
    }
  end
end

defmodule Orchard.GovernanceTest.InvalidAuditLog do
  alias Orchard.Governance.AuditLog

  def changeset(audit_log, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.delete(:target_type)
      |> Map.delete("target_type")

    AuditLog.changeset(audit_log, attrs)
  end
end

defmodule Orchard.GovernanceTest.InvalidSecret do
  def generate, do: %{token: "invalid-token"}
end

defmodule Orchard.GovernanceTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, AuditLog, Tenant}

  describe "create_api_key/2" do
    test "returns the cleartext token once, persists only generated metadata, and writes an audit row" do
      tenant = create_tenant!("tenant-create")
      other_tenant = create_tenant!("tenant-other")
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, %{api_key: api_key, token: token}} =
               Governance.create_api_key(tenant, %{
                 name: "Primary Key",
                 tenant_id: other_tenant.id,
                 token_prefix: "caller-prefix",
                 secret_hash: "caller-hash",
                 revoked_at: now,
                 last_used_at: now
               })

      assert api_key.secret_hash == nil

      persisted = Repo.get!(ApiKey, api_key.id)
      audit_log = audit_log!(api_key.id, "api_key.created")

      assert persisted.tenant_id == tenant.id
      assert persisted.name == "Primary Key"
      assert persisted.revoked_at == nil
      assert persisted.last_used_at == nil
      refute persisted.token_prefix == "caller-prefix"
      refute persisted.secret_hash == "caller-hash"
      refute persisted.token_prefix == token
      refute persisted.secret_hash == token
      assert {:ok, persisted.token_prefix} == ApiKeySecret.token_prefix(token)
      assert persisted.secret_hash == ApiKeySecret.hash(token)
      assert ApiKeySecret.verify(token, persisted.secret_hash)

      assert audit_log.tenant_id == tenant.id
      assert audit_log.api_key_id == api_key.id
      assert audit_log.actor_type == "system"
      assert audit_log.action == "api_key.created"
      assert audit_log.target_type == "api_key"
      assert audit_log.target_id == api_key.id

      assert audit_log.payload == %{
               "name" => "Primary Key",
               "token_prefix" => persisted.token_prefix
             }

      refute Map.has_key?(audit_log.payload, "token")
      assert count_audit_logs(api_key.id, "api_key.created") == 1
    end

    test "returns a sanitized changeset error for missing name and leaves no rows behind" do
      tenant = create_tenant!("tenant-missing-name")

      assert {:error, changeset} = Governance.create_api_key(tenant.id, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
      refute Map.has_key?(changeset.changes, :secret_hash)
      refute Map.has_key?(changeset.params || %{}, "secret_hash")
      assert changeset.data.secret_hash == nil
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "returns :tenant_not_found for unknown and malformed tenant ids" do
      assert {:error, :tenant_not_found} =
               Governance.create_api_key(Ecto.UUID.generate(), %{name: "Missing"})

      assert {:error, :tenant_not_found} = Governance.create_api_key("not-a-uuid", %{name: "Bad"})
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "surfaces prefix collisions without retrying and leaves no extra rows behind" do
      tenant = create_tenant!("tenant-collision")
      create_api_key_record!(tenant, %{token_prefix: "orch_collision"})

      with_env(:governance_api_key_secret_impl, Orchard.GovernanceTest.CollisionSecret, fn ->
        assert {:error, changeset} = Governance.create_api_key(tenant.id, %{name: "Collision"})
        assert %{token_prefix: ["has already been taken"]} = errors_on(changeset)
        refute Map.has_key?(changeset.changes, :secret_hash)
        refute Map.has_key?(changeset.params || %{}, "secret_hash")
      end)

      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "string attrs take precedence over atom attrs when both provide name" do
      tenant = create_tenant!("tenant-mixed-keys")

      attrs = %{"name" => "String Name", name: "Atom Name"}

      assert {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, attrs)

      persisted = Repo.get!(ApiKey, api_key.id)
      assert persisted.name == "String Name"
    end

    test "rejects invalid generated secrets before inserting rows" do
      tenant = create_tenant!("tenant-invalid-secret")

      with_env(:governance_api_key_secret_impl, Orchard.GovernanceTest.InvalidSecret, fn ->
        assert {:error, :invalid_api_key_secret} =
                 Governance.create_api_key(tenant.id, %{name: "Primary"})
      end)

      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "rolls back the api key insert when audit log creation fails" do
      tenant = create_tenant!("tenant-create-audit-fail")

      with_env(:governance_audit_log_impl, Orchard.GovernanceTest.InvalidAuditLog, fn ->
        assert {:error, changeset} = Governance.create_api_key(tenant.id, %{name: "Primary"})
        assert %{target_type: ["can't be blank"]} = errors_on(changeset)
      end)

      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end
  end

  describe "revoke_api_key/1" do
    test "revokes once, writes one audit row, and treats later revokes as a noop" do
      tenant = create_tenant!("tenant-revoke")
      api_key = create_api_key_record!(tenant)

      assert {:ok, revoked} = Governance.revoke_api_key(api_key)
      assert %DateTime{} = revoked.revoked_at
      assert revoked.secret_hash == nil

      audit_log = audit_log!(api_key.id, "api_key.revoked")
      assert audit_log.occurred_at == revoked.revoked_at
      assert count_audit_logs(api_key.id, "api_key.revoked") == 1

      assert {:ok, reloaded} = Governance.revoke_api_key(api_key.id)
      assert reloaded.revoked_at == revoked.revoked_at
      assert reloaded.updated_at == revoked.updated_at
      assert count_audit_logs(api_key.id, "api_key.revoked") == 1

      persisted = Repo.get!(ApiKey, api_key.id)
      assert persisted.revoked_at == revoked.revoked_at
    end

    test "returns :api_key_not_found for unknown and malformed ids" do
      assert {:error, :api_key_not_found} = Governance.revoke_api_key(Ecto.UUID.generate())
      assert {:error, :api_key_not_found} = Governance.revoke_api_key("not-a-uuid")
    end

    test "concurrent revokes stay idempotent and write a single audit row" do
      tenant = create_tenant!("tenant-revoke-race")
      api_key = create_api_key_record!(tenant)
      start_ref = make_ref()
      parent = self()

      task = fn ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, self()})

          receive do
            ^start_ref -> Governance.revoke_api_key(api_key.id)
          end
        end)
      end

      task_one = task.()
      task_two = task.()

      assert_receive {:ready, _pid}, 1_000
      assert_receive {:ready, _pid}, 1_000

      send(task_one.pid, start_ref)
      send(task_two.pid, start_ref)

      results = [Task.await(task_one, 1_000), Task.await(task_two, 1_000)]
      revoked_at_values = Enum.map(results, fn {:ok, revoked} -> revoked.revoked_at end)

      assert Enum.all?(results, &match?({:ok, %ApiKey{}}, &1))
      assert Enum.uniq(revoked_at_values) |> length() == 1
      assert count_audit_logs(api_key.id, "api_key.revoked") == 1
    end

    test "rolls back revoked_at when audit log creation fails" do
      tenant = create_tenant!("tenant-revoke-audit-fail")
      api_key = create_api_key_record!(tenant)

      with_env(:governance_audit_log_impl, Orchard.GovernanceTest.InvalidAuditLog, fn ->
        assert {:error, changeset} = Governance.revoke_api_key(api_key.id)
        assert %{target_type: ["can't be blank"]} = errors_on(changeset)
      end)

      reloaded = Repo.get!(ApiKey, api_key.id)
      assert reloaded.revoked_at == nil
      assert count_audit_logs(api_key.id, "api_key.revoked") == 0
    end
  end

  defp create_tenant!(slug) do
    {:ok, tenant} =
      %Tenant{}
      |> Tenant.changeset(%{slug: slug, name: String.capitalize(slug)})
      |> Repo.insert()

    tenant
  end

  defp create_api_key_record!(tenant, overrides \\ %{}) do
    attrs = %{
      tenant_id: tenant.id,
      name: "Key for #{tenant.slug}",
      token_prefix: "orch_#{System.unique_integer([:positive])}",
      secret_hash: "sha256$#{System.unique_integer([:positive])}"
    }

    {:ok, api_key} =
      %ApiKey{}
      |> ApiKey.changeset(Map.merge(attrs, overrides))
      |> Repo.insert()

    api_key
  end

  defp audit_log!(api_key_id, action) do
    Repo.one!(
      from(audit_log in AuditLog,
        where: audit_log.api_key_id == ^api_key_id and audit_log.action == ^action
      )
    )
  end

  defp count_audit_logs(api_key_id, action) do
    Repo.aggregate(
      from(audit_log in AuditLog,
        where: audit_log.api_key_id == ^api_key_id and audit_log.action == ^action
      ),
      :count,
      :id
    )
  end

  defp with_env(key, value, fun) do
    previous = Application.get_env(:orchard_controller, key, :__missing__)
    Application.put_env(:orchard_controller, key, value)

    try do
      fun.()
    after
      case previous do
        :__missing__ -> Application.delete_env(:orchard_controller, key)
        previous -> Application.put_env(:orchard_controller, key, previous)
      end
    end
  end
end
