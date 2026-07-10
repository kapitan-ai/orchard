defmodule Orchard.NodeEnrollmentSecurityTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes.{AdmissionCandidate, Node}
  alias Orchard.NodeTrust
  alias Orchard.NodeTrust.Store
  alias Orchard.Repo

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-enrollment-security-#{System.unique_integer([:positive])}"
      )

    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust)
    }

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: root)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)
    end)

    assert {:ok, trust} = NodeTrust.initialize(root: root, actor_id: "security-test")
    {:ok, root: root, trust: trust}
  end

  test "consumed enrollment resume is identity-bound and expires at its persisted bound", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    prepared = prepare_redemption(trust, now, DateTime.add(now, 3_600, :second))

    assert {:ok, first_response} = redeem(prepared, now)
    assert {:ok, consumed} = NodeEnrollments.fetch(prepared.enrollment_id)

    assert %{"resume_until" => resume_until_text} = consumed.resume_verifier_metadata
    assert {:ok, resume_until, 0} = DateTime.from_iso8601(resume_until_text)
    assert DateTime.compare(resume_until, now) == :gt
    assert DateTime.compare(resume_until, prepared.expires_at) in [:lt, :eq]

    assert {:ok, ^first_response} =
             redeem(prepared, DateTime.add(now, 1, :second))

    assert {:error, :node_enrollment_rejected} =
             redeem(prepared, DateTime.add(resume_until, 1, :second))
  end

  test "resume is capped by original enrollment expiry and rejected at the boundary", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    expires_at = DateTime.add(now, 60, :second)
    prepared = prepare_redemption(trust, now, expires_at)

    assert {:ok, first_response} = redeem(prepared, now)
    assert {:ok, consumed} = NodeEnrollments.fetch(prepared.enrollment_id)

    assert {:ok, resume_until, 0} =
             DateTime.from_iso8601(consumed.resume_verifier_metadata["resume_until"])

    assert DateTime.compare(resume_until, expires_at) == :eq
    assert {:ok, ^first_response} = redeem(prepared, DateTime.add(expires_at, -1, :second))
    assert {:error, :node_enrollment_rejected} = redeem(prepared, expires_at)
  end

  @tag :task_2_9
  test "crash before token consumption rolls back and the same redemption retries safely", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    prepared = prepare_redemption(trust, now, DateTime.add(now, 3_600, :second))
    test_pid = self()
    start_certificate_issuance_trace()

    injector = fn checkpoint ->
      send(test_pid, {:redemption_checkpoint, checkpoint})

      if checkpoint == :before_token_consumption do
        raise "simulated crash before token consumption"
      end
    end

    assert_raise RuntimeError, "simulated crash before token consumption", fn ->
      redeem(prepared, now, test_fault_injector: injector)
    end

    assert_receive {:redemption_checkpoint, :before_token_consumption}
    assert_redemption_rolled_back(prepared)
    assert certificate_issuance_call_count() == 0

    assert {:ok, response} = redeem(prepared, now)
    assert certificate_issuance_call_count() == 1
    assert response["node_id"] == prepared.node_id
    assert {:ok, consumed} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert consumed.state == :consumed
    assert consumed.node.state == :registered
  end

  @tag :task_2_9
  test "crash after token consumption before certificate issuance rolls back and retries", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    prepared = prepare_redemption(trust, now, DateTime.add(now, 3_600, :second))
    test_pid = self()
    start_certificate_issuance_trace()

    injector = fn checkpoint ->
      if checkpoint == :after_token_consumption_before_certificate_issuance do
        assert {:ok, interim} = NodeEnrollments.fetch(prepared.enrollment_id)

        send(
          test_pid,
          {:redemption_checkpoint, checkpoint, interim.state,
           interim.certificate_issuance_outcome}
        )

        raise "simulated crash after token consumption before certificate issuance"
      end
    end

    assert_raise RuntimeError,
                 "simulated crash after token consumption before certificate issuance",
                 fn ->
                   redeem(prepared, now, test_fault_injector: injector)
                 end

    assert_receive {:redemption_checkpoint, :after_token_consumption_before_certificate_issuance,
                    :consumed, :pending}

    assert_redemption_rolled_back(prepared)
    assert certificate_issuance_call_count() == 0

    assert {:ok, response} = redeem(prepared, now)
    assert certificate_issuance_call_count() == 1
    assert response["node_id"] == prepared.node_id
    assert {:ok, consumed} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert consumed.state == :consumed
    assert consumed.certificate_issuance_outcome == :issued
    assert consumed.node.state == :registered
  end

  @tag :task_2_9
  test "expired issued enrollment rejects before certificate issuance without mutation", %{
    trust: trust
  } do
    issued_at = ~U[2026-07-10 08:00:00Z]
    expires_at = DateTime.add(issued_at, 60, :second)
    prepared = prepare_redemption(trust, issued_at, expires_at)
    start_certificate_issuance_trace()

    assert {:error, :node_enrollment_rejected} = redeem(prepared, expires_at)
    assert certificate_issuance_call_count() == 0
    assert_redemption_rolled_back(prepared)
    assert Repo.aggregate(Node, :count, :id) == 1
    assert Repo.aggregate(AdmissionCandidate, :count, :id) == 0
  end

  test "redemption never overwrites an allocated Node that left provisioned state", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    prepared = prepare_redemption(trust, now, DateTime.add(now, 3_600, :second))

    {1, nil} =
      Repo.update_all(
        from(node in Node, where: node.id == ^prepared.node_id),
        set: [state: :admitted]
      )

    assert {:error, :node_enrollment_rejected} = redeem(prepared, now)
    assert Repo.get!(Node, prepared.node_id).state == :admitted
    assert {:ok, enrollment} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert enrollment.state == :issued
  end

  test "certificate issuance loads and signs with one immutable local trust generation", %{
    root: root,
    trust: trust
  } do
    {:ok, csr} = PKI.generate_csr(trust.cluster_id, Ecto.UUID.generate())
    node_id = node_id_from_csr(csr.node_uri_san)
    identity = PKI.certificate_identity(Ecto.UUID.generate(), csr.csr_fingerprint)

    :erlang.trace_pattern({Store, :load_current, 1}, true, [:call_count])

    on_exit(fn ->
      :erlang.trace_pattern({Store, :load_current, 1}, false, [:call_count])
    end)

    assert {:ok, _certificate} =
             NodeTrust.issue_node_certificate(
               %{
                 certificate_identifier: identity.identifier,
                 cluster_id: trust.cluster_id,
                 controller_id: trust.controller_id,
                 csr_pem: csr.csr_pem,
                 node_id: node_id,
                 now: ~U[2026-07-10 08:00:00Z],
                 serial: identity.serial,
                 trust_authority_id: trust.trust_authority_id
               },
               root: root
             )

    assert {:call_count, 1} = :erlang.trace_info({Store, :load_current, 1}, :call_count)
  end

  test "OpenSpec task 2.5 registration authority ignores colliding legacy node evidence", %{
    trust: trust
  } do
    now = ~U[2026-07-10 08:00:00Z]
    prepared = prepare_redemption(trust, now, DateTime.add(now, 3_600, :second))
    shared_hostname = "shared-worker.orchard.test"
    shared_advertise_addr = "10.0.0.41"
    shared_connect_host = "worker.orchard.test"
    allocated_target = "#{shared_connect_host}:50071"
    shared_beam_name = "orchard_node_agent@worker.orchard.test"

    {1, nil} =
      Repo.update_all(
        from(node in Node, where: node.id == ^prepared.node_id),
        set: [
          hostname: shared_hostname,
          advertise_addr: shared_advertise_addr,
          rpc_port: 50_071,
          connect_host: shared_connect_host,
          connect_port: 50_071,
          capabilities: %{
            "beam_node_name" => shared_beam_name,
            "runtime_target" => allocated_target
          }
        ]
      )

    decoy =
      %Node{}
      |> Node.changeset(%{
        hostname: shared_hostname,
        display_name: "decoy-worker",
        advertise_addr: shared_advertise_addr,
        rpc_port: 50_072,
        connect_host: shared_connect_host,
        connect_port: 50_072,
        state: :provisioned,
        health: :unreachable,
        capabilities: %{
          "beam_node_name" => shared_beam_name,
          "runtime_target" => allocated_target
        },
        tool_readiness: %{}
      })
      |> Repo.insert!()

    candidates = [
      insert_decoy_candidate!(
        decoy,
        prepared.node_id,
        :grpc,
        allocated_target,
        shared_hostname,
        shared_advertise_addr,
        shared_beam_name,
        now
      ),
      insert_decoy_candidate!(
        decoy,
        prepared.node_id,
        :beam,
        shared_beam_name,
        shared_hostname,
        shared_advertise_addr,
        shared_beam_name,
        now
      )
    ]

    decoy_before = Repo.get!(Node, decoy.id)
    candidate_before = Map.new(candidates, &{&1.id, &1})

    assert {:error, :node_enrollment_rejected} =
             NodeEnrollments.redeem(
               prepared.enrollment_id,
               %{
                 cluster_id: prepared.cluster_id,
                 controller_id: prepared.controller_id,
                 csr_pem: prepared.csr_pem,
                 node_id: decoy.id,
                 runtime_endpoint: prepared.runtime_endpoint,
                 token: prepared.token
               },
               now: now
             )

    assert Repo.get!(Node, prepared.node_id).state == :provisioned
    assert Repo.get!(Node, decoy.id) == decoy_before

    assert {:ok, response} = redeem(prepared, now)

    allocated = Repo.get!(Node, prepared.node_id)
    decoy_after = Repo.get!(Node, decoy.id)

    assert response["node_id"] == prepared.node_id
    assert response["node_uri_san"] == PKI.node_uri(prepared.cluster_id, prepared.node_id)
    assert allocated.state == :registered
    assert allocated.hostname == prepared.runtime_endpoint.hostname
    assert allocated.advertise_addr == prepared.runtime_endpoint.host
    assert allocated.connect_host == prepared.runtime_endpoint.host
    assert allocated.rpc_port == prepared.runtime_endpoint.port
    assert allocated.connect_port == prepared.runtime_endpoint.port
    refute allocated.hostname == shared_hostname
    refute allocated.advertise_addr == shared_advertise_addr
    assert decoy_after == decoy_before
    assert Repo.aggregate(Node, :count, :id) == 2

    for candidate <- candidates do
      assert Repo.get!(AdmissionCandidate, candidate.id) == candidate_before[candidate.id]
    end

    assert {:ok, enrollment} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert enrollment.node_id == prepared.node_id
    assert enrollment.node.state == :registered
  end

  test "issued certificate validation rejects time, path, key, SAN, serial, and identifier substitutions",
       %{root: root, trust: trust} do
    now = DateTime.utc_now()
    node_id = Ecto.UUID.generate()
    enrollment_id = Ecto.UUID.generate()
    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, node_id)
    identity = PKI.certificate_identity(enrollment_id, csr.csr_fingerprint)
    assert {:ok, material} = Store.load_current(root)

    assert {:ok, issued} =
             PKI.issue_node_certificate(%{
               ca_certificate_pem: material.ca_certificate_pem,
               ca_private_key_pem: material.ca_private_key_pem,
               certificate_identifier: identity.identifier,
               cluster_id: trust.cluster_id,
               csr_pem: csr.csr_pem,
               node_id: node_id,
               now: now,
               serial: identity.serial
             })

    attrs = %{
      certificate_identifier: issued.certificate_identifier,
      certificate_serial: issued.certificate_serial,
      cluster_id: trust.cluster_id,
      csr_fingerprint: csr.csr_fingerprint,
      enrollment_id: enrollment_id,
      node_id: node_id,
      node_certificate_pem: issued.certificate_pem,
      now: now,
      public_key_fingerprint: csr.public_key_fingerprint,
      runtime_ca_certificate_pem: material.ca_certificate_pem,
      runtime_trust_spki_sha256: material.ca_spki_fingerprint
    }

    assert :ok = PKI.validate_issued_identity(attrs)

    assert {:ok, other_ca} =
             Orchard.NodeTrust.PKI.generate(
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               now
             )

    invalid_cases = [
      Map.put(attrs, :now, DateTime.add(now, 7_776_001, :second)),
      Map.put(attrs, :now, DateTime.add(now, -120, :second)),
      attrs
      |> Map.put(:runtime_ca_certificate_pem, other_ca.ca_certificate_pem)
      |> Map.put(:runtime_trust_spki_sha256, other_ca.ca_spki_fingerprint),
      Map.put(attrs, :public_key_fingerprint, "sha256-substituted"),
      Map.put(attrs, :node_id, Ecto.UUID.generate()),
      Map.put(attrs, :certificate_serial, "1"),
      Map.put(attrs, :certificate_identifier, "nodecert_substituted")
    ]

    for invalid <- invalid_cases do
      assert {:error, :invalid_node_certificate} = PKI.validate_issued_identity(invalid)
    end
  end

  test "certificate issuance rejects local CA material that differs from persisted authority", %{
    root: root,
    trust: trust
  } do
    {1, nil} =
      Repo.update_all(
        Orchard.Nodes.TrustAuthority,
        set: [ca_spki_fingerprint: "sha256-substituted"]
      )

    node_id = Ecto.UUID.generate()
    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, node_id)
    identity = PKI.certificate_identity(Ecto.UUID.generate(), csr.csr_fingerprint)

    assert {:error, :node_certificate_issuance_failed} =
             NodeTrust.issue_node_certificate(
               %{
                 certificate_identifier: identity.identifier,
                 cluster_id: trust.cluster_id,
                 controller_id: trust.controller_id,
                 csr_pem: csr.csr_pem,
                 node_id: node_id,
                 now: DateTime.utc_now(),
                 serial: identity.serial,
                 trust_authority_id: trust.trust_authority_id
               },
               root: root
             )
  end

  defp insert_decoy_candidate!(
         decoy,
         claimed_node_id,
         transport,
         target,
         hostname,
         advertise_addr,
         beam_name,
         now
       ) do
    %AdmissionCandidate{}
    |> AdmissionCandidate.changeset(%{
      node_id: decoy.id,
      source: :runtime_endpoint_observation,
      admission_category: :pending_observed,
      observed_identity: %{
        "claimed_node_id" => claimed_node_id,
        "hostname" => hostname,
        "beam_node_name" => beam_name
      },
      target_ref: target,
      endpoint_transport: transport,
      endpoint_target: target,
      inventory: %{"advertise_addr" => advertise_addr},
      compatibility_evidence: %{},
      last_observed_at: now
    })
    |> Repo.insert!()
  end

  defp prepare_redemption(trust, now, expires_at) do
    assert {:ok, result} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 expires_at: expires_at,
                 node: %{
                   display_name: "security-#{System.unique_integer([:positive, :monotonic])}"
                 }
               },
               now: now
             )

    assert {:ok, _issued} = NodeEnrollments.mark_issued(result.enrollment.id, now: now)

    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, result.enrollment.node_id)

    %{
      cluster_id: trust.cluster_id,
      controller_id: trust.controller_id,
      csr_pem: csr.csr_pem,
      enrollment_id: result.enrollment.id,
      expires_at: expires_at,
      node_id: result.enrollment.node_id,
      runtime_endpoint: %{
        host: "127.0.0.1",
        hostname: "security-node.orchard.test",
        port: 50_061
      },
      token: result.bootstrap_token
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
        runtime_endpoint: prepared.runtime_endpoint,
        token: prepared.token
      },
      Keyword.put(opts, :now, now)
    )
  end

  defp assert_redemption_rolled_back(prepared) do
    assert {:ok, enrollment} = NodeEnrollments.fetch(prepared.enrollment_id)
    assert enrollment.state == :issued
    assert enrollment.consumed_at == nil
    assert enrollment.csr_fingerprint == nil
    assert enrollment.certificate_issuance_outcome == :not_started
    assert enrollment.certificate_identifier == nil
    assert enrollment.certificate_result == %{}
    assert enrollment.node.state == :provisioned
    assert Repo.aggregate(AdmissionCandidate, :count, :id) == 0

    assert Repo.aggregate(
             from(audit in Orchard.Governance.AuditLog,
               where:
                 audit.target_id == ^prepared.enrollment_id and
                   audit.action == "node_enrollment.consumed"
             ),
             :count,
             :id
           ) == 0
  end

  defp start_certificate_issuance_trace do
    :erlang.trace_pattern({NodeTrust, :issue_node_certificate, 1}, true, [:call_count])

    on_exit(fn ->
      :erlang.trace_pattern({NodeTrust, :issue_node_certificate, 1}, false, [:call_count])
    end)
  end

  defp certificate_issuance_call_count do
    assert {:call_count, count} =
             :erlang.trace_info({NodeTrust, :issue_node_certificate, 1}, :call_count)

    count
  end

  defp node_id_from_csr("urn:orchard:cluster:" <> rest) do
    [_cluster_id, node_id] = String.split(rest, ":node:", parts: 2)
    node_id
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
