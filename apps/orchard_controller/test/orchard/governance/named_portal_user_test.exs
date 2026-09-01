defmodule Orchard.Governance.NamedPortalUserTest do
  use Orchard.DataCase, async: false

  import Ecto.Query
  import Orchard.TestSupport.ModelRequestFixtures, only: [create_request!: 1]

  alias Orchard.Governance

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    PortalInviteToken,
    PortalSession,
    PortalUser,
    PortalUserSummary
  }

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

    assert {:error, :invalid_invite} =
             Governance.redeem_portal_invite(tenant.slug, first.token, @password)

    assert {:ok, active} =
             Governance.redeem_portal_invite(tenant.slug, second.token, @password)

    assert active.status == "active"
    assert active.password_hash != @password

    assert {:error, :invalid_invite} =
             Governance.redeem_portal_invite(tenant.slug, second.token, @password)
  end

  test "SPEC 7.4a lists a tenant-scoped secret-free Not issued Portal User summary" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "summary", name: "Summary"})
    {:ok, other_tenant} = Governance.create_tenant(%{slug: "summary-other", name: "Other"})

    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, other_user} = Governance.create_portal_invite(other_tenant, %{email: user.email})
    {:ok, _other_invite} = Governance.copy_portal_invite(other_tenant, other_user)

    assert {:ok, [%PortalUserSummary{} = summary]} =
             Governance.list_portal_user_summaries(tenant)

    assert Map.from_struct(summary) == %{
             id: user.id,
             email: user.email,
             status: "invited",
             invite_context: :not_issued,
             invite_expires_at: nil
           }
  end

  test "SPEC 7.4a lists a pending invite with its committed expiry" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "pending-summary", name: "Pending"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "pending@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)

    assert {:ok,
            [
              %PortalUserSummary{
                status: "invited",
                invite_context: :pending,
                invite_expires_at: expires_at
              }
            ]} = Governance.list_portal_user_summaries(tenant)

    assert expires_at == invite.expires_at
  end

  test "SPEC 7.4a lists an invite at or past expiry as Expired" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "expired-summary", name: "Expired"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "expired@example.com"})
    {:ok, _invite} = Governance.copy_portal_invite(tenant, user)

    expires_at = DateTime.add(DateTime.utc_now(), -1, :second)

    PortalInviteToken
    |> Repo.get_by!(portal_user_id: user.id)
    |> Ecto.Changeset.change(expires_at: expires_at)
    |> Repo.update!()

    assert {:ok,
            [
              %PortalUserSummary{
                status: "invited",
                invite_context: :expired,
                invite_expires_at: ^expires_at
              }
            ]} = Governance.list_portal_user_summaries(tenant)
  end

  test "SPEC 7.4a keeps Active primary with subordinate Redeemed context" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "redeemed-summary", name: "Redeemed"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "redeemed@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, _active} = Governance.redeem_portal_invite(tenant.slug, invite.token, @password)

    assert {:ok,
            [
              %PortalUserSummary{
                status: "active",
                invite_context: :redeemed,
                invite_expires_at: nil
              }
            ]} = Governance.list_portal_user_summaries(tenant)
  end

  test "SPEC 7.4a disablement invalidates an outstanding invite without reactivation" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "disable-invite", name: "Disable Invite"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)

    assert {:ok, disabled} = Governance.disable_portal_user(tenant, user)
    assert disabled.status == "disabled"

    assert {:error, :invalid_invite} =
             Governance.redeem_portal_invite(tenant.slug, invite.token, @password)

    assert {:ok, [%PortalUser{} = persisted]} = Governance.list_portal_users(tenant)
    assert persisted.status == "disabled"

    assert Repo.aggregate(
             from(token in PortalInviteToken, where: token.portal_user_id == ^user.id),
             :count
           ) == 0
  end

  test "SPEC 7.4a legacy disabled user with an outstanding invite cannot reactivate" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "legacy-disabled", name: "Legacy Disabled"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)

    assert {:ok, disabled} =
             user
             |> PortalUser.disable_changeset(DateTime.utc_now())
             |> Repo.update()

    token_row = Repo.get_by!(PortalInviteToken, portal_user_id: user.id)

    assert {:error, :invalid_invite} =
             Governance.redeem_portal_invite(tenant.slug, invite.token, @password)

    persisted = Repo.get!(PortalUser, user.id)
    assert persisted.status == "disabled"
    assert persisted.disabled_at == disabled.disabled_at
    assert persisted.password_hash == disabled.password_hash

    persisted_token = Repo.get!(PortalInviteToken, token_row.id)
    assert persisted_token.token_hash == token_row.token_hash
    assert persisted_token.redeemed_at == token_row.redeemed_at
  end

  test "named login creates a user-owned session and disable ends sessions only" do
    {tenant, user} = active_user!("named-login", "dev@example.com")
    {_tenant, other_user} = active_user!(tenant, "other@example.com")

    assert {:ok, login} =
             Governance.create_portal_session(tenant.slug, user.email, @password, "203.0.113.1")

    assert {:ok, other_login} =
             Governance.create_portal_session(
               tenant.slug,
               other_user.email,
               @password,
               "203.0.113.8"
             )

    persisted = Repo.get!(PortalSession, login.session.id)
    assert persisted.portal_user_id == user.id

    assert {:ok, %{portal_user: validated}} =
             Governance.validate_portal_session(login.token, tenant.slug)

    assert validated.id == user.id

    assert {:ok, minted} =
             Governance.create_portal_api_key(login.token, tenant.slug, %{name: "keep"})

    assert {:ok, other_minted} =
             Governance.create_portal_api_key(other_login.token, tenant.slug, %{
               name: "other-keep"
             })

    assert {:ok, _} = Governance.disable_portal_user(tenant, user)

    assert {:error, :invalid_session} =
             Governance.validate_portal_session(login.token, tenant.slug)

    assert {:ok, %{portal_user: validated_other}} =
             Governance.validate_portal_session(other_login.token, tenant.slug)

    assert validated_other.id == other_user.id

    for result <- [minted, other_minted] do
      assert {:ok, auth} = Governance.authenticate_api_key(result.token)
      assert auth.principal_type == :tenant
      assert is_nil(Repo.get!(ApiKey, result.api_key.id).revoked_at)
    end
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

  test "SPEC 10.2 portal key listing requires Portal User and Organization ownership" do
    {tenant, user} = active_user!("key-list-tenant", "dev@example.com")
    {:ok, other_tenant} = Governance.create_tenant(%{slug: "key-list-other", name: "Other"})

    {:ok, login} =
      Governance.create_portal_session(tenant.slug, user.email, @password, "203.0.113.7")

    generated = ApiKeySecret.generate()

    {:ok, _inconsistent_key} =
      %ApiKey{}
      |> ApiKey.tenant_direct_changeset(%{
        tenant_id: other_tenant.id,
        portal_user_id: user.id,
        name: "other-tenant-key",
        token_prefix: generated.token_prefix,
        secret_hash: generated.secret_hash,
        issuance_surface: "developer_portal"
      })
      |> Repo.insert()

    assert {:ok, %{keys: [], active_portal_count: 0}} =
             Governance.list_portal_api_keys(login.token, tenant.slug)
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
    {:ok, user} = Governance.redeem_portal_invite(tenant.slug, invite.token, @password)
    {tenant, Repo.get!(PortalUser, user.id)}
  end
end
