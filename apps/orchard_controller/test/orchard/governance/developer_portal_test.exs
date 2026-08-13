defmodule Orchard.Governance.DeveloperPortalTest do
  use Orchard.DataCase, async: false

  import Ecto.Query
  import Orchard.TestSupport.ModelRequestFixtures, only: [create_request!: 1]

  alias Orchard.Governance

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    AuditLog,
    PortalLoginThrottle,
    PortalPassword,
    PortalPasswordVerifier,
    PortalSession,
    Tenant
  }

  alias Ecto.Adapters.SQL.Sandbox

  @password "sixteen-chars-ok"
  @rotated "sixteen-chars-two"

  setup do
    previous_mode = Application.get_env(:orchard_controller, :transport_mode, :__missing__)
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    start_verifier!()

    on_exit(fn ->
      Application.delete_env(:orchard_controller, :portal_login_intercept)

      case previous_mode do
        :__missing__ -> Application.delete_env(:orchard_controller, :transport_mode)
        mode -> Application.put_env(:orchard_controller, :transport_mode, mode)
      end
    end)

    :ok
  end

  test "set stores only an Argon2id hash, opens the portal, and writes a redacted audit row" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-set", name: "Portal Set"})

    assert {:ok, returned} = Governance.set_tenant_portal_password(tenant, @password)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_set")

    assert returned.portal_password_hash == nil
    assert returned.portal_session_epoch == 1
    assert PortalPassword.verify(@password, persisted.portal_password_hash) == :ok
    refute persisted.portal_password_hash == @password
    assert persisted.portal_session_epoch == 1

    assert audit.actor_type == "operator"
    assert audit.payload["portal_enabled"] == true
    assert audit.payload["portal_session_epoch"] == 1
    assert audit.payload["surface"] == "console"
    refute Map.has_key?(audit.payload, "portal_password_hash")
    refute inspect(audit.payload) =~ @password
    refute inspect(audit.payload) =~ persisted.portal_password_hash
  end

  test "rotate increments epoch, replaces the hash, and does not revoke keys" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-rotate", name: "Portal Rotate"})
    {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, %{name: "keep"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:ok, returned} = Governance.set_tenant_portal_password(tenant, @rotated)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_rotated")
    kept = Repo.get!(ApiKey, api_key.id)

    assert returned.portal_session_epoch == 2
    assert persisted.portal_session_epoch == 2
    assert PortalPassword.verify(@rotated, persisted.portal_password_hash) == :ok

    assert PortalPassword.verify(@password, persisted.portal_password_hash) ==
             {:error, :invalid_password}

    assert kept.revoked_at == nil
    assert audit.payload["portal_session_epoch"] == 2
  end

  test "clear nulls the hash, increments epoch, and closes the portal" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-clear", name: "Portal Clear"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:ok, returned} = Governance.clear_tenant_portal_password(tenant)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_cleared")

    assert returned.portal_password_hash == nil
    assert returned.portal_session_epoch == 2
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 2
    assert audit.payload["portal_enabled"] == false
  end

  test "existing tenants migrate closed with epoch 0" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-closed", name: "Portal Closed"})
    persisted = Repo.get!(Tenant, tenant.id)

    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "ordinary tenant changeset ignores portal password fields" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-smuggle", name: "Portal Smuggle"})

    changeset =
      Tenant.changeset(tenant, %{
        name: "Renamed",
        portal_password_hash: "not-a-hash",
        portal_session_epoch: 99
      })

    assert {:ok, updated} = Repo.update(changeset)
    persisted = Repo.get!(Tenant, tenant.id)

    assert updated.name == "Renamed"
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "set rejects short passwords before hashing" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-short", name: "Portal Short"})

    assert {:error, :password_too_short} =
             Governance.set_tenant_portal_password(tenant, "short-password")

    persisted = Repo.get!(Tenant, tenant.id)
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "set and clear reject degraded transport" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-http", name: "Portal HTTP"})
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)

    assert {:error, :https_required} =
             Governance.set_tenant_portal_password(tenant, @password)

    assert {:error, :https_required} = Governance.clear_tenant_portal_password(tenant)
    persisted = Repo.get!(Tenant, tenant.id)
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "correct password on an open org creates a session at the current epoch" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-login", name: "Portal Login"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:ok, result} =
             Governance.create_portal_session("portal-login", @password, "203.0.113.10")

    persisted = Repo.get!(PortalSession, result.session.id)
    tenant = Repo.get!(Tenant, tenant.id)

    assert result.tenant.id == tenant.id
    assert result.tenant.portal_password_hash == nil
    assert is_binary(result.token)
    assert String.starts_with?(result.token, "orchard_ps_")
    assert persisted.password_epoch == tenant.portal_session_epoch
    assert persisted.token_hash == :crypto.hash(:sha256, result.token)

    assert {:ok, validated} =
             Governance.validate_portal_session(result.token, "portal-login")

    assert validated.session.id == result.session.id
    assert validated.tenant.id == tenant.id
  end

  test "successful login deletes the throttle row" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-clear-throttle", name: "Clear"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session(
               "portal-clear-throttle",
               "sixteen-chars-bad",
               "203.0.113.11"
             )

    assert Repo.aggregate(PortalLoginThrottle, :count) == 1

    assert {:ok, _} =
             Governance.create_portal_session(
               "portal-clear-throttle",
               @password,
               "203.0.113.11"
             )

    assert Repo.aggregate(PortalLoginThrottle, :count) == 0
  end

  test "unknown slug and closed org return the same error" do
    {:ok, _closed} = Governance.create_tenant(%{slug: "portal-closed-login", name: "Closed"})

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session("portal-closed-login", @password, "203.0.113.12")

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session("missing-org", @password, "203.0.113.12")
  end

  test "fifth failure starts a 30s block and blocked retries do not increment" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-backoff", name: "Backoff"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    for _ <- 1..5 do
      assert {:error, :invalid_credentials} =
               Governance.create_portal_session(
                 "portal-backoff",
                 "sixteen-chars-bad",
                 "203.0.113.13"
               )
    end

    throttle = Repo.one!(PortalLoginThrottle)
    assert throttle.failure_count == 5
    assert %DateTime{} = throttle.blocked_until

    assert {:error, :throttled} =
             Governance.create_portal_session(
               "portal-backoff",
               "sixteen-chars-bad",
               "203.0.113.13"
             )

    assert Repo.one!(PortalLoginThrottle).failure_count == 5
  end

  test "two sources against the same org do not share a backoff" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-sources", name: "Sources"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    for _ <- 1..5 do
      assert {:error, :invalid_credentials} =
               Governance.create_portal_session(
                 "portal-sources",
                 "sixteen-chars-bad",
                 "203.0.113.14"
               )
    end

    assert {:ok, _} =
             Governance.create_portal_session("portal-sources", @password, "203.0.113.15")
  end

  test "password rotated between verify and insert creates no session" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-race", name: "Race"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    Application.put_env(:orchard_controller, :portal_login_intercept, fn ->
      Application.put_env(:orchard_controller, :portal_login_intercept, nil)
      assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @rotated)
    end)

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session("portal-race", @password, "203.0.113.16")

    assert Repo.aggregate(PortalSession, :count) == 0
  end

  test "expired sessions and stale throttle rows are pruned" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-prune", name: "Prune"})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    stale = DateTime.add(now, -86_401, :second)

    {:ok, _} =
      %PortalSession{}
      |> PortalSession.changeset(%{
        tenant_id: tenant.id,
        token_hash: :crypto.hash(:sha256, "expired-token"),
        password_epoch: 0,
        issued_at: stale,
        last_seen_at: stale,
        absolute_expires_at: DateTime.add(stale, 1, :second)
      })
      |> Repo.insert()

    {:ok, _} =
      %PortalLoginThrottle{}
      |> PortalLoginThrottle.changeset(%{
        organization_fingerprint: :crypto.hash(:sha256, "org"),
        source_fingerprint: :crypto.hash(:sha256, "src"),
        failure_count: 1,
        last_failed_at: stale
      })
      |> Ecto.Changeset.put_change(:inserted_at, stale)
      |> Repo.insert()

    assert Governance.prune_portal_persistence() == :ok
    assert Repo.aggregate(PortalSession, :count) == 0
    assert Repo.aggregate(PortalLoginThrottle, :count) == 0
  end

  test "portal mint returns a canonical token once and stores only prefix plus hash" do
    {_tenant, token} = open_portal!("portal-mint")

    assert {:ok, result} =
             Governance.create_portal_api_key(token, "portal-mint", %{name: "laptop"})

    persisted = Repo.get!(ApiKey, result.api_key.id)
    audit = api_key_audit_log!(result.api_key.id, "api_key.created")

    assert String.starts_with?(result.token, "orchard_sk_")
    assert result.api_key.secret_hash == nil
    assert result.api_key.issuance_surface == "developer_portal"
    assert result.curl == nil
    assert persisted.issuance_surface == "developer_portal"
    assert persisted.service_account_id == nil
    assert persisted.secret_hash != result.token
    refute inspect(audit.payload) =~ result.token
    assert audit.actor_type == "developer"
    assert audit.payload["surface"] == "developer_portal"
    assert {:ok, _} = Governance.authenticate_api_key(result.token)
  end

  test "operator mint after 10 portal keys still succeeds" do
    {tenant, token} = open_portal!("portal-cap-operator")

    for index <- 1..10 do
      assert {:ok, _} =
               Governance.create_portal_api_key(token, "portal-cap-operator", %{
                 name: "portal-#{index}"
               })
    end

    assert {:ok, operator} = Governance.create_api_key(tenant, %{name: "operator-keep"})
    assert operator.api_key.issuance_surface == "governance"

    assert {:error, :portal_key_limit_reached} =
             Governance.create_portal_api_key(token, "portal-cap-operator", %{name: "eleventh"})

    assert Repo.aggregate(
             from(api_key in ApiKey,
               where:
                 api_key.tenant_id == ^tenant.id and
                   api_key.issuance_surface == "developer_portal"
             ),
             :count
           ) == 10
  end

  test "list includes operator keys and excludes API Client tokens" do
    {tenant, token} = open_portal!("portal-list")
    assert {:ok, portal} = Governance.create_portal_api_key(token, "portal-list", %{name: "mine"})
    assert {:ok, operator} = Governance.create_api_key(tenant, %{name: "ops"})
    create_api_client_token!(tenant, "client-a")

    create_request!(%{
      tenant_id: tenant.id,
      api_key_id: portal.api_key.id,
      state: :completed
    })

    assert {:ok, listing} = Governance.list_portal_api_keys(tenant)
    ids = Enum.map(listing.keys, & &1.id)

    assert listing.active_portal_count == 1
    assert portal.api_key.id in ids
    assert operator.api_key.id in ids
    refute Enum.any?(listing.keys, &(&1.issuance_surface != "developer_portal" and &1.revocable?))

    portal_row = Enum.find(listing.keys, &(&1.id == portal.api_key.id))
    operator_row = Enum.find(listing.keys, &(&1.id == operator.api_key.id))
    assert portal_row.request_count == 1
    assert portal_row.revocable? == true
    assert operator_row.request_count == 0
    assert operator_row.revocable? == false
    assert length(listing.keys) == 2
  end

  test "revoked and expired portal keys remain listed" do
    {tenant, token} = open_portal!("portal-status")
    assert {:ok, live} = Governance.create_portal_api_key(token, "portal-status", %{name: "live"})

    expired =
      insert_portal_key!(tenant, %{
        name: "expired",
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    assert {:ok, revoked} =
             Governance.revoke_portal_api_key(token, "portal-status", live.api_key)

    assert {:ok, listing} = Governance.list_portal_api_keys(tenant)

    by_id = Map.new(listing.keys, &{&1.id, &1})
    assert by_id[revoked.id].status == :revoked
    assert by_id[expired.id].status == :expired
    assert listing.active_portal_count == 0
  end

  test "two concurrent portal mints from 9 active keys produce exactly one success" do
    {tenant, token} = open_portal!("portal-race-mint")

    for index <- 1..9 do
      assert {:ok, _} =
               Governance.create_portal_api_key(token, "portal-race-mint", %{
                 name: "existing-#{index}"
               })
    end

    parent = self()

    tasks =
      for index <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          Governance.create_portal_api_key(token, "portal-race-mint", %{
            name: "race-#{index}"
          })
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))
    successes = Enum.filter(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, :portal_key_limit_reached}, &1))

    assert length(successes) == 1
    assert length(failures) == 1

    assert Repo.aggregate(
             from(api_key in ApiKey,
               where:
                 api_key.tenant_id == ^tenant.id and
                   api_key.issuance_surface == "developer_portal" and
                   is_nil(api_key.revoked_at)
             ),
             :count
           ) == 10
  end

  test "portal revoke of operator and service-account keys is not found" do
    {tenant, token} = open_portal!("portal-revoke-isolation")
    assert {:ok, operator} = Governance.create_api_key(tenant, %{name: "ops"})
    %{api_key: client_key} = create_api_client_token!(tenant, "client-b")

    assert {:error, :api_key_not_found} =
             Governance.revoke_portal_api_key(token, "portal-revoke-isolation", operator.api_key)

    assert {:error, :api_key_not_found} =
             Governance.revoke_portal_api_key(token, "portal-revoke-isolation", client_key)

    assert Repo.get!(ApiKey, operator.api_key.id).revoked_at == nil
    assert Repo.get!(ApiKey, client_key.id).revoked_at == nil
    _ = token
  end

  test "portal-minted Bearer survives password rotate and stale portal revoke" do
    {tenant, token} = open_portal!("portal-bearer")

    assert {:ok, minted} =
             Governance.create_portal_api_key(token, "portal-bearer", %{name: "app"})

    assert {:ok, _} = Governance.authenticate_api_key(minted.token)
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @rotated)
    assert {:ok, _} = Governance.authenticate_api_key(minted.token)

    assert {:error, :invalid_session} =
             Governance.revoke_portal_api_key(token, "portal-bearer", minted.api_key)

    assert {:ok, _} = Governance.authenticate_api_key(minted.token)
  end

  defp start_verifier! do
    case Process.whereis(PortalPasswordVerifier) do
      nil -> start_supervised!(PortalPasswordVerifier)
      _pid -> :ok
    end
  end

  defp open_portal!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    assert {:ok, tenant} = Governance.set_tenant_portal_password(tenant, @password)
    assert {:ok, result} = Governance.create_portal_session(slug, @password, "203.0.113.40")
    {tenant, result.token}
  end

  defp create_api_client_token!(tenant, name) do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: name,
        owner_contact: "#{name}@example.com"
      })

    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)

    {:ok, created} = Governance.create_api_client_api_token(api_client, %{name: "prod"})
    created
  end

  defp insert_portal_key!(tenant, attrs) do
    generated = ApiKeySecret.generate()

    {:ok, api_key} =
      %ApiKey{}
      |> ApiKey.tenant_direct_changeset(%{
        tenant_id: tenant.id,
        name: Map.fetch!(attrs, :name),
        token_prefix: generated.token_prefix,
        secret_hash: generated.secret_hash,
        issuance_surface: "developer_portal",
        expires_at: Map.get(attrs, :expires_at)
      })
      |> Repo.insert()

    api_key
  end

  defp api_key_audit_log!(api_key_id, action) do
    Repo.one!(
      from(audit_log in AuditLog,
        where: audit_log.api_key_id == ^api_key_id and audit_log.action == ^action
      )
    )
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
end
