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

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, AuditLog, Tenant}

  describe "create_tenant/1" do
    test "creates a tenant, ignores caller-supplied ids, and writes one audit row" do
      legacy_tenant = Repo.get!(Tenant, Governance.legacy_tenant_id())

      assert {:ok, tenant} =
               Governance.create_tenant(%{
                 id: Governance.legacy_tenant_id(),
                 slug: "tenant-created",
                 name: "Tenant Created",
                 inserted_at: DateTime.utc_now(),
                 updated_at: DateTime.utc_now()
               })

      persisted = Repo.get!(Tenant, tenant.id)
      audit_log = tenant_audit_log!(tenant.id, "tenant.created")

      assert tenant.id != Governance.legacy_tenant_id()
      assert tenant.slug == "tenant-created"
      assert tenant.name == "Tenant Created"
      assert persisted.id == tenant.id
      assert persisted.slug == "tenant-created"
      assert persisted.name == "Tenant Created"

      assert legacy_tenant.slug == Governance.legacy_tenant_slug()
      assert legacy_tenant.name == Governance.legacy_tenant_name()

      assert audit_log.tenant_id == tenant.id
      assert audit_log.api_key_id == nil
      assert audit_log.actor_type == "system"
      assert audit_log.actor_id == nil
      assert audit_log.action == "tenant.created"
      assert audit_log.target_type == "tenant"
      assert audit_log.target_id == tenant.id
      assert audit_log.payload == %{"slug" => "tenant-created", "name" => "Tenant Created"}
      assert count_tenant_audit_logs(tenant.id, "tenant.created") == 1
    end

    test "returns a changeset for missing attrs and leaves no non-legacy rows behind" do
      non_legacy_count =
        Repo.aggregate(
          from(tenant in Tenant, where: tenant.id != ^Governance.legacy_tenant_id()),
          :count,
          :id
        )

      assert {:error, changeset} = Governance.create_tenant(%{})
      assert %{slug: ["can't be blank"], name: ["can't be blank"]} = errors_on(changeset)

      assert Repo.aggregate(
               from(tenant in Tenant, where: tenant.id != ^Governance.legacy_tenant_id()),
               :count,
               :id
             ) == non_legacy_count

      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "surfaces duplicate slug changesets and preserves the canonical legacy tenant" do
      assert {:error, changeset} =
               Governance.create_tenant(%{
                 id: Ecto.UUID.generate(),
                 slug: Governance.legacy_tenant_slug(),
                 name: "Duplicate Legacy"
               })

      assert %{slug: ["has already been taken"]} = errors_on(changeset)

      legacy_tenant = Repo.get!(Tenant, Governance.legacy_tenant_id())
      assert legacy_tenant.slug == Governance.legacy_tenant_slug()
      assert legacy_tenant.name == Governance.legacy_tenant_name()
      assert count_tenant_audit_logs(legacy_tenant.id, "tenant.created") == 0
    end

    test "rolls back the tenant insert when audit log creation fails" do
      with_env(:governance_audit_log_impl, Orchard.GovernanceTest.InvalidAuditLog, fn ->
        assert {:error, changeset} =
                 Governance.create_tenant(%{slug: "tenant-audit-fail", name: "Tenant Audit Fail"})

        assert %{target_type: ["can't be blank"]} = errors_on(changeset)
      end)

      assert Repo.get_by(Tenant, slug: "tenant-audit-fail") == nil
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end
  end

  describe "list_tenants/0" do
    test "returns persisted tenants including the legacy tenant in slug order" do
      create_tenant!("beta")
      create_tenant!("alpha")

      assert Governance.list_tenants()
             |> Enum.map(&{&1.slug, &1.name}) == [
               {"alpha", "Alpha"},
               {"beta", "Beta"},
               {Governance.legacy_tenant_slug(), Governance.legacy_tenant_name()}
             ]
    end
  end

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

  describe "authenticate_api_key/1" do
    test "SPEC.md §7.2.2 authenticates a stored bearer key and returns M2a provenance" do
      tenant = create_tenant!("tenant-auth")

      {:ok, %{api_key: api_key, token: token}} =
        Governance.create_api_key(tenant.id, %{name: "Primary"})

      assert {:ok, auth_context} = Governance.authenticate_api_key(token)
      assert auth_context.tenant_id == tenant.id
      assert auth_context.principal_id == tenant.id
      assert auth_context.api_key_id == api_key.id
    end

    test "rejects unknown and malformed tokens" do
      assert {:error, :invalid_api_key} = Governance.authenticate_api_key("orch_missing.secret")
      assert {:error, :invalid_api_key} = Governance.authenticate_api_key("not-a-token")
    end

    test "SPEC.md §10.2 revocation is immediate for subsequent authentication attempts" do
      tenant = create_tenant!("tenant-auth-revoked")

      {:ok, %{api_key: api_key, token: token}} =
        Governance.create_api_key(tenant.id, %{name: "Primary"})

      assert {:ok, _auth_context} = Governance.authenticate_api_key(token)
      assert {:ok, _revoked} = Governance.revoke_api_key(api_key.id)
      assert {:error, :api_key_revoked} = Governance.authenticate_api_key(token)
    end
  end

  describe "touch_api_key_last_used/1" do
    test "updates last_used_at for a valid api key" do
      tenant = create_tenant!("tenant-last-used")
      {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, %{name: "Primary"})
      assert Repo.get!(ApiKey, api_key.id).last_used_at == nil

      assert :ok = Governance.touch_api_key_last_used(api_key.id)

      touched = Repo.get!(ApiKey, api_key.id)
      assert %DateTime{} = touched.last_used_at
    end

    test "returns :api_key_not_found for unknown ids" do
      assert {:error, :api_key_not_found} =
               Governance.touch_api_key_last_used(Ecto.UUID.generate())
    end
  end

  describe "audit_api_key_auth_failure/2" do
    test "writes an audit row when a tenant-resolved key fails authentication" do
      tenant = create_tenant!("tenant-auth-audit")

      {:ok, %{api_key: api_key, token: token}} =
        Governance.create_api_key(tenant.id, %{name: "Primary"})

      assert :ok = Governance.audit_api_key_auth_failure(token, :invalid_api_key)

      audit_log = audit_log!(api_key.id, "api_key.auth_failed")
      assert audit_log.tenant_id == tenant.id
      assert audit_log.api_key_id == api_key.id
      assert audit_log.target_type == "api_key"
      assert audit_log.target_id == api_key.id

      assert audit_log.payload == %{
               "reason" => "invalid_api_key",
               "token_prefix" => api_key.token_prefix
             }
    end

    test "skips persistence when the tenant cannot be resolved from the token" do
      assert :skipped =
               Governance.audit_api_key_auth_failure("orch_missing.secret", :invalid_api_key)

      assert :skipped = Governance.audit_api_key_auth_failure(nil, :missing_header)
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
          Sandbox.allow(Repo, parent, self())
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

  describe "get_tenant/1" do
    test "returns tenant by ID" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "get-test", name: "Get Test"})
      assert {:ok, found} = Governance.get_tenant(tenant.id)
      assert found.id == tenant.id
      assert found.slug == "get-test"
    end

    test "returns tenant when passed a Tenant struct" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "struct-test", name: "Struct Test"})
      assert {:ok, ^tenant} = Governance.get_tenant(tenant)
    end

    test "returns error for unknown ID" do
      assert {:error, :tenant_not_found} = Governance.get_tenant(Ecto.UUID.generate())
    end

    test "returns error for malformed ID" do
      assert {:error, :tenant_not_found} = Governance.get_tenant("not-a-uuid")
    end
  end

  describe "list_api_keys_for_tenant/1" do
    test "returns only keys for the given tenant, newest first, redacted" do
      {:ok, t1} = Governance.create_tenant(%{slug: "list-keys-t1", name: "T1"})
      {:ok, t2} = Governance.create_tenant(%{slug: "list-keys-t2", name: "T2"})

      {:ok, %{api_key: k1}} = Governance.create_api_key(t1.id, %{name: "first"})
      {:ok, %{api_key: k2}} = Governance.create_api_key(t1.id, %{name: "second"})
      {:ok, _} = Governance.create_api_key(t2.id, %{name: "other-tenant"})

      assert {:ok, keys} = Governance.list_api_keys_for_tenant(t1.id)
      assert length(keys) == 2
      assert Enum.map(keys, & &1.id) == [k2.id, k1.id]
      assert Enum.all?(keys, fn k -> k.secret_hash == nil end)
    end

    test "accepts a Tenant struct" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "list-struct", name: "LS"})
      {:ok, _} = Governance.create_api_key(tenant.id, %{name: "key1"})
      assert {:ok, [_]} = Governance.list_api_keys_for_tenant(tenant)
    end

    test "returns empty list for tenant with no keys" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "no-keys", name: "No Keys"})
      assert {:ok, []} = Governance.list_api_keys_for_tenant(tenant.id)
    end

    test "returns error for unknown tenant" do
      assert {:error, :tenant_not_found} =
               Governance.list_api_keys_for_tenant(Ecto.UUID.generate())
    end

    test "returns error for malformed tenant ID" do
      assert {:error, :tenant_not_found} = Governance.list_api_keys_for_tenant("bad")
    end
  end

  describe "revoke_api_key/2 (tenant-scoped)" do
    test "revokes key belonging to tenant" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "rev-scoped", name: "RS"})
      {:ok, %{api_key: key}} = Governance.create_api_key(tenant.id, %{name: "k1"})

      assert {:ok, revoked} = Governance.revoke_api_key(tenant.id, key.id)
      assert revoked.revoked_at != nil
      assert revoked.secret_hash == nil
    end

    test "returns error when key belongs to different tenant" do
      {:ok, t1} = Governance.create_tenant(%{slug: "rev-t1", name: "T1"})
      {:ok, t2} = Governance.create_tenant(%{slug: "rev-t2", name: "T2"})
      {:ok, %{api_key: key}} = Governance.create_api_key(t1.id, %{name: "k1"})

      assert {:error, :api_key_not_found} = Governance.revoke_api_key(t2.id, key.id)

      # Verify key is NOT revoked
      {:ok, keys} = Governance.list_api_keys_for_tenant(t1.id)
      assert [unrevoked] = keys
      assert unrevoked.revoked_at == nil
    end

    test "accepts Tenant struct" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "rev-struct", name: "RS"})
      {:ok, %{api_key: key}} = Governance.create_api_key(tenant.id, %{name: "k1"})

      assert {:ok, revoked} = Governance.revoke_api_key(tenant, key.id)
      assert revoked.revoked_at != nil
    end

    test "is idempotent for already-revoked key" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "rev-idem", name: "RI"})
      {:ok, %{api_key: key}} = Governance.create_api_key(tenant.id, %{name: "k1"})

      assert {:ok, _} = Governance.revoke_api_key(tenant.id, key.id)
      assert {:ok, _} = Governance.revoke_api_key(tenant.id, key.id)
    end

    test "returns error for unknown key ID" do
      {:ok, tenant} = Governance.create_tenant(%{slug: "rev-unknown", name: "RU"})

      assert {:error, :api_key_not_found} =
               Governance.revoke_api_key(tenant.id, Ecto.UUID.generate())
    end

    test "returns error for unknown tenant ID" do
      assert {:error, :tenant_not_found} =
               Governance.revoke_api_key(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  defp tenant_audit_log!(tenant_id, action) do
    Repo.one!(
      from(audit_log in AuditLog,
        where:
          audit_log.tenant_id == ^tenant_id and audit_log.target_type == "tenant" and
            audit_log.target_id == ^tenant_id and audit_log.action == ^action
      )
    )
  end

  defp count_tenant_audit_logs(tenant_id, action) do
    Repo.aggregate(
      from(audit_log in AuditLog,
        where:
          audit_log.tenant_id == ^tenant_id and audit_log.target_type == "tenant" and
            audit_log.target_id == ^tenant_id and audit_log.action == ^action
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
