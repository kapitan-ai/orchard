defmodule Orchard.Governance.NamedPortalUserTest do
  use Orchard.DataCase, async: false

  import Ecto.Query
  import Orchard.TestSupport.ModelRequestFixtures, only: [create_request!: 1]

  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, PortalInviteToken, PortalSession, PortalUser}

  @password "sixteen-chars-ok"

  setup do
    case Process.whereis(Orchard.Governance.PortalPasswordVerifier) do
      nil -> start_supervised!(Orchard.Governance.PortalPasswordVerifier)
      _pid -> :ok
    end

    previous_mode = Application.get_env(:orchard_controller, :transport_mode, :__missing__)
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)

    on_exit(fn ->
      case previous_mode do
        :__missing__ -> Application.delete_env(:orchard_controller, :transport_mode)
        mode -> Application.put_env(:orchard_controller, :transport_mode, mode)
      end
    end)

    :ok
  end

  test "operator invite normalizes email and copy reissues one hash-only token" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "named-invite", name: "Named Invite"})
    assert {:ok, user} = Governance.create_portal_invite(tenant, %{email: "  Dev@Example.COM "})
    assert user.email == "dev@example.com"
    assert user.status == "invited"

    assert {:ok, first} = Governance.copy_portal_invite(tenant, user)
    assert {:ok, second} = Governance.copy_portal_invite(tenant, user)
    assert first.url == "/portal/#{tenant.slug}/invites/#{first.token}"
    assert second.url == "/portal/#{tenant.slug}/invites/#{second.token}"
    refute first.token == second.token
    refute first.url == second.url

    rows = Repo.all(from(token in PortalInviteToken, where: token.portal_user_id == ^user.id))
    assert length(rows) == 1
    assert hd(rows).token_hash == :crypto.hash(:sha256, second.token)
    refute inspect(rows) =~ second.token
    assert {:error, :invalid_invite} = Governance.redeem_portal_invite(first.token, @password)
    assert {:ok, active} = Governance.redeem_portal_invite(second.token, @password)
    assert active.status == "active"
    assert active.password_hash != @password
    assert {:error, :invalid_invite} = Governance.redeem_portal_invite(second.token, @password)
  end

  test "named login creates a user-owned session and disable ends sessions only" do
    {tenant, user} = active_user!("named-login", "dev@example.com")

    assert {:ok, login} =
             Governance.create_portal_session(tenant.slug, user.email, @password, "203.0.113.1")

    persisted = Repo.get!(PortalSession, login.session.id)
    assert persisted.portal_user_id == user.id

    assert {:ok, %{portal_user: validated}} =
             Governance.validate_portal_session(login.token, tenant.slug)

    assert validated.id == user.id

    assert {:ok, minted} =
             Governance.create_portal_api_key(login.token, tenant.slug, %{name: "keep"})

    assert {:ok, _} = Governance.disable_portal_user(tenant, user)

    assert {:error, :invalid_session} =
             Governance.validate_portal_session(login.token, tenant.slug)

    assert {:ok, auth} = Governance.authenticate_api_key(minted.token)
    assert auth.principal_type == :tenant
  end

  test "credential failures are generic and throttling is identity plus source scoped" do
    {tenant, user} = active_user!("named-auth", "one@example.com")
    {_tenant, other} = active_user!(tenant, "two@example.com")

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session(
               tenant.slug,
               "missing@example.com",
               @password,
               "203.0.113.2"
             )

    assert {:error, :invalid_credentials} =
             Governance.create_portal_session(
               tenant.slug,
               user.email,
               "sixteen-chars-bad",
               "203.0.113.2"
             )

    for _ <- 1..5 do
      Governance.create_portal_session(
        tenant.slug,
        user.email,
        "sixteen-chars-bad",
        "203.0.113.3"
      )
    end

    assert {:error, :throttled} =
             Governance.create_portal_session(tenant.slug, user.email, @password, "203.0.113.3")

    assert {:ok, _} =
             Governance.create_portal_session(tenant.slug, other.email, @password, "203.0.113.3")
  end

  test "portal users list and revoke only their own keys and cap is per user" do
    {tenant, first} = active_user!("named-keys", "first@example.com")
    {_tenant, second} = active_user!(tenant, "second@example.com")

    {:ok, first_login} =
      Governance.create_portal_session(tenant.slug, first.email, @password, "203.0.113.4")

    {:ok, second_login} =
      Governance.create_portal_session(tenant.slug, second.email, @password, "203.0.113.5")

    for index <- 1..10 do
      assert {:ok, _} =
               Governance.create_portal_api_key(first_login.token, tenant.slug, %{
                 name: "first-#{index}"
               })
    end

    assert {:error, :portal_key_limit_reached} =
             Governance.create_portal_api_key(first_login.token, tenant.slug, %{name: "eleventh"})

    assert {:ok, second_key} =
             Governance.create_portal_api_key(second_login.token, tenant.slug, %{name: "second"})
    create_request!(%{
      tenant_id: tenant.id,
      api_key_id: second_key.api_key.id,
      state: :completed
    })

    assert {:ok, listing} = Governance.list_portal_api_keys(second_login.token, tenant.slug)
    assert Enum.map(listing.keys, & &1.id) == [second_key.api_key.id]
    assert hd(listing.keys).request_count == 1

    first_key = Repo.one!(from(key in ApiKey, where: key.portal_user_id == ^first.id, limit: 1))

    assert {:error, :api_key_not_found} =
             Governance.revoke_portal_api_key(second_login.token, tenant.slug, first_key)

    assert {:ok, revoked} =
             Governance.revoke_portal_api_key(second_login.token, tenant.slug, second_key.api_key)

    assert revoked.revoked_at
  end

  test "legacy unowned developer portal keys remain tenant bearers but are absent from portal" do
    {tenant, user} = active_user!("named-legacy", "dev@example.com")

    {:ok, login} =
      Governance.create_portal_session(tenant.slug, user.email, @password, "203.0.113.6")

    generated = ApiKeySecret.generate()

    {:ok, legacy} =
      %ApiKey{}
      |> ApiKey.tenant_direct_changeset(%{
        tenant_id: tenant.id,
        name: "legacy",
        token_prefix: generated.token_prefix,
        secret_hash: generated.secret_hash,
        issuance_surface: "developer_portal"
      })
      |> Repo.insert()

    assert is_nil(legacy.portal_user_id)
    assert {:ok, %{principal_type: :tenant}} = Governance.authenticate_api_key(generated.token)
    assert {:ok, %{keys: []}} = Governance.list_portal_api_keys(login.token, tenant.slug)

    assert {:error, :api_key_not_found} =
             Governance.revoke_portal_api_key(login.token, tenant.slug, legacy)
  end

  defp active_user!(slug, email) when is_binary(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    active_user!(tenant, email)
  end

  defp active_user!(tenant, email) do
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: email})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(invite.token, @password)
    {tenant, Repo.get!(PortalUser, user.id)}
  end
end
