defmodule Orchard.NodeAdmissionPreauthorizationsTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.BeamPeerGrants.Grant
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.NodeAdmissionPreauthorizations
  alias Orchard.NodeCredentials.Generation
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, AdmissionPreauthorization, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-preauthorized-admission-#{System.unique_integer([:positive])}"
      )

    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust),
      validator:
        Application.get_env(
          :orchard_controller,
          :node_admission_preauthorization_predicate_validator
        )
    }

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: root)

    Application.delete_env(
      :orchard_controller,
      :node_admission_preauthorization_predicate_validator
    )

    on_exit(fn ->
      File.rm_rf!(root)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)

      restore_app_env(
        :orchard_controller,
        :node_admission_preauthorization_predicate_validator,
        previous.validator
      )
    end)

    now = ~U[2026-09-21 12:00:00Z]
    assert {:ok, trust} = NodeTrust.initialize(root: root, actor_id: "kap-109-test")
    insert_controller!(trust.controller_id, now)

    {:ok, now: now, root: root, trust: trust}
  end

  test "manual mode is the durable deny-by-default admission mode", %{trust: trust, now: now} do
    attrs = preview_attrs(trust, now)

    assert %{mode: :manual, version: 1} = NodeAdmissionPreauthorizations.get_mode()

    assert {:error, :node_admission_preauthorization_disabled} =
             NodeAdmissionPreauthorizations.preview_issuance(attrs)
  end

  test "authoritative enrollment creation rejects an unconfirmed preview", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    attrs = preview_attrs(trust, now)
    assert {:ok, preview} = NodeAdmissionPreauthorizations.preview_issuance(attrs)

    assert {:error, :node_admission_preauthorization_confirmation_required} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 creator_id: "admin-1",
                 expires_at: attrs.expires_at,
                 node: %{display_name: "unconfirmed-preview"}
               },
               now: now,
               preauthorization_preview: preview
             )

    assert Repo.aggregate(AdmissionPreauthorization, :count, :id) == 0
  end

  test "exact preview redemption atomically admits once and exact replay returns the outcome", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)

    assert {:ok, response} = redeem(prepared, now)
    assert response["admission"]["outcome"] == "preauthorized_admitted"

    assert {:ok, ^response} = redeem(prepared, DateTime.add(now, 1, :second))
    assert Repo.get!(Node, prepared.node_id).state == :admitted

    assert Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id).state ==
             :consumed_admitted

    assert Repo.aggregate(AdmissionDecision, :count, :id) == 1
    assert Repo.aggregate(Policy, :count, :node_id) == 1
  end

  test "mode disablement after issuance registers pending review without admission authority", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)
    change_mode!(:manual, "pause automatic admission", DateTime.add(now, 1, :second))

    assert {:ok, response} = redeem(prepared, DateTime.add(now, 2, :second))

    assert response["admission"] == %{
             "outcome" => "registered_pending_review",
             "preauthorization_id" => prepared.preauthorization_id,
             "preauthorization_state" => "consumed_pending_review",
             "reason" => "admission_mode_disabled"
           }

    assert Repo.get!(Node, prepared.node_id).state == :registered
    assert Repo.aggregate(AdmissionDecision, :count, :id) == 0
    assert Repo.aggregate(Policy, :count, :node_id) == 0
  end

  test "revocation wins before redemption and divergent correlation fails closed", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)

    attrs = %{actor_type: "operator", actor_id: "admin-1", reason: "bundle custody lost"}

    assert {:ok, preview} =
             NodeAdmissionPreauthorizations.preview_revocation(
               prepared.preauthorization_id,
               attrs
             )

    assert {:ok, %{state: :revoked}} =
             NodeAdmissionPreauthorizations.revoke(
               prepared.preauthorization_id,
               attrs,
               confirmation_digest: preview.digest,
               now: DateTime.add(now, 1, :second)
             )

    assert {:error, :node_enrollment_rejected} =
             prepared
             |> Map.put(
               :preauthorization_digest,
               "sha256-#{Base.url_encode64(<<0::256>>, padding: false)}"
             )
             |> redeem(DateTime.add(now, 2, :second))

    assert Repo.get!(Node, prepared.node_id).state == :provisioned

    assert {:ok, response} = redeem(prepared, DateTime.add(now, 2, :second))
    assert response["admission"]["reason"] == "preauthorization_revoked"
    assert Repo.get!(Node, prepared.node_id).state == :registered
    assert Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id).state == :revoked
  end

  test "admission-only predicate drift consumes pending review and diagnostics omit secrets", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)

    Application.put_env(
      :orchard_controller,
      :node_admission_preauthorization_predicate_validator,
      fn _preauthorization, _node, _request -> {:error, :drift} end
    )

    assert {:ok, response} = redeem(prepared, now)
    assert response["admission"]["reason"] == "bound_admission_predicate_changed"

    preauthorization = Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id)
    refute inspect(preauthorization) =~ prepared.token
    refute inspect(response["admission"]) =~ prepared.token
    assert preauthorization.state == :consumed_pending_review
  end

  test "preauthorization expiry before Enrollment expiry remains terminal pending review", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)

    prepared =
      prepare_preauthorized_enrollment!(trust, now,
        preauthorization_expires_at: DateTime.add(now, 60, :second),
        enrollment_expires_at: DateTime.add(now, 600, :second)
      )

    assert {:ok, response} = redeem(prepared, DateTime.add(now, 60, :second))
    assert response["admission"]["reason"] == "preauthorization_expired"
    assert response["admission"]["preauthorization_state"] == "expired"

    preauthorization = Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id)
    assert preauthorization.state == :expired
    assert preauthorization.pending_review_audit_log_id
    assert Repo.get!(Node, prepared.node_id).state == :registered
    assert Repo.aggregate(AdmissionDecision, :count, :id) == 0
    assert Repo.aggregate(Policy, :count, :node_id) == 0
    assert Repo.aggregate(Grant, :count, :id) == 0
  end

  test "post-admission persistence failure rolls back the complete admitted outcome", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)

    injector = fn
      :after_admission_before_enrollment_finalization ->
        raise "simulated post-admission persistence failure"

      _checkpoint ->
        :ok
    end

    assert_raise RuntimeError, "simulated post-admission persistence failure", fn ->
      redeem(prepared, now, test_fault_injector: injector)
    end

    assert_preauthorized_redemption_rolled_back(prepared)
    assert {:ok, response} = redeem(prepared, now)
    assert response["admission"]["outcome"] == "preauthorized_admitted"
  end

  test "pending-review failure rolls back registration and consumption", %{
    trust: trust,
    now: now
  } do
    enable_preauthorized_mode!(now)
    prepared = prepare_preauthorized_enrollment!(trust, now)

    Application.put_env(
      :orchard_controller,
      :node_admission_preauthorization_predicate_validator,
      fn _preauthorization, _node, _request -> raise "simulated predicate failure" end
    )

    assert_raise RuntimeError, "simulated predicate failure", fn -> redeem(prepared, now) end
    assert_preauthorized_redemption_rolled_back(prepared)
  end

  test "concurrent exact redemptions return one durable admitted outcome", %{
    root: root,
    now: now
  } do
    :ok = Sandbox.checkin(Repo)
    on_exit(&clean_unboxed_fixture/0)

    prepared =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, trust} = NodeTrust.initialize(root: root, actor_id: "kap-109-race")
        insert_controller!(trust.controller_id, now)
        enable_preauthorized_mode!(now)
        prepare_preauthorized_enrollment!(trust, now)
      end)

    parent = self()

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          redeem(prepared, now,
            test_fault_injector: fn
              :before_token_consumption ->
                send(parent, {:redemption_locked, self()})

                receive do
                  :commit -> :ok
                end

              _checkpoint ->
                :ok
            end
          )
        end)
      end)

    assert_receive {:redemption_locked, first_pid}

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn -> redeem(prepared, now) end)
      end)

    assert Task.yield(second, 100) == nil
    send(first_pid, :commit)

    assert {:ok, response} = Task.await(first, 5_000)
    assert {:ok, ^response} = Task.await(second, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert response["admission"]["outcome"] == "preauthorized_admitted"
      assert Repo.get!(Node, prepared.node_id).state == :admitted
      assert Repo.aggregate(AdmissionDecision, :count, :id) == 1
      assert Repo.aggregate(Policy, :count, :node_id) == 1
      assert Repo.aggregate(Generation, :count, :id) == 1

      assert Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id).state ==
               :consumed_admitted
    end)
  end

  defp enable_preauthorized_mode!(now) do
    change_mode!(:enrollment_preauthorized, "authorize exact bundle admission", now)
  end

  defp change_mode!(mode, reason, now) do
    attrs = %{actor_type: "operator", actor_id: "admin-1", reason: reason}
    assert {:ok, preview} = NodeAdmissionPreauthorizations.preview_mode_change(mode, attrs)

    assert {:ok, changed} =
             NodeAdmissionPreauthorizations.change_mode(mode, attrs,
               confirmation_digest: preview.digest,
               now: now
             )

    changed
  end

  defp prepare_preauthorized_enrollment!(trust, now, opts \\ []) do
    preauthorization_expires_at =
      Keyword.get(opts, :preauthorization_expires_at, DateTime.add(now, 600, :second))

    enrollment_expires_at =
      Keyword.get(opts, :enrollment_expires_at, preauthorization_expires_at)

    attrs = preview_attrs(trust, now, preauthorization_expires_at)
    assert {:ok, preview} = NodeAdmissionPreauthorizations.preview_issuance(attrs)

    assert {:ok, result} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 creator_id: "admin-1",
                 expires_at: enrollment_expires_at,
                 node: %{display_name: "preauthorized-#{System.unique_integer([:positive])}"}
               },
               now: now,
               preauthorization_preview: preview,
               preauthorization_confirmation_digest: preview.digest
             )

    assert {:ok, _issued} = NodeEnrollments.mark_issued(result.enrollment.id, now: now)
    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, result.enrollment.node_id)

    %{
      cluster_id: trust.cluster_id,
      controller_id: trust.controller_id,
      csr_pem: csr.csr_pem,
      enrollment_id: result.enrollment.id,
      node_id: result.enrollment.node_id,
      preauthorization_id: result.preauthorization.id,
      preauthorization_digest: result.preauthorization.preview_digest,
      runtime_endpoint: %{
        host: "10.0.0.21",
        hostname: "preauthorized-node.orchard.test",
        port: 50_071
      },
      token: result.bootstrap_token
    }
  end

  defp preview_attrs(trust, now, expires_at \\ nil) do
    %{
      id: Ecto.UUID.generate(),
      enrollment_id: Ecto.UUID.generate(),
      node_id: Ecto.UUID.generate(),
      cluster_id: trust.cluster_id,
      issuing_controller_id: trust.controller_id,
      actor_type: "operator",
      actor_id: "admin-1",
      expires_at: expires_at || DateTime.add(now, 600, :second),
      pool_id: "general",
      pool_revision: "1",
      routing_policy_id: "default",
      routing_policy_revision: "1",
      controller_dispatch_ceiling: 1,
      capacity_policy_reason: "bounded test admission",
      bound_predicates: %{
        "hostname" => "preauthorized-node.orchard.test",
        "runtime_host" => "10.0.0.21",
        "runtime_port" => 50_071
      },
      confirmation_evidence: %{"bundle_theft_consequence_confirmed" => true}
    }
  end

  defp redeem(prepared, now, opts \\ []) do
    NodeEnrollments.redeem(
      prepared.enrollment_id,
      %{
        cluster_id: prepared.cluster_id,
        controller_id: prepared.controller_id,
        csr_pem: prepared.csr_pem,
        node_id: prepared.node_id,
        preauthorization_id: prepared.preauthorization_id,
        preauthorization_digest: prepared.preauthorization_digest,
        runtime_endpoint: prepared.runtime_endpoint,
        token: prepared.token
      },
      Keyword.put(opts, :now, now)
    )
  end

  defp insert_controller!(controller_id, now) do
    compact_id = String.replace(controller_id, "-", "")

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: controller_id,
      certificate_uri_san: "urn:orchard:controller:#{controller_id}",
      certificate_identifier: "serial:kap-109",
      certificate_fingerprint_sha256: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      canonical_beam_name: "orchard_controller_#{compact_id}@10.0.0.10",
      beam_authorization_root_id: Ecto.UUID.generate(),
      authorization_root_custody_ref: "owner-only-local:kap-109",
      status: :operational,
      first_enrolled_at: now
    })
    |> Repo.insert!()
  end

  defp assert_preauthorized_redemption_rolled_back(prepared) do
    assert {:ok, enrollment} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert enrollment.state == :issued
    assert enrollment.consumed_at == nil
    assert enrollment.certificate_issuance_outcome == :not_started
    assert enrollment.certificate_result == %{}
    assert enrollment.node.state == :provisioned
    assert Repo.get!(AdmissionPreauthorization, prepared.preauthorization_id).state == :authorized
    assert Repo.aggregate(AdmissionCandidate, :count, :id) == 0
    assert Repo.aggregate(AdmissionDecision, :count, :id) == 0
    assert Repo.aggregate(Policy, :count, :node_id) == 0
    assert Repo.aggregate(Grant, :count, :id) == 0
    assert Repo.aggregate(Generation, :count, :id) == 0
  end

  defp clean_unboxed_fixture do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("""
      TRUNCATE TABLE
        audit_logs,
        beam_disconnect_obligations,
        beam_peer_grants,
        node_credential_generations,
        node_dispatch_capacity_policies,
        node_runtime_capacity_evidence,
        node_admission_decisions,
        node_admission_candidates,
        node_admission_preauthorizations,
        node_enrollments,
        nodes,
        controller_instances,
        node_trust_authorities,
        cluster_identities
      CASCADE
      """)

      Repo.query!("""
      UPDATE node_admission_modes
      SET mode = 'manual',
          version = 1,
          changed_by_actor_type = NULL,
          changed_by_actor_id = NULL,
          changed_at = NULL,
          change_reason = NULL,
          updated_at = clock_timestamp()
      WHERE singleton = true
      """)
    end)
  end

  defp restore_app_env(application, key, nil), do: Application.delete_env(application, key)
  defp restore_app_env(application, key, value), do: Application.put_env(application, key, value)
end
