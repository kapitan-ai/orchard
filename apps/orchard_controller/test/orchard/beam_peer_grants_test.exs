defmodule Orchard.BeamPeerGrantsTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.BeamPeerGrants
  alias Orchard.BeamPeerGrants.{ControllerInitializer, ControlListener, ControlServer, Grant}
  alias Orchard.Cluster.V1.{RetrieveBeamPeerGrantRequest, RetrieveBeamPeerGrantResponse}
  alias Orchard.ControllerInstances
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.DispatchCapacity
  alias Orchard.Governance.AuditLog
  alias Orchard.Node.{BeamPeerGrantBootstrap, BeamPeerGrantStore, RuntimeTLS}
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionDecision, Enrollment}
  alias Orchard.Nodes.Node
  alias Orchard.NodeTrust
  alias Orchard.RuntimeEndpoint.{ActivationProbe, AuthenticatedPeer, BeamClient, Target}
  alias Orchard.TransportTLS.CertificateIdentity

  defmodule AuthenticatedStatusServer do
    alias Orchard.Nodes.Node
    alias Orchard.Repo

    def status(target, _opts) do
      node = Repo.get!(Node, target.node_id)

      {:ok,
       %{
         node_metadata: %{
           node_id: node.id,
           display_name: node.display_name,
           hostname: node.hostname,
           listen_host: node.connect_host,
           listen_port: node.connect_port,
           agent_version: "0.5.0-dev"
         },
         runtime_health: %{ready: true, health_code: "", health_message: ""}
       }}
    end
  end

  defmodule CertificateStreamAdapter do
    def get_cert(der), do: der
  end

  defmodule RecordingCookieInstaller do
    def install(grant, node_name) do
      send(Application.fetch_env!(:orchard_controller, :beam_peer_grant_test_pid), {
        :peer_cookie_installed,
        grant,
        node_name
      })

      :ok
    end
  end

  setup do
    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_trust: Application.get_env(:orchard_controller, :node_trust),
      beam_peer_grants: Application.get_env(:orchard_controller, :beam_peer_grants),
      runtime_endpoint: Application.get_env(:orchard_controller, :runtime_endpoint)
    }

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-peer-grants-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)

    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      authorization_root_path: authorization_root
    )

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:control_plane, previous.control_plane)
      restore_env(:node_trust, previous.node_trust)
      restore_env(:beam_peer_grants, previous.beam_peer_grants)
      restore_env(:runtime_endpoint, previous.runtime_endpoint)
    end)

    {:ok, root: root, trust_root: trust_root, authorization_root: authorization_root}
  end

  test "SPEC.md §7.5.0 registered Node has no BEAM Peer Grant before admission" do
    node =
      %Node{}
      |> Node.changeset(%{
        hostname: "registered-no-grant.local",
        display_name: "registered-no-grant",
        advertise_addr: "10.0.0.20",
        rpc_port: 50_071,
        connect_host: "10.0.0.20",
        connect_port: 50_071,
        state: :registered,
        health: :unreachable,
        capabilities: %{},
        tool_readiness: %{}
      })
      |> Repo.insert!()

    assert BeamPeerGrants.list_for_node(node.id) == []
  end

  test "SPEC.md §7.5.0 Controller application initializes grant authority before admission", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert pid =
             start_supervised!(
               {ControllerInitializer,
                private_ipv4: "10.0.0.10",
                membership_scope: :remote_beam,
                node_trust_root: trust_root,
                authorization_root_path: authorization_root,
                now: now}
             )

    assert is_pid(pid)
    node = register_node!(trust, now)

    assert {:ok, %{node: _admitted, grants: [%Grant{}]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)
  end

  test "SPEC.md §7.5.0 grant listener gives one stable Controller certificate upgrade refusal" do
    assert {:error, :beam_controller_identity_upgrade_required} =
             ControlListener.server_options(host: "10.0.0.10", port: 50_072)
  end

  test "SPEC.md §7.5.0 admission descriptor is owner-only and contains no grant material", %{
    root: root,
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, _now} = pending_grant!(trust_root, authorization_root)
    descriptor_root = Path.join(root, "descriptor")
    descriptor_path = Path.join(descriptor_root, "peer-grant.json")

    File.mkdir!(descriptor_root)
    File.chmod!(descriptor_root, 0o700)

    assert :ok =
             BeamPeerGrants.write_admitted_descriptor(
               node.id,
               descriptor_path,
               "10.0.0.10:50072"
             )

    assert Bitwise.band(File.stat!(descriptor_path).mode, 0o777) == 0o600

    assert descriptor_path |> File.read!() |> Jason.decode!() == %{
             "grant_id" => grant.id,
             "generation" => grant.generation,
             "controller_id" => grant.controller_id,
             "control_endpoint" => "10.0.0.10:50072"
           }
  end

  test "SPEC.md §7.5.0 admission atomically creates one exact pending-delivery pair", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)
    assert BeamPeerGrants.list_for_node(node.id) == []

    assert {:ok, %{node: admitted, grants: [%Grant{} = grant]}} =
             Nodes.admit_node(
               node.id,
               %{
                 trust_evidence_ref: "registration-audit:#{Ecto.UUID.generate()}",
                 pool_id: Ecto.UUID.generate(),
                 routing_policy_id: Ecto.UUID.generate(),
                 capacity_policy_reason: "approve initial peer grant capacity"
               },
               now: now
             )

    compact_node_id = String.replace(node.id, "-", "")

    assert admitted.state == :admitted
    assert admitted.canonical_beam_name == "orchard_node_agent_#{compact_node_id}@10.0.0.20"
    assert [^grant] = BeamPeerGrants.list_for_node(node.id)
    assert grant.state == :pending_delivery
    assert grant.generation == 1
    assert grant.cluster_id == trust.cluster_id
    assert grant.controller_id == controller.id
    assert grant.controller_beam_name == controller.canonical_beam_name
    assert grant.controller_certificate_identifier == controller.certificate_identifier

    assert grant.controller_certificate_fingerprint_sha256 ==
             controller.certificate_fingerprint_sha256

    assert grant.beam_authorization_root_id == controller.beam_authorization_root_id
    assert grant.node_id == node.id
    assert grant.node_beam_name == admitted.canonical_beam_name
    assert grant.contract_version == 1
    assert grant.purpose == "runtime_endpoint"
    assert grant.issued_at == now
    assert grant.not_before_at == now
    assert grant.expires_at == DateTime.add(now, 30, :day)
    assert byte_size(grant.secret_hash) == 32
    refute Map.has_key?(Map.from_struct(grant), :encoded_secret)
  end

  test "SPEC.md §7.5.0 admission binds the grant to the local Controller when a peer row exists",
       %{
         trust_root: trust_root,
         authorization_root: authorization_root
       } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    peer = insert_peer_controller!(now)
    node = register_node!(trust, now)

    assert {:ok, %{grants: [%Grant{} = grant]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    assert grant.controller_id == controller.id
    refute grant.controller_id == peer.id
    assert grant.controller_beam_name == controller.canonical_beam_name
  end

  test "SPEC.md §7.5.0 admission fails closed when the local Controller row is not operational",
       %{
         trust_root: trust_root,
         authorization_root: authorization_root
       } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    insert_peer_controller!(now)
    node = register_node!(trust, now)

    ControllerInstance
    |> Repo.get!(controller.id)
    |> Ecto.Changeset.change(status: :retired)
    |> Repo.update!()

    assert {:error, :beam_peer_grant_controller_scope_invalid} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    assert BeamPeerGrants.list_for_node(node.id) == []
    assert Repo.get!(Node, node.id).state == :registered
  end

  defp insert_peer_controller!(now) do
    peer_id = Ecto.UUID.generate()
    compact_id = String.replace(peer_id, "-", "")

    %ControllerInstance{}
    |> ControllerInstance.changeset(%{
      id: peer_id,
      certificate_uri_san: "spiffe://orchard/controller/#{peer_id}",
      certificate_identifier: "serial:#{System.unique_integer([:positive])}",
      certificate_fingerprint_sha256: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      canonical_beam_name: "orchard_controller_#{compact_id}@10.0.0.11",
      beam_authorization_root_id: Ecto.UUID.generate(),
      authorization_root_custody_ref: "owner-only-local:#{Ecto.UUID.generate()}",
      status: :operational,
      first_enrolled_at: now
    })
    |> Repo.insert!()
  end

  test "SPEC.md §7.5.0 concurrent admission permits only one tracer Node pair", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    nodes = [register_node!(trust, now, "10.0.0.20"), register_node!(trust, now, "10.0.0.21")]
    parent = self()

    tasks =
      Enum.map(nodes, fn node ->
        Task.async(fn ->
          send(parent, {:admission_ready, self()})
          receive do: (:admit -> Nodes.admit_node(node.id, admission_attrs(), now: now))
        end)
      end)

    task_pids =
      for _index <- 1..2 do
        assert_receive {:admission_ready, task_pid}
        task_pid
      end

    Enum.each(task_pids, &send(&1, :admit))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert [winner] = for({:ok, %{node: node, grants: [grant]}} <- results, do: {node, grant})

    assert [{:error, :beam_peer_grant_tracer_capacity_reached}] =
             Enum.reject(results, &match?({:ok, _result}, &1))

    {winner_node, winner_grant} = winner

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               delivery_request(winner_grant),
               authenticated_peer!(winner_node.id),
               now: now
             )

    assert Repo.aggregate(Grant, :count, :id) == 1
    assert Repo.get!(Grant, winner_grant.id).state == :active

    assert [loser] = Enum.reject(nodes, &(&1.id == winner_node.id))
    assert Repo.get!(Node, loser.id).state == :registered
    assert BeamPeerGrants.list_for_node(loser.id) == []
  end

  test "SPEC.md §7.5.0 admission uses the global grant transaction lock order", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    assert {:ok, %{grants: [%Grant{}]}} =
             Nodes.admit_node(node.id, admission_attrs(),
               now: now,
               test_lock_observer: lock_observer(:admission)
             )

    assert lock_order(:admission) == [:grant, :node, :enrollment, :controller]
  end

  test "SPEC.md §7.5.0 admission fails closed behind a concurrent Enrollment revocation", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    :ok = Sandbox.checkin(Repo)
    on_exit(&clean_unboxed_grant_fixture/0)

    {node, enrollment} =
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

        assert {:ok, _controller} =
                 ControllerInstances.ensure_local(
                   private_ipv4: "10.0.0.10",
                   membership_scope: :remote_beam,
                   node_trust_root: trust_root,
                   authorization_root_path: authorization_root,
                   now: now
                 )

        node = register_node!(trust, now)

        enrollment =
          Repo.one!(from(candidate in Enrollment, where: candidate.node_id == ^node.id))

        {node, enrollment}
      end)

    parent = self()

    revocation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            locked =
              Enrollment
              |> where([candidate], candidate.id == ^enrollment.id)
              |> lock("FOR UPDATE")
              |> Repo.one!()

            send(parent, :enrollment_revocation_locked)

            receive do
              :finish_enrollment_revocation -> :ok
            after
              5_000 -> raise "timed out waiting to finish Enrollment revocation"
            end

            locked
            |> Enrollment.changeset(%{state: :revoked, revoked_at: now})
            |> Repo.update!()
          end)
        end)
      end)

    assert_receive :enrollment_revocation_locked, 2_000

    admission =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Nodes.admit_node(node.id, admission_attrs(),
            now: now,
            test_lock_observer: fn lock_name ->
              send(parent, {:concurrent_admission_lock, lock_name})
              :ok
            end
          )
        end)
      end)

    assert_receive {:concurrent_admission_lock, :grant}, 2_000
    assert_receive {:concurrent_admission_lock, :node}, 2_000
    send(revocation.pid, :finish_enrollment_revocation)

    assert {:ok, %Enrollment{state: :revoked}} = Task.await(revocation, 5_000)
    assert {:error, :beam_peer_grant_node_certificate_invalid} = Task.await(admission, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert BeamPeerGrants.list_for_node(node.id) == []
      assert Repo.get!(Node, node.id).state == :registered
    end)
  end

  test "SPEC.md §7.5.0 grant persistence failure rolls back the complete admission", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    injector = fn
      :after_grant_insert -> {:error, :simulated_grant_persistence_failure}
      _checkpoint -> :ok
    end

    assert {:error, :simulated_grant_persistence_failure} =
             Nodes.admit_node(
               node.id,
               admission_attrs(),
               now: now,
               test_fault_injector: injector
             )

    persisted = Repo.get!(Node, node.id)
    assert persisted.state == :registered
    assert persisted.canonical_beam_name == nil
    assert BeamPeerGrants.list_for_node(node.id) == []

    assert Repo.aggregate(
             from(decision in AdmissionDecision,
               where: decision.node_id == ^node.id and decision.decision == :admitted
             ),
             :count,
             :id
           ) == 0

    assert Repo.aggregate(
             from(audit in AuditLog,
               where: audit.action == "node_admission.admitted",
               where: fragment("?->>'node_id'", audit.payload) == ^node.id
             ),
             :count,
             :id
           ) == 0
  end

  test "SPEC.md §7.5.0 delivery rechecks expiry after lock contention", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)
    Process.put(:delivery_database_now, now)

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrants.deliver(
               delivery_request(grant),
               authenticated_peer!(node.id),
               now: now,
               test_database_now: fn -> Process.get(:delivery_database_now) end,
               test_lock_observer: fn
                 :controller ->
                   Process.put(:delivery_database_now, grant.expires_at)
                   :ok

                 _lock ->
                   :ok
               end
             )

    assert Repo.get!(Grant, grant.id).state == :pending_delivery
  end

  test "SPEC.md §7.5.0 delivery evidence uses database time after lock contention", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)
    delivered_at = DateTime.add(now, 5, :second)
    Process.put(:delivery_evidence_database_now, now)

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               delivery_request(grant),
               authenticated_peer!(node.id),
               now: now,
               test_database_now: fn -> Process.get(:delivery_evidence_database_now) end,
               test_lock_observer: fn
                 :controller ->
                   Process.put(:delivery_evidence_database_now, delivered_at)
                   :ok

                 _lock ->
                   :ok
               end
             )

    assert Repo.get!(Grant, grant.id).delivered_at == delivered_at
  end

  test "SPEC.md §7.5.0 certificate-authenticated lost delivery response retries exactly", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    assert {:ok, %{grants: [grant]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    request = %{
      grant_id: grant.id,
      generation: grant.generation,
      controller_id: grant.controller_id
    }

    peer = authenticated_peer!(node.id)

    assert {:ok, first} = BeamPeerGrants.deliver(request, peer, now: now)
    assert {:ok, retry} = BeamPeerGrants.deliver(request, peer, now: now)
    assert first.grant_id == grant.id
    assert first.generation == grant.generation
    assert first.encoded_secret == retry.encoded_secret
    assert first.secret_hash == retry.secret_hash
    assert first.encoded_secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert Repo.get!(Grant, grant.id).state == :active
  end

  test "SPEC.md §7.5.0 Controller derives one nonsecret exact Distribution launch scope", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               %{
                 grant_id: grant.id,
                 generation: grant.generation,
                 controller_id: grant.controller_id
               },
               authenticated_peer!(node.id),
               now: now
             )

    assert {:ok, material} =
             BeamPeerGrants.distribution_launch_material(grant.id, now: now)

    assert material.scope.grant_id == grant.id
    assert material.scope.controller_beam_name == grant.controller_beam_name
    assert material.scope.node_beam_name == grant.node_beam_name
    assert material.local_identity.generation_id
    assert material.local_identity.certfile
    assert material.peer_identity.uri_san =~ ":node:#{node.id}"

    assert material.peer_identity.certificate_fingerprint ==
             grant.node_certificate_fingerprint_sha256

    refute Map.has_key?(material.scope, :encoded_secret)
    refute Map.has_key?(material.scope, :secret_hash)
    refute Map.has_key?(material, :authorization_root)
  end

  test "SPEC.md §7.5.0 Distribution launch rechecks expiry after lock contention", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               delivery_request(grant),
               authenticated_peer!(node.id),
               now: now
             )

    Process.put(:launch_database_now, now)

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrants.distribution_launch_material(
               grant.id,
               now: now,
               test_database_now: fn -> Process.get(:launch_database_now) end,
               test_lock_observer: fn
                 :controller ->
                   Process.put(:launch_database_now, grant.expires_at)
                   :ok

                 _lock ->
                   :ok
               end
             )
  end

  test "SPEC.md §7.5.0 lost-response retry and launch revalidation use one lock order", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)
    request = delivery_request(grant)
    peer = authenticated_peer!(node.id)

    assert {:ok, _delivery} = BeamPeerGrants.deliver(request, peer, now: now)

    launch_observer = lock_observer(:launch)

    assert {:ok, _material} =
             BeamPeerGrants.distribution_launch_material(
               grant.id,
               now: now,
               test_lock_observer: launch_observer
             )

    delivery_observer = lock_observer(:delivery)

    assert {:ok, _retry} =
             BeamPeerGrants.deliver(
               request,
               peer,
               now: now,
               test_lock_observer: delivery_observer
             )

    assert lock_order(:launch) == [:grant, :node, :enrollment, :controller]
    assert lock_order(:delivery) == [:grant, :node, :enrollment, :controller]
  end

  test "SPEC.md §7.5.0 a non-operational Controller cannot deliver a pending grant", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)

    Orchard.ControllerInstances.ControllerInstance
    |> Repo.get!(grant.controller_id)
    |> Ecto.Changeset.change(status: :recovery_required)
    |> Repo.update!()

    request = %{
      grant_id: grant.id,
      generation: grant.generation,
      controller_id: grant.controller_id
    }

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.deliver(request, authenticated_peer!(node.id), now: now)
  end

  test "SPEC.md §7.5.0 delivery rejects missing runtime trust SPKI bindings", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)
    enrollment = Repo.one!(from(candidate in Enrollment, where: candidate.node_id == ^node.id))

    enrollment
    |> Ecto.Changeset.change(
      certificate_result: Map.put(enrollment.certificate_result, "runtime_trust_spki_sha256", nil)
    )
    |> Repo.update!()

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.deliver(
               delivery_request(grant),
               authenticated_peer!(node.id),
               now: now
             )
  end

  test "SPEC.md §7.5.0 mTLS control stream is the plaintext grant boundary", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, _now} = pending_grant!(trust_root, authorization_root)

    request = %RetrieveBeamPeerGrantRequest{
      grant_id: grant.id,
      generation: grant.generation,
      controller_id: grant.controller_id
    }

    stream = %GRPC.Server.Stream{
      adapter: CertificateStreamAdapter,
      payload: node_certificate_der!(node.id)
    }

    assert %RetrieveBeamPeerGrantResponse{} =
             response =
             ControlServer.retrieve_beam_peer_grant(request, stream)

    assert response.grant_id == grant.id
    assert response.node_id == node.id
    assert response.generation == grant.generation
    assert response.encoded_secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert response.secret_hash == grant.secret_hash
    assert Repo.get!(Grant, grant.id).state == :active
    assert %DateTime{} = Repo.get!(Grant, grant.id).delivered_at
  end

  test "SPEC.md §7.5.0 grant control listener requires mutual TLS", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_node, _grant, _now} = pending_grant!(trust_root, authorization_root)

    assert {:ok, options} =
             ControlListener.server_options(
               host: "10.0.0.10",
               port: 50_072
             )

    assert options[:endpoint] == Orchard.BeamPeerGrants.ControlEndpoint
    assert options[:port] == 50_072
    assert options[:start_server] == true
    assert options[:adapter_opts][:ip] == {10, 0, 0, 10}
    assert %GRPC.Credential{ssl: ssl} = options[:adapter_opts][:cred]
    assert ssl[:verify] == :verify_peer
    assert ssl[:fail_if_no_peer_cert] == true
    assert ssl[:versions] == [:"tlsv1.3"]

    assert {:ok, identity} = NodeTrust.runtime_client_generation_paths()

    assert {:ok, certificate} =
             identity.certfile |> File.read!() |> CertificateIdentity.from_pem()

    assert Enum.sort(certificate.extended_key_usages) == [:client_auth, :server_auth]
  end

  test "SPEC.md §7.5.0 Node retrieves and stores a grant over a real mTLS control stream", %{
    root: root,
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {node, grant, _now} = pending_grant!(trust_root, authorization_root)
    identity_root = Path.join(root, "live-node-identity")
    _identity = live_node_identity!(identity_root, node.id)
    assert {:ok, identity} = RuntimeTLS.load_registered_identity(identity_root)
    port = free_loopback_port!()
    descriptor_path = Path.join(identity_root, "peer-grant-descriptor.json")

    Application.put_env(:orchard_controller, :beam_peer_grant_test_pid, self())
    on_exit(fn -> Application.delete_env(:orchard_controller, :beam_peer_grant_test_pid) end)

    start_supervised!({ControlListener, host: "127.0.0.1", port: port, allow_test_loopback: true})

    assert {:error, _reason} =
             :ssl.connect(
               ~c"127.0.0.1",
               port,
               [
                 active: false,
                 certfile: String.to_charlist(identity.certfile),
                 keyfile: String.to_charlist(identity.keyfile),
                 server_name_indication: :disable,
                 verify: :verify_none,
                 versions: [:"tlsv1.2"]
               ],
               1_000
             )

    assert :ok =
             BeamPeerGrantDescriptor.write(descriptor_path, %{
               grant_id: grant.id,
               generation: grant.generation,
               controller_id: grant.controller_id,
               control_endpoint: "127.0.0.1:#{port}"
             })

    assert pid =
             start_supervised!(
               {BeamPeerGrantBootstrap,
                identity_root: identity_root,
                descriptor_path: descriptor_path,
                node_beam_name: grant.node_beam_name,
                cookie_installer: RecordingCookieInstaller,
                name: nil}
             )

    assert is_pid(pid)
    assert_receive {:peer_cookie_installed, installed, node_name}

    assert node_name == grant.node_beam_name
    assert installed.grant_id == grant.id
    assert installed.encoded_secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/

    assert {:ok, ^installed} =
             BeamPeerGrantStore.load(identity_root, identity, grant.node_beam_name)

    assert Repo.get!(Grant, grant.id).state == :active
  end

  test "SPEC.md §7.5.0 legacy Node identity remains explicit gRPC-compatible but not grant-capable",
       %{
         root: root,
         trust_root: trust_root,
         authorization_root: authorization_root
       } do
    {node, _grant, _now} = pending_grant!(trust_root, authorization_root)
    identity_root = Path.join(root, "legacy-node-identity")
    _identity = live_node_identity!(identity_root, node.id)
    generation_id = identity_root |> Path.join("current") |> File.read!() |> String.trim()
    generation_root = Path.join([identity_root, "generations", generation_id])
    metadata_path = Path.join(generation_root, "metadata.json")

    metadata =
      metadata_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.drop([
        "controller_certificate_identifier",
        "controller_certificate_fingerprint"
      ])

    write_private!(metadata_path, Jason.encode!(metadata))
    File.rm!(Path.join(generation_root, "controller-certificate.pem"))

    assert {:ok, legacy} = RuntimeTLS.load_registered_identity(identity_root)
    assert legacy.controller_certificate_identifier == nil
    assert legacy.controller_certificate_fingerprint == nil
    assert legacy.controller_certfile == nil

    assert {:error, :node_runtime_tls_identity_upgrade_required} =
             RuntimeTLS.load_registered_identity(identity_root,
               require_controller_certificate: true
             )
  end

  test "SPEC.md §7.5.0 production activation target requires one exact active grant", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    assert {:ok, %{node: admitted, grants: [grant]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    assert {:ok, []} = Nodes.activation_probe_runtime_endpoint_targets()

    request = %{
      grant_id: grant.id,
      generation: grant.generation,
      controller_id: grant.controller_id
    }

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(request, authenticated_peer!(node.id), now: now)

    assert {:ok, [target]} = Nodes.activation_probe_runtime_endpoint_targets()
    assert target.transport == :beam
    assert target.node_id == node.id
    assert target.address == admitted.canonical_beam_name
    assert target.metadata.source == :trusted_node_inventory
    assert target.metadata.authorization == :activation_probe
    assert target.metadata.grant_id == grant.id
    assert target.metadata.generation == grant.generation
  end

  test "SPEC.md §7.5.0 pending grant cannot authorize a production BEAM target", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    assert {:ok, %{node: admitted, grants: [grant]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    target =
      Target.beam(node.id,
        address: admitted.canonical_beam_name,
        metadata: %{
          generation: grant.generation,
          grant_id: grant.id,
          source: :trusted_node_inventory
        }
      )

    assert {:error, :beam_peer_grant_not_active} = BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 active grant rejects the wrong canonical BEAM target", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = %{target | address: "orchard_node_agent_forged@10.0.0.20"}

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 active grant rejects a mismatched generation", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = put_in(target.metadata.generation, grant.generation + 1)

    assert {:error, :beam_peer_grant_generation_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 revoked grant cannot authorize a new BEAM connection", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    grant |> Ecto.Changeset.change(state: :revoked) |> Repo.update!()

    assert {:error, :beam_peer_grant_revoked} = BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 a non-operational Controller is removed from trusted targets", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)

    Orchard.ControllerInstances.ControllerInstance
    |> Repo.get!(grant.controller_id)
    |> Ecto.Changeset.change(status: :retired)
    |> Repo.update!()

    assert {:ok, []} = Nodes.activation_probe_runtime_endpoint_targets()

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 expired grant cannot authorize a new BEAM connection", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    grant |> Ecto.Changeset.change(state: :expired) |> Repo.update!()

    assert {:error, :beam_peer_grant_expired} = BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 superseded grant cannot authorize a new BEAM connection", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    grant |> Ecto.Changeset.change(state: :superseded) |> Repo.update!()

    assert {:error, :beam_peer_grant_not_active} = BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 wrong-cluster grant scope cannot authorize a new BEAM connection", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    grant |> Ecto.Changeset.change(cluster_id: Ecto.UUID.generate()) |> Repo.update!()

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 wrong-purpose grant scope cannot authorize a new BEAM connection", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    grant |> Ecto.Changeset.change(purpose: "control_plane") |> Repo.update!()

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 lost Controller authorization root blocks new BEAM connections", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    File.rename!(authorization_root, authorization_root <> ".lost")

    assert {:error, :beam_authorization_root_unavailable} =
             BeamPeerGrants.authorize_target(target)
  end

  test "SPEC.md §7.5.0 exact active target authorizes the derived pair secret", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)

    assert {:ok, authorization} = BeamPeerGrants.authorize_target(target)
    assert authorization.grant.id == grant.id
    assert authorization.node_name == target.address
    assert authorization.secret_hash == grant.secret_hash
    assert authorization.encoded_secret =~ ~r/\A[A-Za-z0-9_-]{43}\z/
    assert authorization.authenticated_peer.node_id == target.node_id
    assert authorization.authenticated_peer.scheme == :mtls
  end

  test "SPEC.md §7.5.0 authorization rechecks expiry before returning the secret", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)

    assert {:error, :beam_peer_grant_expired} =
             BeamPeerGrants.authorize_target(target,
               test_database_now: fn -> grant.expires_at end
             )
  end

  test "SPEC.md §7.5.0 active target rejects mismatched certificate scope", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = put_in(target.metadata.certificate_fingerprint, "sha256-forged")

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 active target rejects a mismatched Node identity", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = %{target | node_id: Ecto.UUID.generate()}

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 active target rejects a mismatched enrollment identity", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = put_in(target.metadata.enrollment_id, Ecto.UUID.generate())

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 active target rejects a mismatched Controller identity", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = put_in(target.metadata.controller_id, Ecto.UUID.generate())

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 active target rejects a mismatched authorization root", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    wrong_target = put_in(target.metadata.beam_authorization_root_id, Ecto.UUID.generate())

    assert {:error, :beam_peer_credential_mismatch} =
             BeamPeerGrants.authorize_target(wrong_target)
  end

  test "SPEC.md §7.5.0 exact active grant reaches the BEAM distribution boundary", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    controller_name = target.metadata.controller_beam_name
    [_service, listen_host] = String.split(controller_name, "@", parts: 2)

    Application.put_env(:orchard_controller, :runtime_endpoint,
      beam: [
        enabled: true,
        node_name: controller_name,
        cookie_file: nil,
        admitted_services: [],
        allowed_cidrs: [],
        listen_host: listen_host
      ]
    )

    assert {:error, :beam_distribution_unavailable} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 connect rechecks expiry after establishing Distribution", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    controller_name = target.metadata.controller_beam_name
    [_service, listen_host] = String.split(controller_name, "@", parts: 2)

    Application.put_env(:orchard_controller, :runtime_endpoint,
      beam: [
        enabled: true,
        node_name: controller_name,
        cookie_file: nil,
        admitted_services: [],
        allowed_cidrs: [],
        listen_host: listen_host
      ]
    )

    Process.put(:connect_database_now, grant.not_before_at)
    caller = self()

    assert {:error, :beam_peer_grant_expired} =
             BeamClient.connect(target,
               current_node: String.to_atom(controller_name),
               test_database_now: fn -> Process.get(:connect_database_now) end,
               connector: fn node ->
                 send(caller, {:peer_connected, node})
                 Process.put(:connect_database_now, grant.expires_at)
                 :ok
               end,
               cookie_setter: fn node, cookie ->
                 send(caller, {:peer_cookie_set, node, cookie})
                 true
               end,
               disconnect: fn node ->
                 send(caller, {:peer_disconnected, node})
                 true
               end
             )

    peer = String.to_atom(target.address)
    assert_received {:peer_connected, ^peer}
    assert_received {:peer_cookie_set, ^peer, :orchard_expired_peer_grant}
    assert_received {:peer_disconnected, ^peer}
  end

  test "SPEC.md §7.5.0 connect scrubs the peer when final authorization raises", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    controller_name = target.metadata.controller_beam_name
    [_service, listen_host] = String.split(controller_name, "@", parts: 2)

    Application.put_env(:orchard_controller, :runtime_endpoint,
      beam: [
        enabled: true,
        node_name: controller_name,
        cookie_file: nil,
        admitted_services: [],
        allowed_cidrs: [],
        listen_host: listen_host
      ]
    )

    Process.put(:final_authorization_failure, false)
    caller = self()

    assert {:error, :beam_peer_grant_authorization_unavailable} =
             BeamClient.connect(target,
               current_node: String.to_atom(controller_name),
               test_database_now: fn ->
                 if Process.get(:final_authorization_failure) do
                   raise "authorization store failed"
                 else
                   grant.not_before_at
                 end
               end,
               connector: fn node ->
                 send(caller, {:peer_connected, node})
                 Process.put(:final_authorization_failure, true)
                 :ok
               end,
               cookie_setter: fn node, cookie ->
                 send(caller, {:peer_cookie_set, node, cookie})
                 true
               end,
               disconnect: fn node ->
                 send(caller, {:peer_disconnected, node})
                 true
               end
             )

    peer = String.to_atom(target.address)
    assert_received {:peer_connected, ^peer}
    assert_received {:peer_cookie_set, ^peer, :orchard_expired_peer_grant}
    assert_received {:peer_disconnected, ^peer}
  end

  test "SPEC.md §7.5.0 connect scrubs the peer when final authorization exits", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    controller_name = target.metadata.controller_beam_name
    [_service, listen_host] = String.split(controller_name, "@", parts: 2)

    Application.put_env(:orchard_controller, :runtime_endpoint,
      beam: [
        enabled: true,
        node_name: controller_name,
        cookie_file: nil,
        admitted_services: [],
        allowed_cidrs: [],
        listen_host: listen_host
      ]
    )

    Process.put(:final_authorization_exit, false)
    caller = self()

    assert {:error, :beam_peer_grant_authorization_unavailable} =
             BeamClient.connect(target,
               current_node: String.to_atom(controller_name),
               test_database_now: fn ->
                 if Process.get(:final_authorization_exit) do
                   exit(:authorization_store_failed)
                 else
                   grant.not_before_at
                 end
               end,
               connector: fn node ->
                 send(caller, {:peer_connected, node})
                 Process.put(:final_authorization_exit, true)
                 :ok
               end,
               cookie_setter: fn node, cookie ->
                 send(caller, {:peer_cookie_set, node, cookie})
                 true
               end,
               disconnect: fn node ->
                 send(caller, {:peer_disconnected, node})
                 true
               end
             )

    peer = String.to_atom(target.address)
    assert_received {:peer_connected, ^peer}
    assert_received {:peer_cookie_set, ^peer, :orchard_expired_peer_grant}
    assert_received {:peer_disconnected, ^peer}
  end

  test "SPEC.md §7.5.0 connect scrubs the installed cookie when Distribution never connects",
       %{
         trust_root: trust_root,
         authorization_root: authorization_root
       } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    controller_name = target.metadata.controller_beam_name
    [_service, listen_host] = String.split(controller_name, "@", parts: 2)

    Application.put_env(:orchard_controller, :runtime_endpoint,
      beam: [
        enabled: true,
        node_name: controller_name,
        cookie_file: nil,
        admitted_services: [],
        allowed_cidrs: [],
        listen_host: listen_host
      ]
    )

    caller = self()

    assert {:error, :beam_node_unavailable} =
             BeamClient.connect(target,
               current_node: String.to_atom(controller_name),
               connector: fn _node -> {:error, :beam_node_unavailable} end,
               cookie_setter: fn node, cookie ->
                 send(caller, {:peer_cookie_set, node, cookie})
                 true
               end,
               disconnect: fn node ->
                 send(caller, {:peer_disconnected, node})
                 true
               end
             )

    peer = String.to_atom(target.address)
    assert_received {:peer_cookie_set, ^peer, :orchard_expired_peer_grant}
    assert_received {:peer_disconnected, ^peer}
  end

  test "SPEC.md §7.5.0 activation probe accepts the production BEAM client", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, _target} = active_grant_target!(trust_root, authorization_root)

    assert {:ok, []} = ActivationProbe.run_once(client: BeamClient, timeout: 100)
  end

  test "SPEC.md §4.1 BEAM client status activates only through authenticated observation", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)

    connection = %BeamClient{
      authenticated_peer: authenticated_peer!(target.node_id),
      node: node(),
      server_module: AuthenticatedStatusServer,
      target: target
    }

    assert {:ok, %{runtime_health: %{ready: true}}} = BeamClient.status(connection, [])
    assert Repo.get!(Node, target.node_id).state == :active
  end

  test "SPEC.md §4.1 grant-backed authenticated BEAM observation activates admitted Node", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)

    assert {:ok, %{grants: [grant]}} =
             Nodes.admit_node(node.id, admission_attrs(), now: now)

    peer = authenticated_peer!(node.id)

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               %{
                 grant_id: grant.id,
                 generation: grant.generation,
                 controller_id: grant.controller_id
               },
               peer,
               now: now
             )

    assert {:ok, [target]} = Nodes.activation_probe_runtime_endpoint_targets()
    observed_at = DateTime.utc_now()

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""},
      active_request_count: 2,
      max_concurrency: 4
    }

    assert {:ok, active} =
             Nodes.observe_authenticated_status(target, status, observed_at, peer)

    assert active.state == :active
    assert active.last_heartbeat_at == DateTime.truncate(observed_at, :microsecond)

    evidence = DispatchCapacity.get_capacity_evidence(node.id)
    assert evidence.runtime_concurrency_limit == 4
    assert evidence.active_request_count == 2
    assert evidence.validity == :valid
    assert evidence.observed_at == DateTime.truncate(observed_at, :microsecond)
  end

  test "SPEC.md §4.5 degraded authenticated observation is recorded for active nodes", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    # Promote admitted -> active first with healthy observation
    node = Repo.get!(Node, target.node_id)
    peer = authenticated_peer!(node.id)

    healthy_status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""},
      active_request_count: 1,
      max_concurrency: 4
    }

    first_at = DateTime.utc_now()

    assert {:ok, active} =
             Nodes.observe_authenticated_status(target, healthy_status, first_at, peer)

    assert active.state == :active
    assert active.health == :healthy

    degraded_status = %{
      node_metadata: healthy_status.node_metadata,
      runtime_health: %{ready: true, health_code: "SLOW", health_message: "warm path degraded"},
      active_request_count: 2,
      max_concurrency: 4
    }

    second_at = DateTime.add(first_at, 1, :second)

    assert {:ok, degraded} =
             Nodes.observe_authenticated_status(target, degraded_status, second_at, peer)

    assert degraded.state == :active
    assert degraded.health == :degraded
    assert degraded.last_heartbeat_at == DateTime.truncate(second_at, :microsecond)

    evidence = DispatchCapacity.get_capacity_evidence(node.id)
    assert evidence.active_request_count == 2
    assert evidence.observed_at == DateTime.truncate(second_at, :microsecond)
  end

  test "SPEC.md §4.5 non-healthy admitted observation does not activate", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    node = Repo.get!(Node, target.node_id)
    peer = authenticated_peer!(node.id)

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "SLOW", health_message: "not ready to promote"},
      active_request_count: 0,
      max_concurrency: 1
    }

    assert :noop = Nodes.observe_authenticated_status(target, status, DateTime.utc_now(), peer)
    assert Repo.get!(Node, node.id).state == :admitted
  end

  test "SPEC.md §7.5.0 authenticated activation uses the grant transaction lock order", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    node = Repo.get!(Node, target.node_id)
    peer = authenticated_peer!(node.id)
    observed_at = DateTime.utc_now()

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""}
    }

    assert {:ok, _active} =
             Nodes.observe_authenticated_status(
               target,
               status,
               observed_at,
               peer,
               test_lock_observer: lock_observer(:activation)
             )

    assert lock_order(:activation) == [:grant, :node, :enrollment, :controller]
  end

  test "SPEC.md §7.5.0 authenticated activation revalidates the authorization root", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {_grant, target} = active_grant_target!(trust_root, authorization_root)
    node = Repo.get!(Node, target.node_id)
    peer = authenticated_peer!(node.id)

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""}
    }

    File.rm_rf!(authorization_root)

    assert :noop =
             Nodes.observe_authenticated_status(
               target,
               status,
               DateTime.utc_now(),
               peer
             )

    assert Repo.get!(Node, node.id).state == :admitted
  end

  test "SPEC.md §7.5.0 authenticated activation rechecks expiry before mutation", %{
    trust_root: trust_root,
    authorization_root: authorization_root
  } do
    {grant, target} = active_grant_target!(trust_root, authorization_root)
    node = Repo.get!(Node, target.node_id)
    peer = authenticated_peer!(node.id)

    status = %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        listen_host: node.connect_host,
        listen_port: node.connect_port,
        agent_version: "0.5.0-dev"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""}
    }

    Process.put(:activation_database_now, grant.not_before_at)

    assert :noop =
             Nodes.observe_authenticated_status(
               target,
               status,
               DateTime.utc_now(),
               peer,
               test_database_now: fn -> Process.get(:activation_database_now) end,
               test_lock_observer: fn
                 :controller ->
                   Process.put(:activation_database_now, grant.expires_at)
                   :ok

                 _lock ->
                   :ok
               end
             )

    assert Repo.get!(Node, node.id).state == :admitted
  end

  defp register_node!(trust, now, host \\ "10.0.0.20") do
    assert {:ok, created} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 expires_at: DateTime.add(now, 1, :hour),
                 node: %{
                   display_name: "grant-node-#{System.unique_integer([:positive, :monotonic])}"
                 }
               },
               now: now
             )

    assert {:ok, _enrollment} = NodeEnrollments.mark_issued(created.enrollment.id, now: now)
    assert {:ok, csr} = PKI.generate_csr(trust.cluster_id, created.enrollment.node_id)
    Process.put({:node_private_key, created.enrollment.node_id}, csr.private_key_pem)

    assert {:ok, _response} =
             NodeEnrollments.redeem(
               created.enrollment.id,
               %{
                 cluster_id: trust.cluster_id,
                 controller_id: trust.controller_id,
                 csr_pem: csr.csr_pem,
                 node_id: created.enrollment.node_id,
                 runtime_endpoint: %{
                   host: host,
                   hostname: "grant-node.orchard.test",
                   port: 50_071
                 },
                 token: created.bootstrap_token
               },
               now: now
             )

    Repo.get!(Node, created.enrollment.node_id)
  end

  defp clean_unboxed_grant_fixture do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("""
      TRUNCATE TABLE
        audit_logs,
        beam_peer_grants,
        node_admission_decisions,
        node_admission_candidates,
        node_enrollments,
        nodes,
        controller_instances,
        node_trust_authorities,
        cluster_identities
      CASCADE
      """)
    end)
  end

  defp admission_attrs do
    %{
      trust_evidence_ref: "registration-audit:#{Ecto.UUID.generate()}",
      pool_id: Ecto.UUID.generate(),
      routing_policy_id: Ecto.UUID.generate(),
      capacity_policy_reason: "approved for test capacity"
    }
  end

  defp active_grant_target!(trust_root, authorization_root) do
    {node, grant, now} = pending_grant!(trust_root, authorization_root)

    assert {:ok, _delivery} =
             BeamPeerGrants.deliver(
               %{
                 grant_id: grant.id,
                 generation: grant.generation,
                 controller_id: grant.controller_id
               },
               authenticated_peer!(node.id),
               now: now
             )

    assert {:ok, [target]} = Nodes.activation_probe_runtime_endpoint_targets()
    {grant, target}
  end

  defp pending_grant!(trust_root, authorization_root) do
    now = ~U[2026-07-13 08:00:00.000000Z]
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_node!(trust, now)
    assert {:ok, %{grants: [grant]}} = Nodes.admit_node(node.id, admission_attrs(), now: now)
    {node, grant, now}
  end

  defp authenticated_peer!(node_id) do
    enrollment = Repo.one!(from(enrollment in Enrollment, where: enrollment.node_id == ^node_id))
    result = enrollment.certificate_result
    certificate_pem = result["node_certificate_pem"]
    assert {:ok, certificate} = CertificateIdentity.from_pem(certificate_pem)

    %AuthenticatedPeer{
      node_id: node_id,
      node_uri_san: result["node_uri_san"],
      enrollment_id: enrollment.id,
      certificate_identifier: enrollment.certificate_identifier,
      certificate_serial: certificate.serial,
      certificate_fingerprint: certificate.fingerprint,
      runtime_trust_spki_sha256: result["runtime_trust_spki_sha256"]
    }
  end

  defp delivery_request(grant) do
    %{
      grant_id: grant.id,
      generation: grant.generation,
      controller_id: grant.controller_id
    }
  end

  defp lock_observer(operation) do
    test_pid = self()

    fn lock_name ->
      send(test_pid, {:grant_lock, operation, lock_name})
      :ok
    end
  end

  defp lock_order(operation) do
    for _index <- 1..4 do
      assert_receive {:grant_lock, ^operation, lock_name}
      lock_name
    end
  end

  defp node_certificate_der!(node_id) do
    enrollment = Repo.one!(from(enrollment in Enrollment, where: enrollment.node_id == ^node_id))

    [{:Certificate, der, :not_encrypted}] =
      :public_key.pem_decode(enrollment.certificate_result["node_certificate_pem"])

    der
  end

  defp live_node_identity!(root, node_id) do
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    enrollment = Repo.one!(from(enrollment in Enrollment, where: enrollment.node_id == ^node_id))
    result = enrollment.certificate_result
    assert {:ok, trust} = NodeTrust.public_material()
    assert {:ok, certificate} = CertificateIdentity.from_pem(result["node_certificate_pem"])

    generation_id = Ecto.UUID.generate()
    generations_root = Path.join(root, "generations")
    generation_root = Path.join(generations_root, generation_id)

    File.mkdir!(generations_root)
    File.chmod!(generations_root, 0o700)
    File.mkdir!(generation_root)
    File.chmod!(generation_root, 0o700)

    paths = %{
      cacertfile: Path.join(generation_root, "runtime-ca-certificate.pem"),
      certfile: Path.join(generation_root, "node-certificate.pem"),
      controller_certfile: Path.join(generation_root, "controller-certificate.pem"),
      keyfile: Path.join(generation_root, "node-private-key.pem")
    }

    write_private!(paths.cacertfile, result["runtime_ca_certificate_pem"])
    write_private!(paths.certfile, result["node_certificate_pem"])
    write_private!(paths.controller_certfile, result["controller_certificate_pem"])

    write_private!(
      paths.keyfile,
      Process.get({:node_private_key, node_id}) || raise("missing key")
    )

    metadata = %{
      "state" => "registered",
      "generation_id" => generation_id,
      "enrollment_id" => enrollment.id,
      "cluster_id" => enrollment.cluster_id,
      "node_id" => node_id,
      "controller_id" => enrollment.expected_controller_id,
      "controller_uri_san" => trust.controller_uri_san,
      "controller_certificate_identifier" => result["controller_certificate_identifier"],
      "controller_certificate_fingerprint" => result["controller_certificate_fingerprint"],
      "node_uri_san" => result["node_uri_san"],
      "certificate_identifier" => result["certificate_identifier"],
      "runtime_trust_spki_sha256" => result["runtime_trust_spki_sha256"]
    }

    write_private!(Path.join(generation_root, "metadata.json"), Jason.encode!(metadata))
    write_private!(Path.join(root, "current"), generation_id <> "\n")

    Map.merge(paths, %{
      certificate_fingerprint: certificate.fingerprint,
      certificate_identifier: result["certificate_identifier"],
      cluster_id: enrollment.cluster_id,
      controller_certificate_fingerprint: result["controller_certificate_fingerprint"],
      controller_certificate_identifier: result["controller_certificate_identifier"],
      controller_id: enrollment.expected_controller_id,
      controller_uri_san: trust.controller_uri_san,
      node_id: node_id
    })
  end

  defp write_private!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  defp free_loopback_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
