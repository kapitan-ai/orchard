defmodule Orchard.Governance.FoundationTest do
  use Orchard.DataCase, async: false

  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, AuditLog, Tenant}

  describe "tenant foundation" do
    test "seeded legacy tenant exists after migrations" do
      tenant = Repo.get(Tenant, Governance.legacy_tenant_id())

      assert tenant
      assert tenant.slug == Governance.legacy_tenant_slug()
      assert tenant.name == Governance.legacy_tenant_name()
    end

    test "changeset requires slug and name" do
      changeset = Tenant.changeset(%Tenant{}, %{})

      assert %{slug: ["can't be blank"], name: ["can't be blank"]} = errors_on(changeset)
    end

    test "insert enforces unique slug" do
      assert {:ok, _tenant} =
               %Tenant{}
               |> Tenant.changeset(%{slug: "tenant-one", name: "Tenant One"})
               |> Repo.insert()

      assert {:error, changeset} =
               %Tenant{}
               |> Tenant.changeset(%{slug: "tenant-one", name: "Tenant Duplicate"})
               |> Repo.insert()

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "api key foundation" do
    test "changeset requires tenant_id, name, token_prefix, and secret_hash" do
      changeset = ApiKey.changeset(%ApiKey{}, %{})

      assert %{
               tenant_id: ["can't be blank"],
               name: ["can't be blank"],
               token_prefix: ["can't be blank"],
               secret_hash: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "insert succeeds for a valid tenant and enforces unique token_prefix" do
      tenant = create_tenant!("tenant-api-key")

      attrs = %{
        tenant_id: tenant.id,
        name: "Primary Key",
        token_prefix: "orch_1234",
        secret_hash: "hash-1234"
      }

      assert {:ok, api_key} = %ApiKey{} |> ApiKey.changeset(attrs) |> Repo.insert()
      assert api_key.tenant_id == tenant.id

      assert {:error, changeset} =
               %ApiKey{}
               |> ApiKey.changeset(%{attrs | name: "Duplicate Prefix"})
               |> Repo.insert()

      assert %{token_prefix: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "audit log foundation" do
    test "has no updated_at field, inserts append-only records with defaults, and rejects updates" do
      tenant = create_tenant!("tenant-audit-log")
      api_key = create_api_key!(tenant)

      refute :updated_at in AuditLog.__schema__(:fields)

      assert {:ok, audit_log} =
               %AuditLog{}
               |> AuditLog.changeset(%{
                 tenant_id: tenant.id,
                 api_key_id: api_key.id,
                 actor_type: "api_key",
                 actor_id: api_key.id,
                 action: "api_key.created",
                 target_type: "api_key",
                 target_id: api_key.id
               })
               |> Repo.insert()

      reloaded = Repo.get!(AuditLog, audit_log.id)

      assert reloaded.tenant_id == tenant.id
      assert reloaded.api_key_id == api_key.id
      assert reloaded.payload == %{}
      assert match?(%DateTime{}, reloaded.occurred_at)

      assert_raise Postgrex.Error, ~r/audit_logs is append-only/, fn ->
        reloaded
        |> AuditLog.changeset(%{
          tenant_id: tenant.id,
          actor_type: reloaded.actor_type,
          actor_id: reloaded.actor_id,
          action: reloaded.action,
          target_type: reloaded.target_type,
          target_id: reloaded.target_id,
          payload: %{"updated" => true}
        })
        |> Repo.update()
      end
    end

    test "changeset requires actor_type, action, and target_type" do
      changeset = AuditLog.changeset(%AuditLog{}, %{})

      assert %{
               tenant_id: ["can't be blank"],
               actor_type: ["can't be blank"],
               action: ["can't be blank"],
               target_type: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  defp create_tenant!(slug) do
    {:ok, tenant} =
      %Tenant{}
      |> Tenant.changeset(%{slug: slug, name: String.capitalize(slug)})
      |> Repo.insert()

    tenant
  end

  defp create_api_key!(tenant) do
    {:ok, api_key} =
      %ApiKey{}
      |> ApiKey.changeset(%{
        tenant_id: tenant.id,
        name: "Key for #{tenant.slug}",
        token_prefix: "prefix-#{System.unique_integer([:positive])}",
        secret_hash: "secret-hash-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert()

    api_key
  end
end
