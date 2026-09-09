defmodule Orchard.Governance.PortalLifecycleAuditTest.InvalidAuditLog do
  alias Orchard.Governance.AuditLog

  def changeset(audit_log, attrs) do
    attrs = attrs |> Map.new() |> Map.delete(:target_type) |> Map.delete("target_type")
    AuditLog.changeset(audit_log, attrs)
  end
end

defmodule Orchard.Governance.PortalLifecycleAuditTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance

  alias Orchard.Governance.{
    ApiKey,
    AuditLog,
    PortalInviteToken,
    PortalPasswordVerifier,
    PortalSession,
    PortalUser,
    Tenant
  }

  alias Orchard.Repo

  @password "sixteen-chars-ok"

  setup do
    if Process.whereis(PortalPasswordVerifier) == nil do
      start_supervised!(PortalPasswordVerifier)
    end

    if Process.whereis(Orchard.Metrics.Supervisor) == nil do
      start_supervised!(Orchard.Metrics.Supervisor)
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

  test "SPEC.md §10.9 Portal User creation commits one bounded invited audit row" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "audit-create", name: "Audit Create"})

    assert {:ok, user} =
             Governance.create_portal_invite(tenant, %{email: "private@example.com"})

    audit =
      Repo.one!(
        from(row in AuditLog,
          where: row.action == "portal_user.invited" and row.target_id == ^user.id
        )
      )

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == nil
    assert audit.actor_type == "operator"
    assert audit.actor_id == nil
    assert audit.target_type == "portal_user"
    assert audit.target_id == user.id
    assert audit.occurred_at == user.inserted_at
    assert audit.payload == %{"surface" => "console"}

    payload = Jason.encode!(audit.payload)
    refute payload =~ user.email
    refute payload =~ "token"
    refute payload =~ "password"
    refute payload =~ "previous_invite_existed"

    refute Repo.exists?(
             from(invite in PortalInviteToken, where: invite.portal_user_id == ^user.id)
           )
  end

  test "SPEC.md §7.4a first Copy invite classifies and audits under the Portal User lock" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "audit-first-copy", name: "First Copy"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "copy@example.com"})

    assert {:ok, result} = Governance.copy_portal_invite(tenant, user)

    invite = Repo.get_by!(PortalInviteToken, portal_user_id: user.id)

    audit =
      Repo.one!(
        from(row in AuditLog,
          where: row.action == "portal_user.invite_issued" and row.target_id == ^user.id
        )
      )

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == nil
    assert audit.actor_type == "operator"
    assert audit.actor_id == nil
    assert audit.target_type == "portal_user"
    assert audit.target_id == user.id

    assert audit.payload == %{
             "surface" => "console",
             "expires_at" => DateTime.to_iso8601(result.expires_at)
           }

    assert result.expires_at == invite.expires_at
    assert result.expires_at == DateTime.add(audit.occurred_at, 604_800, :second)
    assert invite.token_hash == :crypto.hash(:sha256, result.token)

    evidence = Jason.encode!(audit.payload)
    refute evidence =~ result.token
    refute evidence =~ result.url
    refute evidence =~ user.email
    refute evidence =~ Base.encode16(invite.token_hash)
    refute evidence =~ "previous_invite_existed"
  end

  test "SPEC.md §7.4a concurrent Copy invite calls serialize issued then reissued classification" do
    :ok = Sandbox.checkin(Repo)
    slug = "audit-copy-race-#{System.unique_integer([:positive])}"
    on_exit(fn -> clean_unboxed_tenant!(slug) end)

    {tenant, user} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: "Copy Race"})
        {:ok, user} = Governance.create_portal_invite(tenant, %{email: "race@example.com"})
        {tenant, user}
      end)

    start_ref = make_ref()
    release_lock_ref = make_ref()
    continue_secret_ref = make_ref()
    user_id = user.id
    parent = self()

    handler_id = {__MODULE__, :invite_secret_generation, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :governance, :portal_invite, :before_secret_generation],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:before_invite_secret, self(), metadata.portal_user_id})

          receive do
            {^continue_secret_ref, :continue} -> :ok
          after
            5_000 -> raise "timed out waiting to generate the invite secret"
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    lock_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            PortalUser
            |> where([row], row.id == ^user.id)
            |> lock("FOR UPDATE")
            |> Repo.one!()

            send(parent, {:portal_user_lock_held, self()})

            receive do
              ^release_lock_ref -> :ok
            after
              5_000 -> raise "timed out holding the Portal User lock"
            end
          end)
        end)
      end)

    assert_receive {:portal_user_lock_held, lock_holder_pid}, 2_000

    copy_task = fn ->
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:copy_ready, self(), backend_pid})

          receive do
            ^start_ref -> {backend_pid, Governance.copy_portal_invite(tenant, user)}
          after
            5_000 -> raise "timed out waiting to start the Copy race"
          end
        end)
      end)
    end

    first_task = copy_task.()
    second_task = copy_task.()

    assert_receive {:copy_ready, first_task_pid, first_backend_pid}, 2_000
    assert_receive {:copy_ready, second_task_pid, second_backend_pid}, 2_000
    refute first_backend_pid == second_backend_pid

    backend_by_task = %{
      first_task_pid => first_backend_pid,
      second_task_pid => second_backend_pid
    }

    send(first_task.pid, start_ref)
    send(second_task.pid, start_ref)

    assert_backends_waiting_for_lock!([first_backend_pid, second_backend_pid])
    refute_received {:before_invite_secret, _pid, ^user_id}
    send(lock_holder_pid, release_lock_ref)
    assert {:ok, :ok} = Task.await(lock_holder, 2_000)

    assert_receive {:before_invite_secret, first_copy_pid, ^user_id}, 2_000

    second_backend_pid =
      backend_by_task |> Map.delete(first_copy_pid) |> Map.values() |> List.first()

    assert_backends_waiting_for_lock!([second_backend_pid])
    refute_received {:before_invite_secret, _pid, ^user_id}
    send(first_copy_pid, {continue_secret_ref, :continue})

    assert_receive {:before_invite_secret, second_copy_pid, ^user_id}, 2_000
    refute second_copy_pid == first_copy_pid
    send(second_copy_pid, {continue_secret_ref, :continue})

    results =
      [Task.await(first_task, 5_000), Task.await(second_task, 5_000)]
      |> Enum.map(fn {_backend_pid, {:ok, result}} -> result end)

    Sandbox.unboxed_run(Repo, fn ->
      audits =
        AuditLog
        |> where([row], row.target_id == ^user.id)
        |> where(
          [row],
          row.action in ["portal_user.invite_issued", "portal_user.invite_reissued"]
        )
        |> Repo.all()

      assert Enum.frequencies_by(audits, & &1.action) == %{
               "portal_user.invite_issued" => 1,
               "portal_user.invite_reissued" => 1
             }

      [earlier_expiry, later_expiry] = results |> Enum.map(& &1.expires_at) |> Enum.sort(DateTime)
      assert DateTime.compare(later_expiry, earlier_expiry) == :gt

      reissued = Enum.find(audits, &(&1.action == "portal_user.invite_reissued"))
      issued = Enum.find(audits, &(&1.action == "portal_user.invite_issued"))

      issued_expiry = DateTime.from_iso8601(issued.payload["expires_at"]) |> elem(1)
      reissued_expiry = DateTime.from_iso8601(reissued.payload["expires_at"]) |> elem(1)

      assert Enum.any?(results, &(&1.expires_at == issued_expiry))
      assert Enum.any?(results, &(&1.expires_at == reissued_expiry))
      assert issued.occurred_at == DateTime.add(issued_expiry, -604_800, :second)
      assert reissued_expiry == later_expiry
      assert DateTime.compare(reissued.occurred_at, issued.occurred_at) in [:eq, :gt]
      assert DateTime.compare(reissued.occurred_at, reissued_expiry) == :lt

      assert reissued.scope == "tenant"
      assert reissued.tenant_id == tenant.id
      assert reissued.api_key_id == nil
      assert reissued.actor_type == "operator"
      assert reissued.actor_id == nil
      assert reissued.target_type == "portal_user"
      assert reissued.target_id == user.id

      assert reissued.payload == %{
               "surface" => "console",
               "expires_at" => DateTime.to_iso8601(later_expiry)
             }

      current_invite = Repo.get_by!(PortalInviteToken, portal_user_id: user.id)
      assert current_invite.expires_at == later_expiry
      assert Enum.any?(results, &(&1.token |> digest() == current_invite.token_hash))
    end)

    clean_unboxed_tenant!(slug)
  end

  test "SPEC.md §10.9 invite redemption commits Portal User provenance atomically" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "audit-redeem", name: "Audit Redeem"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "redeem@example.com"})
    {:ok, invite_result} = Governance.copy_portal_invite(tenant, user)

    assert {:ok, active} =
             Governance.redeem_portal_invite(tenant.slug, invite_result.token, @password)

    invite = Repo.get_by!(PortalInviteToken, portal_user_id: user.id)

    audit =
      Repo.one!(
        from(row in AuditLog,
          where: row.action == "portal_user.invite_redeemed" and row.target_id == ^user.id
        )
      )

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == nil
    assert audit.actor_type == "user"
    assert audit.actor_id == user.id
    assert audit.target_type == "portal_user"
    assert audit.target_id == user.id
    assert audit.occurred_at == invite.redeemed_at
    assert audit.payload == %{"surface" => "developer_portal"}
    assert active.status == "active"
  end

  test "SPEC.md §10.9 invalid redemption attempts emit no succeeded audit row or metric" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "audit-invalid-redeem", name: "Invalid"})

    {:ok, replaced_user} =
      Governance.create_portal_invite(tenant, %{email: "replaced@example.com"})

    {:ok, replaced_token} = Governance.copy_portal_invite(tenant, replaced_user)
    {:ok, current_token} = Governance.copy_portal_invite(tenant, replaced_user)

    {:ok, expired_user} =
      Governance.create_portal_invite(tenant, %{email: "expired@example.com"})

    {:ok, expired_token} = Governance.copy_portal_invite(tenant, expired_user)

    PortalInviteToken
    |> Repo.get_by!(portal_user_id: expired_user.id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    {:ok, disabled_user} =
      Governance.create_portal_invite(tenant, %{email: "disabled@example.com"})

    {:ok, disabled_token} = Governance.copy_portal_invite(tenant, disabled_user)
    {:ok, _disabled} = Governance.disable_portal_user(tenant, disabled_user)

    {:ok, redeemed_user} =
      Governance.create_portal_invite(tenant, %{email: "redeemed@example.com"})

    {:ok, redeemed_token} = Governance.copy_portal_invite(tenant, redeemed_user)
    {:ok, _active} = Governance.redeem_portal_invite(tenant.slug, redeemed_token.token, @password)

    {:ok, other_tenant} =
      Governance.create_tenant(%{slug: "audit-invalid-redeem-other", name: "Other"})

    ref = attach_audit_metric()

    for token <- [
          "orchard_pi_invalid",
          replaced_token.token,
          expired_token.token,
          disabled_token.token,
          redeemed_token.token
        ] do
      assert {:error, :invalid_invite} =
               Governance.redeem_portal_invite(tenant.slug, token, @password)
    end

    assert {:error, :invalid_invite} =
             Governance.redeem_portal_invite(other_tenant.slug, current_token.token, @password)

    assert {:ok, _active} =
             Governance.redeem_portal_invite(tenant.slug, current_token.token, @password)

    assert Repo.aggregate(
             from(row in AuditLog,
               where:
                 row.tenant_id == ^tenant.id and
                   row.action == "portal_user.invite_redeemed"
             ),
             :count
           ) == 2

    assert_receive {^ref, %{value: 1}, %{action: "portal_user", outcome: "succeeded"}}
    refute_receive {^ref, _measurements, _metadata}
  end

  test "SPEC.md §10.9 disable audits one effective transition and repeats as a true no-op" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "audit-disable", name: "Audit Disable"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "disable@example.com"})

    assert {:ok, disabled} = Governance.disable_portal_user(tenant, user)

    audit =
      Repo.one!(
        from(row in AuditLog,
          where: row.action == "portal_user.disabled" and row.target_id == ^user.id
        )
      )

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == nil
    assert audit.actor_type == "operator"
    assert audit.actor_id == nil
    assert audit.target_type == "portal_user"
    assert audit.target_id == user.id
    assert audit.occurred_at == disabled.disabled_at
    assert audit.payload == %{"surface" => "console"}

    ref = attach_audit_metric()
    assert {:ok, repeated} = Governance.disable_portal_user(tenant, user)
    assert repeated.disabled_at == disabled.disabled_at
    assert repeated.session_epoch == disabled.session_epoch
    assert repeated.updated_at == disabled.updated_at

    assert Repo.aggregate(
             from(row in AuditLog,
               where: row.action == "portal_user.disabled" and row.target_id == ^user.id
             ),
             :count
           ) == 1

    refute_receive {^ref, _measurements, %{outcome: "succeeded"}}, 100
  end

  test "SPEC.md §10.9 Portal key mint commits one bounded user-provenance audit row" do
    {tenant, user, session} = active_session!("audit-key-mint")

    assert {:ok, minted} =
             Governance.create_portal_api_key(session.token, tenant.slug, %{name: "workstation"})

    audit = Repo.get_by!(AuditLog, action: "api_key.created", api_key_id: minted.api_key.id)

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == minted.api_key.id
    assert audit.actor_type == "user"
    assert audit.actor_id == user.id
    assert audit.target_type == "api_key"
    assert audit.target_id == minted.api_key.id
    assert audit.occurred_at == minted.api_key.inserted_at

    assert audit.payload == %{
             "name" => "workstation",
             "token_prefix" => minted.api_key.token_prefix,
             "owner_type" => "tenant",
             "surface" => "developer_portal",
             "issuance_surface" => "developer_portal",
             "portal_user_id" => user.id
           }

    evidence = Jason.encode!(audit.payload)
    refute evidence =~ minted.token
    refute evidence =~ "secret_hash"
    refute evidence =~ user.email
  end

  test "SPEC.md §10.9 Portal key revoke audits one effective transition and repeats as a no-op" do
    {tenant, user, session} = active_session!("audit-key-revoke")

    {:ok, minted} =
      Governance.create_portal_api_key(session.token, tenant.slug, %{name: "retired"})

    assert {:ok, revoked} =
             Governance.revoke_portal_api_key(session.token, tenant.slug, minted.api_key)

    audit = Repo.get_by!(AuditLog, action: "api_key.revoked", api_key_id: minted.api_key.id)

    assert audit.scope == "tenant"
    assert audit.tenant_id == tenant.id
    assert audit.api_key_id == minted.api_key.id
    assert audit.actor_type == "user"
    assert audit.actor_id == user.id
    assert audit.target_type == "api_key"
    assert audit.target_id == minted.api_key.id
    assert audit.occurred_at == revoked.revoked_at

    assert audit.payload == %{
             "name" => "retired",
             "token_prefix" => minted.api_key.token_prefix,
             "owner_type" => "tenant",
             "surface" => "developer_portal",
             "issuance_surface" => "developer_portal",
             "portal_user_id" => user.id
           }

    ref = attach_audit_metric()

    assert {:ok, repeated} =
             Governance.revoke_portal_api_key(session.token, tenant.slug, minted.api_key)

    assert repeated.revoked_at == revoked.revoked_at
    assert repeated.updated_at == revoked.updated_at

    assert Repo.aggregate(
             from(row in AuditLog,
               where: row.action == "api_key.revoked" and row.api_key_id == ^minted.api_key.id
             ),
             :count
           ) == 1

    refute_receive {^ref, _measurements, %{outcome: "succeeded"}}, 100
  end

  test "SPEC.md §7.4a Portal key mint rejects an epoch that becomes stale after validation" do
    {tenant, user, session} = active_session!("audit-stale-mint")

    {result, queries} =
      while_validation_is_paused(
        fn ->
          Governance.create_portal_api_key(session.token, tenant.slug, %{name: "stale-mint"})
        end,
        fn -> increment_session_epoch!(user) end
      )

    assert result == {:error, :invalid_session}
    refute Enum.any?(queries, &String.contains?(&1, ~s|FROM "api_keys"|))
    refute Repo.get_by(ApiKey, name: "stale-mint")
    refute Repo.get_by(AuditLog, action: "api_key.created", actor_id: user.id)
  end

  test "SPEC.md §7.4a Portal key revoke rejects a stale epoch before locking the API key" do
    {tenant, user, session} = active_session!("audit-stale-revoke")
    {:ok, minted} = Governance.create_portal_api_key(session.token, tenant.slug, %{name: "kept"})

    {result, queries} =
      while_validation_is_paused(
        fn ->
          Governance.revoke_portal_api_key(session.token, tenant.slug, minted.api_key)
        end,
        fn ->
          increment_session_epoch!(user)
        end
      )

    assert result == {:error, :invalid_session}
    refute Enum.any?(queries, &String.contains?(&1, ~s|FROM "api_keys"|))
    persisted = Repo.get!(ApiKey, minted.api_key.id)
    assert persisted.revoked_at == nil
    refute Repo.get_by(AuditLog, action: "api_key.revoked", api_key_id: persisted.id)
  end

  test "SPEC.md §10.9 every lifecycle action rolls its domain mutation back on audit failure" do
    {:ok, creation_tenant} =
      Governance.create_tenant(%{slug: "audit-fail-create", name: "Audit Fail Create"})

    {:ok, issue_tenant} =
      Governance.create_tenant(%{slug: "audit-fail-issue", name: "Audit Fail Issue"})

    {:ok, issue_user} =
      Governance.create_portal_invite(issue_tenant, %{email: "issue@example.com"})

    {:ok, reissue_tenant} =
      Governance.create_tenant(%{slug: "audit-fail-reissue", name: "Audit Fail Reissue"})

    {:ok, reissue_user} =
      Governance.create_portal_invite(reissue_tenant, %{email: "reissue@example.com"})

    {:ok, _first_reissue} = Governance.copy_portal_invite(reissue_tenant, reissue_user)
    original_reissue = Repo.get_by!(PortalInviteToken, portal_user_id: reissue_user.id)

    {:ok, redeem_tenant} =
      Governance.create_tenant(%{slug: "audit-fail-redeem", name: "Audit Fail Redeem"})

    {:ok, redeem_user} =
      Governance.create_portal_invite(redeem_tenant, %{email: "redeem@example.com"})

    {:ok, redeem_invite} = Governance.copy_portal_invite(redeem_tenant, redeem_user)

    {disable_tenant, disable_user, disable_session} = active_session!("audit-fail-disable")

    {:ok, disable_key} =
      Governance.create_portal_api_key(disable_session.token, disable_tenant.slug, %{
        name: "survives-disable"
      })

    {mint_tenant, mint_user, mint_session} = active_session!("audit-fail-mint")
    {revoke_tenant, _revoke_user, revoke_session} = active_session!("audit-fail-revoke")

    {:ok, revoke_key} =
      Governance.create_portal_api_key(revoke_session.token, revoke_tenant.slug, %{
        name: "survives-revoke"
      })

    ref = attach_audit_metric()

    with_invalid_audit(fn ->
      assert {:error, :audit_write_failed} =
               Governance.create_portal_invite(creation_tenant, %{
                 email: "rolled-back@example.com"
               })

      assert {:error, :audit_write_failed} =
               Governance.copy_portal_invite(issue_tenant, issue_user)

      assert {:error, :audit_write_failed} =
               Governance.copy_portal_invite(reissue_tenant, reissue_user)

      assert {:error, :audit_write_failed} =
               Governance.redeem_portal_invite(
                 redeem_tenant.slug,
                 redeem_invite.token,
                 @password
               )

      assert {:error, :audit_write_failed} =
               Governance.disable_portal_user(disable_tenant, disable_user)

      assert {:error, :audit_write_failed} =
               Governance.create_portal_api_key(mint_session.token, mint_tenant.slug, %{
                 name: "rolled-back-key"
               })

      assert {:error, :audit_write_failed} =
               Governance.revoke_portal_api_key(
                 revoke_session.token,
                 revoke_tenant.slug,
                 revoke_key.api_key
               )
    end)

    refute Repo.get_by(PortalUser,
             tenant_id: creation_tenant.id,
             email: "rolled-back@example.com"
           )

    refute Repo.get_by(PortalInviteToken, portal_user_id: issue_user.id)

    persisted_reissue = Repo.get_by!(PortalInviteToken, portal_user_id: reissue_user.id)
    assert persisted_reissue.id == original_reissue.id
    assert persisted_reissue.token_hash == original_reissue.token_hash
    assert persisted_reissue.expires_at == original_reissue.expires_at

    persisted_redeem_user = Repo.get!(PortalUser, redeem_user.id)
    persisted_redeem_invite = Repo.get_by!(PortalInviteToken, portal_user_id: redeem_user.id)
    assert persisted_redeem_user.status == "invited"
    assert persisted_redeem_invite.redeemed_at == nil

    persisted_disable_user = Repo.get!(PortalUser, disable_user.id)
    assert persisted_disable_user.status == "active"
    assert persisted_disable_user.session_epoch == disable_user.session_epoch
    assert Repo.get_by!(PortalSession, token_hash: digest(disable_session.token))
    assert Repo.get!(ApiKey, disable_key.api_key.id).revoked_at == nil

    refute Repo.get_by(ApiKey,
             portal_user_id: mint_user.id,
             name: "rolled-back-key"
           )

    assert Repo.get!(ApiKey, revoke_key.api_key.id).revoked_at == nil

    for _action <- 1..5 do
      assert_receive {^ref, %{value: 1}, %{action: "portal_user", outcome: "failed"}}
    end

    for _action <- 1..2 do
      assert_receive {^ref, %{value: 1}, %{action: "api_key", outcome: "failed"}}
    end

    refute_received {^ref, _measurements, %{outcome: "succeeded"}}
  end

  defp active_session!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "#{slug}@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(tenant.slug, invite.token, @password)

    {:ok, session} =
      Governance.create_portal_session(
        tenant.slug,
        user.email,
        @password,
        "203.0.113.#{System.unique_integer([:positive])}"
      )

    {tenant, user, session}
  end

  defp while_validation_is_paused(operation, mutation) do
    parent = self()
    start_ref = make_ref()
    handler_id = {__MODULE__, :paused_validation, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:observed_query, self(), metadata.query})

          if String.contains?(metadata.query, ~s|FROM "portal_users" AS p0|) and
               not String.contains?(metadata.query, "FOR UPDATE") do
            send(parent, {:portal_user_validated, self()})

            receive do
              :continue_after_epoch_change -> :ok
            after
              2_000 -> raise "timed out waiting for the epoch change"
            end
          end
        end,
        nil
      )

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        receive do
          ^start_ref -> operation.()
        end
      end)

    try do
      send(task.pid, start_ref)
      assert_receive {:portal_user_validated, task_pid}, 2_000
      mutation.()
      send(task_pid, :continue_after_epoch_change)
      result = Task.await(task, 2_000)
      {result, collect_observed_queries(task.pid, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp increment_session_epoch!(user) do
    user
    |> Ecto.Changeset.change(session_epoch: user.session_epoch + 1)
    |> Repo.update!()
  end

  defp collect_observed_queries(task_pid, queries) do
    receive do
      {:observed_query, ^task_pid, query} ->
        collect_observed_queries(task_pid, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp assert_backends_waiting_for_lock!(backend_pids) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await_backend_lock_wait(backend_pids, deadline)
  end

  defp await_backend_lock_wait(backend_pids, deadline) do
    waiting_count =
      Sandbox.unboxed_run(Repo, fn ->
        [[count]] =
          Repo.query!(
            "SELECT count(DISTINCT pid) FROM pg_locks WHERE pid = ANY($1::integer[]) AND NOT granted",
            [backend_pids]
          ).rows

        count
      end)

    cond do
      waiting_count == length(backend_pids) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected database backends #{inspect(backend_pids)} to be waiting on locks")

      true ->
        Process.sleep(10)
        await_backend_lock_wait(backend_pids, deadline)
    end
  end

  defp with_invalid_audit(fun) do
    key = :governance_audit_log_impl
    previous = Application.get_env(:orchard_controller, key, :missing)

    Application.put_env(
      :orchard_controller,
      key,
      Orchard.Governance.PortalLifecycleAuditTest.InvalidAuditLog
    )

    try do
      fun.()
    after
      case previous do
        :missing -> Application.delete_env(:orchard_controller, key)
        value -> Application.put_env(:orchard_controller, key, value)
      end
    end
  end

  defp attach_audit_metric do
    owner = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :metrics, :audit_events],
        fn _event, measurements, metadata, _config ->
          send(owner, {ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp clean_unboxed_tenant!(slug) do
    Sandbox.unboxed_run(Repo, fn ->
      case Repo.get_by(Tenant, slug: slug) do
        nil ->
          :ok

        tenant ->
          user_ids =
            PortalUser
            |> where([user], user.tenant_id == ^tenant.id)
            |> select([user], user.id)
            |> Repo.all()

          Repo.query!("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

          try do
            Repo.delete_all(from(row in AuditLog, where: row.tenant_id == ^tenant.id))
          after
            Repo.query!("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")
          end

          Repo.delete_all(from(row in PortalSession, where: row.portal_user_id in ^user_ids))
          Repo.delete_all(from(row in PortalInviteToken, where: row.portal_user_id in ^user_ids))
          Repo.delete_all(from(row in ApiKey, where: row.portal_user_id in ^user_ids))
          Repo.delete_all(from(row in PortalUser, where: row.id in ^user_ids))
          Repo.delete!(tenant)
      end
    end)
  end

  defp digest(token), do: :crypto.hash(:sha256, token)
end
