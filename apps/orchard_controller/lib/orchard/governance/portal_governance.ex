defmodule Orchard.Governance.PortalGovernance do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.API.Transport

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    PortalApiKeySummary,
    PortalInviteToken,
    PortalLoginThrottle,
    PortalPassword,
    PortalPasswordVerifier,
    PortalSession,
    PortalUser,
    Tenant
  }

  alias Orchard.Repo

  @active_key_limit 10
  @invite_seconds 604_800
  @session_seconds 28_800
  @idle_seconds 1_800
  @backoffs %{5 => 30, 6 => 60, 7 => 120, 8 => 240, 9 => 480}

  def create_invite(tenant_or_id, attrs) do
    attrs = Map.new(attrs)

    with :ok <- require_https(), {:ok, tenant} <- tenant(tenant_or_id) do
      %PortalUser{}
      |> PortalUser.invite_changeset(%{
        tenant_id: tenant.id,
        email: attrs[:email] || attrs["email"]
      })
      |> Repo.insert()
    end
  end

  def copy_invite(tenant_or_id, user_or_id) do
    with :ok <- require_https(),
         {:ok, tenant} <- tenant(tenant_or_id),
         {:ok, user} <- user_for_tenant(tenant.id, id(user_or_id)),
         true <- user.status == "invited" do
      token = "orchard_pi_" <> random_secret()
      expires_at = DateTime.add(now(), @invite_seconds, :second)

      Repo.transaction(fn ->
        from(row in PortalInviteToken, where: row.portal_user_id == ^user.id) |> Repo.delete_all()

        %PortalInviteToken{}
        |> PortalInviteToken.changeset(%{
          portal_user_id: user.id,
          token_hash: digest(token),
          expires_at: expires_at
        })
        |> Repo.insert!()

        delete_sessions(user.id)
        %{token: token, url: "/portal/#{tenant.slug}/invites/#{token}", expires_at: expires_at}
      end)
      |> unwrap()
    else
      false -> {:error, :portal_user_not_invited}
      error -> error
    end
  end

  def redeem_invite(token, password) do
    with :ok <- require_https(), {:ok, password_hash} <- PortalPassword.hash(password) do
      Repo.transaction(fn -> redeem_invite_transaction(token, password_hash) end)
      |> unwrap()
    end
  end

  def disable_user(tenant_or_id, user_or_id) do
    with {:ok, tenant} <- tenant(tenant_or_id),
         {:ok, user} <- user_for_tenant(tenant.id, id(user_or_id)) do
      Repo.transaction(fn -> disable_user_transaction(user) end)
      |> unwrap()
    end
  end

  def list_users(tenant_or_id) do
    with {:ok, tenant} <- tenant(tenant_or_id) do
      {:ok,
       PortalUser
       |> where([u], u.tenant_id == ^tenant.id)
       |> order_by([u], asc: u.email)
       |> Repo.all()}
    end
  end

  def login(slug, email, password, source) do
    email = PortalUser.normalize_email(email)
    fingerprints = fingerprints(slug, email, source)

    with :ok <- require_https(),
         :ok <- reserve_attempt(fingerprints),
         {:ok, tenant, user, password_hash} <-
           PortalPasswordVerifier.run(fn -> authenticate(slug, email, password) end) do
      finalize_login(tenant, user, password_hash, fingerprints)
    else
      {:error, :throttled} = error -> error
      _ -> {:error, :invalid_credentials}
    end
  end

  def validate(token, slug, opts \\ []) do
    current = now()

    with %PortalSession{} = session <- Repo.get_by(PortalSession, token_hash: digest(token)),
         %Tenant{} = tenant <- Repo.get_by(Tenant, slug: normalize_slug(slug)),
         %PortalUser{} = user <- Repo.get(PortalUser, session.portal_user_id),
         true <- session.tenant_id == tenant.id and user.tenant_id == tenant.id,
         true <- user.status == "active" and session.password_epoch == user.session_epoch,
         true <- DateTime.compare(session.absolute_expires_at, current) == :gt,
         true <-
           DateTime.compare(DateTime.add(session.last_seen_at, @idle_seconds, :second), current) ==
             :gt do
      session =
        if Keyword.get(opts, :touch, false),
          do: session |> Changeset.change(last_seen_at: current) |> Repo.update!(),
          else: session

      {:ok, %{session: session, tenant: tenant, portal_user: user}}
    else
      _ -> {:error, :invalid_session}
    end
  end

  def logout(token) do
    from(row in PortalSession, where: row.token_hash == ^digest(token)) |> Repo.delete_all()
    :ok
  end

  def mint_key(session_token, slug, attrs) do
    attrs = Map.new(attrs)

    with :ok <- require_https(),
         {:ok, %{tenant: tenant, portal_user: user}} <- validate(session_token, slug),
         generated <- ApiKeySecret.generate() do
      Repo.transaction(fn -> mint_key_transaction(tenant, user, attrs, generated) end)
      |> unwrap()
    end
  end

  def list_keys(session_token, slug) do
    with {:ok, %{portal_user: user}} <- validate(session_token, slug) do
      keys =
        ApiKey
        |> where(
          [key],
          key.portal_user_id == ^user.id and key.issuance_surface == "developer_portal"
        )
        |> order_by([key], desc: key.inserted_at, desc: key.id)
        |> Repo.all()
        |> Enum.map(fn key ->
          %PortalApiKeySummary{
            id: key.id,
            name: key.name,
            token_prefix: key.token_prefix,
            issuance_surface: key.issuance_surface,
            status: ApiKey.status(key, now()),
            request_count: 0,
            revocable?: is_nil(key.revoked_at),
            inserted_at: key.inserted_at,
            last_used_at: key.last_used_at,
            expires_at: key.expires_at,
            revoked_at: key.revoked_at
          }
        end)

      {:ok, %{keys: keys, active_portal_count: active_key_count(user.id)}}
    end
  end

  def revoke_key(session_token, slug, key_or_id) do
    with :ok <- require_https(),
         {:ok, %{tenant: tenant, portal_user: user}} <- validate(session_token, slug) do
      Repo.transaction(fn -> revoke_key_transaction(tenant, user, key_or_id) end)
      |> unwrap()
    end
  end

  def prune do
    current = now()
    from(row in PortalSession, where: row.absolute_expires_at < ^current) |> Repo.delete_all()
    :ok
  rescue
    _ -> :ok
  end

  defp redeem_invite_transaction(token, password_hash) do
    current = now()

    invite =
      PortalInviteToken
      |> where([row], row.token_hash == ^digest(token))
      |> where([row], is_nil(row.redeemed_at) and row.expires_at > ^current)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(invite), do: Repo.rollback(:invalid_invite)
    user = Repo.get!(PortalUser, invite.portal_user_id)

    case user |> PortalUser.activation_changeset(password_hash) |> Repo.update() do
      {:ok, active} ->
        invite |> Changeset.change(redeemed_at: current) |> Repo.update!()
        delete_sessions(user.id)
        active

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp disable_user_transaction(user) do
    case user |> PortalUser.disable_changeset(now()) |> Repo.update() do
      {:ok, disabled} ->
        delete_sessions(user.id)
        disabled

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp mint_key_transaction(tenant, user, attrs, generated) do
    PortalUser |> where([u], u.id == ^user.id) |> lock("FOR UPDATE") |> Repo.one!()

    if active_key_count(user.id) >= @active_key_limit,
      do: Repo.rollback(:portal_key_limit_reached)

    case %ApiKey{}
         |> ApiKey.tenant_direct_changeset(%{
           tenant_id: tenant.id,
           portal_user_id: user.id,
           name: attrs[:name] || attrs["name"],
           token_prefix: generated.token_prefix,
           secret_hash: generated.secret_hash,
           issuance_surface: "developer_portal"
         })
         |> Repo.insert() do
      {:ok, key} -> %{api_key: %{key | secret_hash: nil}, token: generated.token, curl: nil}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp revoke_key_transaction(tenant, user, key_or_id) do
    key =
      ApiKey
      |> where([key], key.id == ^id(key_or_id) and key.tenant_id == ^tenant.id)
      |> where(
        [key],
        key.portal_user_id == ^user.id and key.issuance_surface == "developer_portal"
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(key), do: Repo.rollback(:api_key_not_found)

    case key |> ApiKey.revoke_changeset(%{revoked_at: now()}) |> Repo.update() do
      {:ok, revoked} -> %{revoked | secret_hash: nil}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authenticate(slug, email, password) do
    tenant = Repo.get_by(Tenant, slug: normalize_slug(slug))
    user = tenant && Repo.get_by(PortalUser, tenant_id: tenant.id, email: email)

    case user do
      %PortalUser{status: "active", password_hash: hash} when is_binary(hash) ->
        if PortalPassword.verify(password, hash) == :ok,
          do: {:ok, tenant, user, hash},
          else: {:error, :invalid_credentials}

      _ ->
        PortalPassword.dummy_verify(password)
        {:error, :invalid_credentials}
    end
  end

  defp finalize_login(tenant, user, password_hash, fingerprints) do
    Repo.transaction(fn ->
      locked = PortalUser |> where([u], u.id == ^user.id) |> lock("FOR UPDATE") |> Repo.one!()

      if locked.status != "active" or locked.password_hash != password_hash,
        do: Repo.rollback(:invalid_credentials)

      token = "orchard_ps_" <> random_secret()
      current = now()

      session =
        %PortalSession{}
        |> PortalSession.changeset(%{
          tenant_id: tenant.id,
          portal_user_id: locked.id,
          token_hash: digest(token),
          password_epoch: locked.session_epoch,
          issued_at: current,
          last_seen_at: current,
          absolute_expires_at: DateTime.add(current, @session_seconds, :second)
        })
        |> Repo.insert!()

      delete_throttle(fingerprints)
      %{session: session, token: token, tenant: tenant, portal_user: locked}
    end)
    |> unwrap()
  end

  defp reserve_attempt(fingerprints) do
    current = now()

    Repo.transaction(fn ->
      row =
        PortalLoginThrottle
        |> where([r], r.organization_fingerprint == ^fingerprints.organization)
        |> where(
          [r],
          r.identity_fingerprint == ^fingerprints.identity and
            r.source_fingerprint == ^fingerprints.source
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      row =
        row ||
          %PortalLoginThrottle{}
          |> PortalLoginThrottle.changeset(
            Map.merge(fingerprints, %{
              organization_fingerprint: fingerprints.organization,
              identity_fingerprint: fingerprints.identity,
              source_fingerprint: fingerprints.source,
              failure_count: 0,
              last_failed_at: current
            })
          )
          |> Repo.insert!()

      if row.blocked_until && DateTime.compare(row.blocked_until, current) == :gt,
        do: Repo.rollback(:throttled)

      count = row.failure_count + 1

      blocked_until =
        if count < 5,
          do: nil,
          else: DateTime.add(current, Map.get(@backoffs, count, 900), :second)

      row
      |> PortalLoginThrottle.changeset(%{
        failure_count: count,
        last_failed_at: current,
        blocked_until: blocked_until
      })
      |> Repo.update!()

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, :throttled} -> {:error, :throttled}
    end
  end

  defp delete_throttle(fp) do
    from(r in PortalLoginThrottle,
      where:
        r.organization_fingerprint == ^fp.organization and
          r.identity_fingerprint == ^fp.identity and
          r.source_fingerprint == ^fp.source
    )
    |> Repo.delete_all()
  end

  defp active_key_count(user_id) do
    current = now()

    ApiKey
    |> where(
      [k],
      k.portal_user_id == ^user_id and k.issuance_surface == "developer_portal" and
        is_nil(k.revoked_at)
    )
    |> where([k], is_nil(k.expires_at) or k.expires_at > ^current)
    |> Repo.aggregate(:count)
  end

  defp delete_sessions(user_id) do
    from(row in PortalSession, where: row.portal_user_id == ^user_id) |> Repo.delete_all()
  end

  defp user_for_tenant(tenant_id, user_id) do
    case Repo.get_by(PortalUser, tenant_id: tenant_id, id: user_id) do
      nil -> {:error, :portal_user_not_found}
      user -> {:ok, user}
    end
  end

  defp tenant(%Tenant{} = tenant), do: {:ok, tenant}

  defp tenant(id) when is_binary(id) do
    case Repo.get(Tenant, id) do
      nil -> {:error, :tenant_not_found}
      tenant -> {:ok, tenant}
    end
  end

  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id), do: id

  defp require_https,
    do: if(Transport.public_api_https_enabled?(), do: :ok, else: {:error, :https_required})

  defp fingerprints(slug, email, source),
    do: %{
      organization: hmac("org:" <> normalize_slug(slug)),
      identity: hmac("id:" <> email),
      source: hmac("src:" <> source)
    }

  defp hmac(value), do: :crypto.mac(:hmac, :sha256, secret(), value)

  defp secret,
    do:
      Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])
      |> Keyword.fetch!(:secret_key_base)

  defp normalize_slug(slug), do: slug |> String.trim() |> String.downcase()
  defp random_secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(token), do: :crypto.hash(:sha256, token)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}
end
