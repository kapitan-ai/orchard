defmodule Orchard.Governance.PortalGovernance do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.API.Transport

  alias Orchard.Governance.{
    ApiKey,
    ApiKeySecret,
    AuditLog,
    AuditWriter,
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
  alias Orchard.Requests.Request

  @active_key_limit 10
  @invite_seconds 604_800
  @session_seconds 28_800
  @idle_seconds 1_800
  @backoffs %{5 => 30, 6 => 60, 7 => 120, 8 => 240, 9 => 480}

  def create_invite(tenant_or_id, attrs) do
    attrs = Map.new(attrs)

    with :ok <- require_https(), {:ok, tenant} <- tenant(tenant_or_id) do
      AuditWriter.transaction(fn -> create_invite_transaction(tenant, attrs) end)
      |> unwrap()
    end
  end

  def copy_invite(tenant_or_id, user_or_id) do
    with :ok <- require_https(),
         {:ok, tenant} <- tenant(tenant_or_id),
         {:ok, user} <- user_for_tenant(tenant.id, id(user_or_id)) do
      AuditWriter.transaction(fn -> copy_invite_transaction(tenant, user.id) end)
      |> unwrap()
    end
  end

  def redeem_invite(slug, token, password) do
    with :ok <- require_https(), {:ok, password_hash} <- PortalPassword.hash(password) do
      AuditWriter.transaction(fn -> redeem_invite_transaction(slug, token, password_hash) end)
      |> unwrap()
    end
  end

  @spec validate_invite(String.t(), String.t()) ::
          :ok | {:error, :invalid_invite | :https_required}
  def validate_invite(slug, token) do
    current = now()

    with :ok <- require_https() do
      valid? =
        PortalInviteToken
        |> join(:inner, [invite], user in PortalUser, on: user.id == invite.portal_user_id)
        |> join(:inner, [_invite, user], tenant in Tenant, on: tenant.id == user.tenant_id)
        |> where([invite, user, tenant], invite.token_hash == ^digest(token))
        |> where([_invite, _user, tenant], tenant.slug == ^normalize_slug(slug))
        |> where([invite, user, _tenant], user.status == "invited")
        |> where([invite, _user, _tenant], is_nil(invite.redeemed_at))
        |> where([invite, _user, _tenant], invite.expires_at > ^current)
        |> Repo.exists?()

      if valid?, do: :ok, else: {:error, :invalid_invite}
    end
  end

  def disable_user(tenant_or_id, user_or_id) do
    with {:ok, tenant} <- tenant(tenant_or_id) do
      AuditWriter.transaction(fn -> disable_user_transaction(tenant.id, id(user_or_id)) end)
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
         {:ok, %{tenant: tenant, portal_user: user, session: session}} <-
           validate(session_token, slug),
         generated <- ApiKeySecret.generate() do
      identity = session_identity(tenant, user, session)

      AuditWriter.transaction(fn -> mint_key_transaction(identity, attrs, generated) end)
      |> unwrap()
    end
  end

  def list_keys(session_token, slug) do
    with {:ok, %{tenant: tenant, portal_user: user}} <- validate(session_token, slug) do
      api_keys =
        ApiKey
        |> where(
          [key],
          key.portal_user_id == ^user.id and key.tenant_id == ^tenant.id and
            key.issuance_surface == "developer_portal"
        )
        |> order_by([key], desc: key.inserted_at, desc: key.id)
        |> Repo.all()

      request_counts = portal_request_counts(tenant.id, Enum.map(api_keys, & &1.id))

      keys =
        Enum.map(api_keys, fn key ->
          %PortalApiKeySummary{
            id: key.id,
            name: key.name,
            token_prefix: key.token_prefix,
            issuance_surface: key.issuance_surface,
            status: ApiKey.status(key, now()),
            request_count: Map.get(request_counts, key.id, 0),
            revocable?: is_nil(key.revoked_at),
            inserted_at: key.inserted_at,
            last_used_at: key.last_used_at,
            expires_at: key.expires_at,
            revoked_at: key.revoked_at
          }
        end)

      {:ok, %{keys: keys, active_portal_count: active_key_count(tenant.id, user.id)}}
    end
  end

  def revoke_key(session_token, slug, key_or_id) do
    with :ok <- require_https(),
         {:ok, %{tenant: tenant, portal_user: user, session: session}} <-
           validate(session_token, slug) do
      identity = session_identity(tenant, user, session)

      AuditWriter.transaction(fn -> revoke_key_transaction(identity, key_or_id) end)
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

  defp create_invite_transaction(tenant, attrs) do
    case %PortalUser{}
         |> PortalUser.invite_changeset(%{
           tenant_id: tenant.id,
           email: attrs[:email] || attrs["email"]
         })
         |> Repo.insert() do
      {:ok, user} ->
        insert_portal_user_audit!(user, "portal_user.invited", user.inserted_at)
        user

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp redeem_invite_transaction(slug, token, password_hash) do
    tenant = redemption_tenant!(slug)
    user_id = redemption_user_id!(tenant.id, token)
    user = lock_invited_user!(tenant.id, user_id, :invalid_invite)
    current = now()
    invite = lock_valid_invite!(user.id, token, current)

    case user |> PortalUser.activation_changeset(password_hash) |> Repo.update() do
      {:ok, active} ->
        invite |> Changeset.change(redeemed_at: current) |> Repo.update!()
        delete_sessions(user.id)
        insert_portal_user_audit!(user, "portal_user.invite_redeemed", current)
        active

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp copy_invite_transaction(tenant, user_id) do
    user = lock_invited_user!(tenant.id, user_id, :portal_user_not_invited)
    previous_invite = Repo.get_by(PortalInviteToken, portal_user_id: user.id)

    action =
      if previous_invite, do: "portal_user.invite_reissued", else: "portal_user.invite_issued"

    :telemetry.execute(
      [:orchard, :governance, :portal_invite, :before_secret_generation],
      %{},
      %{portal_user_id: user.id}
    )

    occurred_at = now()
    token = "orchard_pi_" <> random_secret()

    expires_at =
      occurred_at
      |> DateTime.add(@invite_seconds, :second)
      |> extending_expiry(previous_invite)

    from(row in PortalInviteToken, where: row.portal_user_id == ^user.id)
    |> Repo.delete_all()

    %PortalInviteToken{}
    |> PortalInviteToken.changeset(%{
      portal_user_id: user.id,
      token_hash: digest(token),
      expires_at: expires_at
    })
    |> Repo.insert!()

    delete_sessions(user.id)
    insert_portal_user_audit!(user, action, occurred_at, expires_at)
    %{token: token, url: "/portal/#{tenant.slug}/invites/#{token}", expires_at: expires_at}
  end

  defp redemption_tenant!(slug) do
    case Repo.get_by(Tenant, slug: normalize_slug(slug)) do
      nil -> Repo.rollback(:invalid_invite)
      tenant -> tenant
    end
  end

  defp redemption_user_id!(tenant_id, token) do
    case PortalInviteToken
         |> join(:inner, [invite], user in PortalUser, on: user.id == invite.portal_user_id)
         |> where([invite, user], invite.token_hash == ^digest(token))
         |> where([_invite, user], user.tenant_id == ^tenant_id)
         |> select([_invite, user], user.id)
         |> Repo.one() do
      nil -> Repo.rollback(:invalid_invite)
      user_id -> user_id
    end
  end

  defp lock_invited_user!(tenant_id, user_id, error) do
    user =
      PortalUser
      |> where([row], row.id == ^user_id and row.tenant_id == ^tenant_id)
      |> where([user], user.status == "invited")
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(user), do: Repo.rollback(error)
    user
  end

  defp lock_valid_invite!(user_id, token, current) do
    invite =
      PortalInviteToken
      |> where([row], row.portal_user_id == ^user_id and row.token_hash == ^digest(token))
      |> where([row], is_nil(row.redeemed_at) and row.expires_at > ^current)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(invite), do: Repo.rollback(:invalid_invite)
    invite
  end

  defp disable_user_transaction(tenant_id, user_id) do
    user =
      PortalUser
      |> where([user], user.tenant_id == ^tenant_id and user.id == ^user_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(user), do: Repo.rollback(:portal_user_not_found)

    if user.status == "disabled" do
      user
    else
      occurred_at = now()

      case user |> PortalUser.disable_changeset(occurred_at) |> Repo.update() do
        {:ok, disabled} ->
          from(invite in PortalInviteToken,
            where: invite.portal_user_id == ^user.id and is_nil(invite.redeemed_at)
          )
          |> Repo.delete_all()

          delete_sessions(user.id)
          insert_portal_user_audit!(disabled, "portal_user.disabled", occurred_at)
          disabled

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end
  end

  defp mint_key_transaction(identity, attrs, generated) do
    user = lock_active_session_user!(identity)

    if active_key_count(identity.tenant_id, user.id) >= @active_key_limit,
      do: Repo.rollback(:portal_key_limit_reached)

    case %ApiKey{}
         |> ApiKey.tenant_direct_changeset(%{
           tenant_id: identity.tenant_id,
           portal_user_id: user.id,
           name: attrs[:name] || attrs["name"],
           token_prefix: generated.token_prefix,
           secret_hash: generated.secret_hash,
           issuance_surface: "developer_portal"
         })
         |> Repo.insert() do
      {:ok, key} ->
        insert_portal_api_key_audit!(user, key, "api_key.created", key.inserted_at)
        %{api_key: %{key | secret_hash: nil}, token: generated.token, curl: nil}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp revoke_key_transaction(identity, key_or_id) do
    user = lock_active_session_user!(identity)

    key =
      ApiKey
      |> where([key], key.id == ^id(key_or_id) and key.tenant_id == ^identity.tenant_id)
      |> where(
        [key],
        key.portal_user_id == ^identity.portal_user_id and
          key.issuance_surface == "developer_portal"
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(key), do: Repo.rollback(:api_key_not_found)

    if key.revoked_at do
      %{key | secret_hash: nil}
    else
      occurred_at = now()

      case key |> ApiKey.revoke_changeset(%{revoked_at: occurred_at}) |> Repo.update() do
        {:ok, revoked} ->
          insert_portal_api_key_audit!(user, revoked, "api_key.revoked", occurred_at)
          %{revoked | secret_hash: nil}

        {:error, reason} ->
          Repo.rollback(reason)
      end
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

  defp active_key_count(tenant_id, user_id) do
    current = now()

    ApiKey
    |> where(
      [k],
      k.tenant_id == ^tenant_id and k.portal_user_id == ^user_id and
        k.issuance_surface == "developer_portal" and is_nil(k.revoked_at)
    )
    |> where([k], is_nil(k.expires_at) or k.expires_at > ^current)
    |> Repo.aggregate(:count)
  end

  defp portal_request_counts(_tenant_id, []), do: %{}

  defp portal_request_counts(tenant_id, api_key_ids) do
    Request
    |> where([request], request.tenant_id == ^tenant_id)
    |> where([request], request.api_key_id in ^api_key_ids)
    |> group_by([request], request.api_key_id)
    |> select([request], {request.api_key_id, count(request.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp delete_sessions(user_id) do
    from(row in PortalSession, where: row.portal_user_id == ^user_id) |> Repo.delete_all()
  end

  defp insert_portal_user_audit!(user, action, occurred_at, expires_at \\ nil) do
    {actor_type, actor_id, surface} = portal_user_audit_provenance(user, action)

    %AuditLog{}
    |> audit_log_impl().changeset(%{
      scope: "tenant",
      tenant_id: user.tenant_id,
      api_key_id: nil,
      actor_type: actor_type,
      actor_id: actor_id,
      action: action,
      target_type: "portal_user",
      target_id: user.id,
      occurred_at: occurred_at,
      payload: portal_user_audit_payload(surface, expires_at)
    })
    |> AuditWriter.insert()
    |> case do
      {:ok, _audit_log} -> :ok
      {:error, _changeset} -> Repo.rollback(:audit_write_failed)
    end
  end

  defp audit_log_impl do
    Application.get_env(:orchard_controller, :governance_audit_log_impl, AuditLog)
  end

  defp insert_portal_api_key_audit!(user, key, action, occurred_at) do
    %AuditLog{}
    |> audit_log_impl().changeset(%{
      scope: "tenant",
      tenant_id: key.tenant_id,
      api_key_id: key.id,
      actor_type: "user",
      actor_id: user.id,
      action: action,
      target_type: "api_key",
      target_id: key.id,
      occurred_at: occurred_at,
      payload: portal_api_key_audit_payload(user, key)
    })
    |> AuditWriter.insert()
    |> case do
      {:ok, _audit_log} -> :ok
      {:error, _changeset} -> Repo.rollback(:audit_write_failed)
    end
  end

  defp portal_api_key_audit_payload(user, key) do
    %{
      "name" => key.name,
      "token_prefix" => key.token_prefix,
      "owner_type" => "tenant",
      "surface" => "developer_portal",
      "issuance_surface" => "developer_portal",
      "portal_user_id" => user.id
    }
    |> maybe_put_expiry(key.expires_at)
  end

  defp maybe_put_expiry(payload, nil), do: payload

  defp maybe_put_expiry(payload, expires_at),
    do: Map.put(payload, "expires_at", DateTime.to_iso8601(expires_at))

  defp session_identity(tenant, user, session),
    do: %{
      tenant_id: tenant.id,
      portal_user_id: user.id,
      session_epoch: session.password_epoch
    }

  defp lock_active_session_user!(identity) do
    user =
      PortalUser
      |> where(
        [row],
        row.id == ^identity.portal_user_id and row.tenant_id == ^identity.tenant_id
      )
      |> lock("FOR UPDATE")
      |> Repo.one()

    if is_nil(user) or user.status != "active" or user.session_epoch != identity.session_epoch,
      do: Repo.rollback(:invalid_session)

    user
  end

  defp portal_user_audit_provenance(_user, action)
       when action in [
              "portal_user.invited",
              "portal_user.invite_issued",
              "portal_user.invite_reissued",
              "portal_user.disabled"
            ],
       do: {"operator", nil, "console"}

  defp portal_user_audit_provenance(user, "portal_user.invite_redeemed"),
    do: {"user", user.id, "developer_portal"}

  defp portal_user_audit_payload(surface, nil), do: %{"surface" => surface}

  defp portal_user_audit_payload(surface, expires_at) do
    %{"surface" => surface, "expires_at" => DateTime.to_iso8601(expires_at)}
  end

  defp extending_expiry(candidate, nil), do: candidate

  defp extending_expiry(candidate, %PortalInviteToken{expires_at: previous}) do
    if DateTime.compare(candidate, previous) == :gt,
      do: candidate,
      else: DateTime.add(previous, 1, :microsecond)
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
