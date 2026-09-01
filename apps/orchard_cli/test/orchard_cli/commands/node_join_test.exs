defmodule OrchardCLI.Commands.NodeJoinTest.NoNetworkClient do
  @moduledoc false

  @spec redeem(map(), map()) :: {:error, :credential_transmission_attempted}
  def redeem(_bundle, _identity) do
    send(
      Application.fetch_env!(:orchard_cli, :node_join_test_pid),
      :credential_transmission_attempted
    )

    {:error, :credential_transmission_attempted}
  end
end

defmodule OrchardCLI.Commands.NodeJoinTest.CorruptingClient do
  @moduledoc false

  alias Orchard.NodeEnrollment.PKI
  alias OrchardCLI.PinnedHTTPS

  @spec redeem(map(), map()) :: {:ok, map()} | {:error, atom()}
  def redeem(bundle, identity) do
    case PinnedHTTPS.redeem(bundle, identity) do
      {:ok, response} ->
        {:ok, replacement} = PKI.generate_csr(bundle.cluster_id, bundle.node_id)
        root = Application.fetch_env!(:orchard_cli, :node_identity_root)

        path =
          Path.join([
            root,
            "generations",
            identity.generation_id,
            "node-private-key.pem"
          ])

        File.write!(path, replacement.private_key_pem)
        {:ok, response}

      error ->
        error
    end
  end
end

defmodule OrchardCLI.Commands.NodeJoinTest.ResponseLossClient do
  @moduledoc false

  alias OrchardCLI.PinnedHTTPS

  @spec redeem(map(), map()) :: {:error, atom()}
  def redeem(bundle, identity) do
    case PinnedHTTPS.redeem(bundle, identity) do
      {:ok, response} ->
        send(
          Application.fetch_env!(:orchard_cli, :node_join_test_pid),
          {:simulated_response_loss, response}
        )

        {:error, :node_enrollment_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

defmodule OrchardCLI.Commands.NodeJoinTest.Task28Endpoint do
  use GRPC.Endpoint

  run(Orchard.Node.RuntimeServer)
end

defmodule OrchardCLI.Commands.NodeJoinTest.StalledRuntimeServer do
  @moduledoc false

  use GRPC.Server, service: Orchard.Cluster.V1.NodeRuntimeService.Service

  alias Orchard.Cluster.V1.StatusRequest

  @spec get_status(StatusRequest.t(), Orchard.GRPCTypes.server_stream()) :: no_return()
  def get_status(%StatusRequest{}, _stream) do
    raise GRPC.RPCError, status: :unavailable, message: "runtime status unavailable"
  end
end

defmodule OrchardCLI.Commands.NodeJoinTest.StalledRuntimeEndpoint do
  use GRPC.Endpoint

  run(OrchardCLI.Commands.NodeJoinTest.StalledRuntimeServer)
end

defmodule OrchardCLI.Commands.NodeJoinTest do
  use ExUnit.Case, async: false

  import Bitwise
  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: TransportClient
  alias Orchard.DispatchCapacity
  alias Orchard.Inference
  alias Orchard.Node.ModelManager
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes, as: NodeInventory
  alias Orchard.Nodes.Node, as: InventoryNode
  alias Orchard.NodeTrust
  alias Orchard.NodeTrust.PKI, as: NodeTrustPKI
  alias Orchard.NodeTrust.Store, as: NodeTrustStore
  alias Orchard.Repo

  alias Orchard.RuntimeEndpoint.{
    ActivationProbe,
    AuthenticatedPeer,
    GrpcCompatibilityClient,
    Target
  }

  alias Orchard.TestTLS
  alias Orchard.TransportTLS.PeerVerifier
  alias OrchardCLI.Commands.Node
  alias OrchardCLI.Commands.Nodes
  alias OrchardCLI.EndpointMetadata
  alias OrchardCLI.NodeEnrollmentBundle
  alias OrchardCLI.NodeIdentity.Store
  alias OrchardCLI.PinnedHTTPS

  setup_all do
    case Process.whereis(ModelManager) do
      nil -> start_supervised!(ModelManager)
      _pid -> :ok
    end

    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-join-#{System.unique_integer([:positive])}"
      )

    trust_root = Path.join(root, "controller-node-trust")
    identity_root = Path.join(root, "node-identity")
    support_root = Path.join(root, "controller-support")
    bundle_path = Path.join(root, "node-enrollment.json")

    previous = %{
      control_plane: Application.get_env(:orchard_controller, :control_plane),
      node_enrollment_client: Application.get_env(:orchard_cli, :node_enrollment_client),
      node_identity_root: Application.get_env(:orchard_cli, :node_identity_root),
      node_join_test_pid: Application.get_env(:orchard_cli, :node_join_test_pid),
      node_runtime_endpoint: Application.get_env(:orchard_cli, :node_runtime_endpoint),
      node_trust: Application.get_env(:orchard_controller, :node_trust),
      node_runtime: Application.get_env(:orchard_node_agent, :runtime),
      support_root: System.get_env("ORCHARD_SUPPORT_ROOT")
    }

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    System.put_env("ORCHARD_SUPPORT_ROOT", support_root)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)
    Application.put_env(:orchard_cli, :node_identity_root, identity_root)
    Application.put_env(:orchard_cli, :node_join_test_pid, self())

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env("ORCHARD_SUPPORT_ROOT", previous.support_root)
      restore_app_env(:orchard_controller, :control_plane, previous.control_plane)
      restore_app_env(:orchard_controller, :node_trust, previous.node_trust)
      restore_app_env(:orchard_cli, :node_enrollment_client, previous.node_enrollment_client)
      restore_app_env(:orchard_cli, :node_identity_root, previous.node_identity_root)
      restore_app_env(:orchard_cli, :node_join_test_pid, previous.node_join_test_pid)

      restore_app_env(
        :orchard_cli,
        :node_runtime_endpoint,
        previous.node_runtime_endpoint
      )

      restore_app_env(:orchard_node_agent, :runtime, previous.node_runtime)
    end)

    assert {:ok, trust} =
             NodeTrust.initialize(root: trust_root, actor_id: "local-test-operator")

    tls = TestTLS.write_server_identity!(Path.join([root, "https", "public"]))
    port = start_https_controller!(tls)

    assert {:ok, %Req.Response{status: 200}} =
             Req.get("https://127.0.0.1:#{port}/health/live",
               connect_options: [transport_opts: [cacertfile: tls.ca_path]],
               retry: false
             )

    assert :ok =
             EndpointMetadata.write(%{
               transport_mode: "direct_https",
               public_host: "127.0.0.1",
               api_https_port: port,
               plain_http_port: nil,
               api_bind_ip: "127.0.0.1",
               ca_certfile: tls.ca_path,
               generated_by: "node-join-test"
             })

    assert {:ok, _message} =
             Nodes.run(["enrollment", "create", "--output", bundle_path])

    bundle = bundle_path |> File.read!() |> Jason.decode!()

    {:ok,
     bundle: bundle,
     bundle_path: bundle_path,
     https_trust_spki_sha256: tls.ca_spki_fingerprint,
     identity_root: identity_root,
     root: root,
     trust_root: trust_root,
     trust: trust}
  end

  test "OpenSpec task 2.4 joins through pinned HTTPS and persists one registered Node identity",
       context do
    %{bundle: bundle, bundle_path: bundle_path, identity_root: identity_root, trust: trust} =
      context

    bootstrap_token = bundle["token"]

    assert bundle["controller"]["https_trust_spki_sha256"] ==
             context.https_trust_spki_sha256

    assert {:ok, message} =
             Node.run(["join", "--enrollment-bundle", bundle_path])

    assert message =~ "Node joined and registered"
    assert message =~ "Node Admission remains required before active or schedulable"
    assert message =~ bundle["node_id"]
    refute message =~ bootstrap_token
    refute message =~ "PRIVATE KEY"

    assert {:ok, enrollment} = NodeEnrollments.fetch(bundle["enrollment_id"])
    assert enrollment.state == :consumed
    assert %DateTime{} = enrollment.consumed_at
    assert enrollment.csr_fingerprint != nil
    assert enrollment.certificate_issuance_outcome == :issued
    assert enrollment.certificate_identifier != nil
    assert enrollment.certificate_result["node_uri_san"] == node_uri(bundle)
    assert enrollment.node.state == :registered
    refute inspect(enrollment) =~ bootstrap_token

    generation_root = current_generation_root(identity_root)

    assert private_mode(identity_root) == 0o700
    assert private_mode(Path.join(identity_root, "generations")) == 0o700
    assert private_mode(generation_root) == 0o700
    assert private_mode(Path.join(identity_root, "current")) == 0o600

    identity_files = [
      "node-private-key.pem",
      "node-csr.pem",
      "node-certificate.pem",
      "runtime-ca-certificate.pem",
      "metadata.json"
    ]

    for filename <- identity_files do
      assert private_mode(Path.join(generation_root, filename)) == 0o600
    end

    private_key = File.read!(Path.join(generation_root, "node-private-key.pem"))
    certificate = File.read!(Path.join(generation_root, "node-certificate.pem"))
    runtime_ca = File.read!(Path.join(generation_root, "runtime-ca-certificate.pem"))
    metadata = generation_root |> Path.join("metadata.json") |> File.read!() |> Jason.decode!()

    assert private_key =~ "BEGIN EC PRIVATE KEY"
    assert certificate =~ "BEGIN CERTIFICATE"
    assert runtime_ca == trust.ca_certificate_pem
    assert metadata["state"] == "registered"
    assert metadata["node_id"] == bundle["node_id"]
    assert metadata["cluster_id"] == bundle["cluster_id"]
    assert metadata["controller_id"] == bundle["controller"]["id"]
    assert metadata["controller_uri_san"] == bundle["controller"]["uri_san"]
    assert metadata["node_uri_san"] == node_uri(bundle)

    Enum.each(identity_files, fn filename ->
      refute File.read!(Path.join(generation_root, filename)) =~ bootstrap_token
    end)

    [{:Certificate, certificate_der, :not_encrypted}] = :public_key.pem_decode(certificate)
    assert :binary.match(certificate_der, node_uri(bundle)) != :nomatch
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 rejects a wrong HTTPS trust pin through a real TLS handshake",
       context do
    wrong_tls =
      TestTLS.write_server_identity!(Path.join([context.root, "https", "wrong-public-ca"]))

    wrong_controller =
      context.bundle["controller"]
      |> Map.put("https_trust_anchor_pem", File.read!(wrong_tls.ca_path))
      |> Map.put("https_trust_spki_sha256", wrong_tls.ca_spki_fingerprint)

    File.write!(
      context.bundle_path,
      Jason.encode!(Map.put(context.bundle, "controller", wrong_controller))
    )

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "Controller TLS identity or trust pin validation failed"
    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
    assert enrollment.node.state == :provisioned
    assert enrollment.certificate_result == %{}
    assert {:ok, %{state: "prepared"}} = Store.load_current(context.identity_root)
  end

  test "OpenSpec task 2.6 registration stays pending until explicit audited admission",
       context do
    node_id = context.bundle["node_id"]
    enrollment_id = context.bundle["enrollment_id"]
    reason = "approved after enrollment review"
    actor_id = "task-2.6-operator"
    pool_id = Ecto.UUID.generate()
    routing_policy_id = Ecto.UUID.generate()

    Application.put_env(
      :orchard_cli,
      :node_runtime_endpoint,
      host: "10.0.0.62",
      port: 50_071,
      hostname: "enrolled-worker.orchard.test"
    )

    assert {:ok, join_output} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert join_output =~ "Node Admission remains required"
    assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)
    assert enrollment.node.state == :registered
    assert NodeInventory.schedulable_nodes() == []

    assert {:ok, pending_output} = Nodes.run(["pending", "--json"])
    pending_review = Jason.decode!(pending_output)

    assert [pending] = pending_review["data"]
    assert pending["node_id"] == node_id
    assert pending["source"] == "registered_node"
    assert pending["admission_category"] == "pending_registered"
    assert pending["status"]["scheduling"]["eligible"] == false
    assert "node_not_admitted" in pending["status"]["scheduling"]["reason_codes"]

    admit_args = [
      "admit",
      node_id,
      "--dry-run",
      "--json",
      "--trust-evidence-ref",
      "node-enrollment:#{enrollment_id}",
      "--pool-id",
      pool_id,
      "--routing-policy-id",
      routing_policy_id,
      "--capacity-policy-reason",
      reason
    ]

    assert {:ok, preview_output} = Nodes.run(admit_args)
    preview = Jason.decode!(preview_output)

    assert preview["action"] == "node_admission.admit"
    assert preview["current"]["lifecycle"]["state"] == "registered"
    assert preview["expected_transition"] == %{"from" => "registered", "to" => "admitted"}
    assert preview["blockers"] == []
    assert Repo.get!(InventoryNode, node_id).state == :registered
    assert NodeInventory.schedulable_nodes() == []

    attrs = %{
      "trust_evidence_ref" => "node-enrollment:#{enrollment_id}",
      "pool_id" => pool_id,
      "routing_policy_id" => routing_policy_id,
      "reason" => reason,
      "capacity_policy_reason" => reason
    }

    assert {:ok, result} =
             NodeInventory.admit_node(
               node_id,
               attrs,
               actor_type: "operator",
               actor_id: actor_id
             )

    assert result.node.id == node_id
    assert result.node.state == :admitted
    assert result.decision.decision == :admitted
    assert result.decision.actor_type == "operator"
    assert result.decision.actor_id == actor_id
    assert result.decision.metadata["reason"] == reason
    assert result.audit_log.scope == "cluster"
    assert result.audit_log.action == "node_admission.admitted"
    assert result.audit_log.actor_type == "operator"
    assert result.audit_log.actor_id == actor_id
    assert result.audit_log.payload["node_id"] == node_id
    assert result.audit_log.payload["reason"] == reason
    refute inspect(result.audit_log.payload) =~ context.bundle["token"]

    assert Repo.get!(InventoryNode, node_id).state == :admitted
    assert NodeInventory.schedulable_nodes() == []

    assert {:ok, after_output} = Nodes.run(["pending", "--json"])
    assert Jason.decode!(after_output)["data"] == []
  end

  test "OpenSpec task 2.7 activates only from a fresh identity-matched authenticated inventory target",
       context do
    node_id = context.bundle["node_id"]
    enrollment_id = context.bundle["enrollment_id"]
    now = DateTime.utc_now()

    Application.put_env(
      :orchard_cli,
      :node_runtime_endpoint,
      host: "authenticated-worker.orchard.test",
      port: 50_071,
      hostname: "authenticated-worker.orchard.test"
    )

    assert {:ok, _join_output} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert Repo.get!(InventoryNode, node_id).state == :registered
    assert NodeInventory.activation_probe_runtime_endpoint_targets() == {:ok, []}
    assert NodeInventory.active_runtime_endpoint_targets() == {:ok, []}
    assert NodeInventory.schedulable_nodes() == []

    assert {:ok, admitted} =
             NodeInventory.admit_node(node_id, %{
               "trust_evidence_ref" => "node-enrollment:#{enrollment_id}",
               "pool_id" => Ecto.UUID.generate(),
               "routing_policy_id" => Ecto.UUID.generate(),
               "capacity_policy_reason" => "approve authenticated activation capacity"
             })

    assert admitted.node.state == :admitted
    assert NodeInventory.schedulable_nodes() == []

    assert [
             %Target{
               transport: :grpc_compat,
               node_id: ^node_id,
               address: [host: "authenticated-worker.orchard.test", port: 50_071]
             } = target
           ] = Inference.activation_probe_runtime_endpoint_targets()

    assert target.metadata.authorization == :activation_probe
    assert Inference.runtime_endpoint_targets() == []

    status = authenticated_status(node_id)
    wrong_node_id = Ecto.UUID.generate()
    assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)

    peer_identity = %AuthenticatedPeer{
      node_id: node_id,
      node_uri_san: target.metadata.node_uri_san,
      enrollment_id: enrollment.id,
      certificate_identifier: enrollment.certificate_identifier,
      certificate_serial: target.metadata.certificate_serial,
      certificate_fingerprint: target.metadata.certificate_fingerprint,
      runtime_trust_spki_sha256: target.metadata.runtime_trust_spki_sha256
    }

    assert {:ok, still_admitted} =
             NodeInventory.observe_status(target, status, DateTime.add(now, -1, :second))

    assert still_admitted.state == :admitted
    assert NodeInventory.schedulable_nodes() == []

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               status,
               now,
               %{peer_identity | node_id: wrong_node_id}
             )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               authenticated_status(wrong_node_id),
               now,
               peer_identity
             )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               status,
               DateTime.add(now, -31, :second),
               peer_identity
             )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               status,
               now,
               %{peer_identity | certificate_identifier: "nodecert_substituted"}
             )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               Map.delete(status, :runtime_health),
               now,
               peer_identity
             )

    static_target =
      Target.grpc_compat(
        host: "authenticated-worker.orchard.test",
        port: 50_071,
        node_id: node_id
      )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               static_target,
               status,
               now,
               peer_identity
             )

    assert :noop =
             NodeInventory.observe_authenticated_status(
               target,
               status,
               DateTime.add(now, 30, :second),
               peer_identity
             )

    assert Repo.get!(InventoryNode, node_id).state == :admitted
    assert Repo.get(InventoryNode, wrong_node_id) == nil
    assert NodeInventory.schedulable_nodes() == []
    assert [%Target{node_id: ^node_id}] = Inference.activation_probe_runtime_endpoint_targets()
    assert Inference.runtime_endpoint_targets() == []

    assert {:ok, active} =
             NodeInventory.observe_authenticated_status(
               target,
               status,
               now,
               peer_identity
             )

    assert active.id == node_id
    assert active.state == :active
    assert [%Target{node_id: ^node_id}] = Inference.activation_probe_runtime_endpoint_targets()
    assert [%Target{node_id: ^node_id} = active_target] = Inference.runtime_endpoint_targets()
    assert active_target.metadata.authorization == :inference_dispatch
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]
  end

  @tag :task_2_8
  test "OpenSpec task 2.8 activates through a real certificate-backed gRPC status call",
       context do
    port = free_tcp_port()
    target = join_admit_and_configure_runtime!(context, port)
    start_enrolled_tls_server!(port)

    assert Repo.get!(InventoryNode, context.bundle["node_id"]).state == :admitted

    assert {:ok, [%{target_id: target_id, status: :observed}]} =
             ActivationProbe.run_once()

    assert target_id == target.id

    node_id = context.bundle["node_id"]
    assert Repo.get!(InventoryNode, node_id).state == :active
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]
  end

  @tag :liveness_evidence
  test "SPEC.md §4.5 leader-owned probe keeps an idle active Node live and demotes idle Node loss",
       context do
    port = free_tcp_port()
    _target = join_admit_and_configure_runtime!(context, port)
    start_enrolled_tls_server!(port)
    node_id = context.bundle["node_id"]
    unreachable_ms = Inference.node_unreachable_threshold_ms()

    IO.puts("""

    === issue #148 slice A: idle active-Node liveness over the real mTLS probe ===
    node_id=#{node_id} runtime endpoint=127.0.0.1:#{port}
    unreachable_threshold_ms=#{unreachable_ms} freshness_threshold_ms=#{Inference.node_freshness_threshold_ms()} probe_interval_ms=#{ActivationProbe.interval_ms()}
    No inference request is dispatched anywhere in this scenario. Probe cycles observe
    the Node over real mutual TLS; cycles that age past a threshold inject observed_at
    instead of sleeping through it.
    """)

    assert Repo.get!(InventoryNode, node_id).state == :admitted
    emit_liveness_row("admitted, before any probe cycle", node_id)

    assert {:ok, [%{status: :observed}]} = ActivationProbe.run_once()
    first = Repo.get!(InventoryNode, node_id)
    first_evidence = DispatchCapacity.get_capacity_evidence(node_id)
    assert first.state == :active
    assert first.health == :healthy
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]
    emit_liveness_row("probe cycle 1: admitted -> active", node_id)

    Process.sleep(1_100)

    assert {:ok, [%{status: :observed}]} = ActivationProbe.run_once()
    idle = Repo.get!(InventoryNode, node_id)
    idle_evidence = DispatchCapacity.get_capacity_evidence(node_id)
    assert idle.state == :active
    assert idle.health == :healthy
    assert DateTime.compare(idle.last_heartbeat_at, first.last_heartbeat_at) == :gt
    assert DateTime.compare(idle_evidence.observed_at, first_evidence.observed_at) == :gt
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]
    emit_liveness_row("probe cycle 2: idle refresh, no request traffic", node_id)

    aged_at = DateTime.add(idle.last_heartbeat_at, unreachable_ms + 1_000, :millisecond)
    Application.put_env(:orchard_controller, :control_plane, role: :standby)

    assert {:error, :controller_standby} =
             ActivationProbe.run_once(observed_at: aged_at, timeout: 1_000)

    assert :noop = NodeInventory.sweep_stale_node_heartbeats(aged_at)
    assert Repo.get!(InventoryNode, node_id).health == :healthy
    assert Repo.get!(InventoryNode, node_id).last_heartbeat_at == idle.last_heartbeat_at
    emit_liveness_row("standby Controller cycle: writes nothing", node_id)

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    assert {:ok, []} = ActivationProbe.run_once(targets: [], observed_at: aged_at)
    swept = Repo.get!(InventoryNode, node_id)
    assert swept.state == :active
    assert swept.health == :unreachable
    assert NodeInventory.schedulable_nodes() == []
    emit_liveness_row("sweep cycle: heartbeat aged past threshold", node_id)

    assert {:ok, [%{status: :observed}]} = ActivationProbe.run_once()
    recovered = Repo.get!(InventoryNode, node_id)
    assert recovered.health == :healthy
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]
    emit_liveness_row("probe cycle 3: observation clears demotion", node_id)

    fresh_failure_at = DateTime.add(recovered.last_heartbeat_at, 5, :second)
    stop_supervised!({:task_2_8_grpc_server, port})
    start_stalled_tls_server!(port)

    stalled_log =
      with_debug_logging(fn ->
        assert {:ok, []} = ActivationProbe.run_once(observed_at: fresh_failure_at, timeout: 1_000)
      end)

    assert probe_failure_reason(stalled_log) == "authenticated_transport_failed"

    degraded = Repo.get!(InventoryNode, node_id)
    assert degraded.health == :degraded
    assert Enum.map(NodeInventory.schedulable_nodes(), & &1.id) == [node_id]

    emit_liveness_row(
      "node runtime status fails (#{probe_failure_reason(stalled_log)})",
      node_id
    )

    stop_supervised!({:stalled_grpc_server, port})

    aged_failure_at =
      DateTime.add(recovered.last_heartbeat_at, unreachable_ms + 1_000, :millisecond)

    lost_log =
      with_debug_logging(fn ->
        assert {:ok, []} =
                 ActivationProbe.run_once(observed_at: aged_failure_at, timeout: 1_000)
      end)

    lost = Repo.get!(InventoryNode, node_id)
    assert lost.health == :unreachable
    assert NodeInventory.schedulable_nodes() == []

    emit_liveness_row(
      "node agent gone, past threshold (#{probe_failure_reason(lost_log)})",
      node_id
    )
  end

  @tag :task_2_10
  test "OpenSpec task 2.10 standby Controller cannot activate from authenticated status",
       context do
    port = free_tcp_port()
    target = join_admit_and_configure_runtime!(context, port)
    start_enrolled_tls_server!(port)
    Application.put_env(:orchard_controller, :control_plane, role: :standby)

    assert {:error, :controller_standby} = ActivationProbe.run_once()

    assert {:ok, %GrpcCompatibilityClient{security: {:mutual_tls, _, _}} = connection} =
             GrpcCompatibilityClient.connect(target)

    try do
      assert {:error, :authenticated_observation_rejected} =
               GrpcCompatibilityClient.status(connection, timeout: 5_000)
    after
      GrpcCompatibilityClient.disconnect(connection)
    end

    assert Repo.get!(InventoryNode, context.bundle["node_id"]).state == :admitted
    assert NodeInventory.schedulable_nodes() == []
  end

  @tag :task_2_8
  test "OpenSpec task 2.8 rejects a real gRPC server signed by the wrong internal CA",
       context do
    port = free_tcp_port()
    target = join_admit_and_configure_runtime!(context, port)

    {:ok, wrong_ca} =
      NodeTrustPKI.generate(
        context.bundle["cluster_id"],
        context.bundle["controller"]["id"],
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        DateTime.utc_now()
      )

    identity =
      issue_test_node_identity!(
        Path.join(context.identity_root, "wrong-ca-server"),
        wrong_ca,
        context.bundle["cluster_id"],
        context.bundle["node_id"]
      )

    start_test_tls_server!(port, identity, context.bundle["controller"]["uri_san"])
    capture_log(fn -> assert_authenticated_connection_rejected(target) end)
    assert Repo.get!(InventoryNode, context.bundle["node_id"]).state == :admitted
  end

  @tag :task_2_8
  test "OpenSpec task 2.8 rejects a correct-CA server with the wrong Node-id SAN",
       context do
    port = free_tcp_port()
    target = join_admit_and_configure_runtime!(context, port)
    {:ok, trust_material} = NodeTrustStore.load_current(context.trust_root)

    identity =
      issue_test_node_identity!(
        Path.join(context.identity_root, "wrong-node-server"),
        trust_material,
        context.bundle["cluster_id"],
        Ecto.UUID.generate()
      )

    start_test_tls_server!(port, identity, context.bundle["controller"]["uri_san"])
    capture_log(fn -> assert_authenticated_connection_rejected(target) end)
    assert Repo.get!(InventoryNode, context.bundle["node_id"]).state == :admitted
  end

  @tag :task_2_8
  test "OpenSpec task 2.8 rejects a correct-CA client with the wrong Controller-id SAN",
       context do
    port = free_tcp_port()
    target = join_admit_and_configure_runtime!(context, port)
    start_enrolled_tls_server!(port)
    node_paths = current_node_identity_paths(context.identity_root)

    wrong_controller_credential =
      GRPC.Credential.new(
        ssl: [
          certfile: node_paths.certfile,
          keyfile: node_paths.keyfile,
          cacertfile: node_paths.cacertfile,
          verify: :verify_peer,
          server_name_indication: :disable,
          verify_fun:
            PeerVerifier.new(target.metadata.node_uri_san,
              serial: target.metadata.certificate_serial,
              fingerprint: target.metadata.certificate_fingerprint
            )
        ]
      )

    capture_log(fn ->
      assert_transport_connection_rejected(target.address, wrong_controller_credential)
    end)

    assert Repo.get!(InventoryNode, context.bundle["node_id"]).state == :admitted
  end

  @tag :identity_integrity
  test "OpenSpec task 2.4 refuses corrupted prepared identity before credential transmission",
       context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.NoNetworkClient
    )

    for corruption <- [:private_key, :csr, :metadata] do
      File.rm_rf!(context.identity_root)
      assert {:ok, bundle} = NodeEnrollmentBundle.load(context.bundle_path)
      assert {:ok, prepared} = Store.prepare(context.identity_root, bundle)
      corrupt_prepared_identity!(context.identity_root, prepared, corruption, bundle)

      assert {:error, message, 1} =
               Node.run(["join", "--enrollment-bundle", context.bundle_path])

      assert message =~ "protected local Node identity state"
      refute_received :credential_transmission_attempted
    end

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
    assert enrollment.node.state == :provisioned
  end

  @tag :bundle_lifetime
  test "OpenSpec task 2.4 rejects a bundle over 24 hours without transmitting credentials",
       context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.NoNetworkClient
    )

    {:ok, issued_at, 0} = DateTime.from_iso8601(context.bundle["issued_at"])

    invalid_bundle =
      Map.put(
        context.bundle,
        "expires_at",
        issued_at |> DateTime.add(86_401, :second) |> DateTime.to_iso8601()
      )

    File.write!(context.bundle_path, Jason.encode!(invalid_bundle))

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "malformed or unsupported"
    refute_received :credential_transmission_attempted

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
  end

  @tag :task_2_10
  test "OpenSpec task 2.10 rejects an invalid runtime advertisement before key generation or credential transmission",
       context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.NoNetworkClient
    )

    Application.put_env(
      :orchard_cli,
      :node_runtime_endpoint,
      host: "0.0.0.0",
      port: 50_061,
      hostname: "invalid-runtime-target.orchard.test"
    )

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "protected local Node identity state"
    refute_received :credential_transmission_attempted
    assert {:error, :not_found} = Store.load_current(context.identity_root)

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
    assert enrollment.node.state == :provisioned
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 rejects an expired bundle locally without transmitting credentials",
       context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.NoNetworkClient
    )

    now = DateTime.utc_now()

    expired_bundle =
      context.bundle
      |> Map.put("issued_at", now |> DateTime.add(-7_200, :second) |> DateTime.to_iso8601())
      |> Map.put("expires_at", now |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601())

    File.write!(context.bundle_path, Jason.encode!(expired_bundle))

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "Node Enrollment Bundle has expired"
    refute_received :credential_transmission_attempted
    assert {:error, :not_found} = Store.load_current(context.identity_root)

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
    assert enrollment.node.state == :provisioned
    assert enrollment.certificate_result == %{}
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 rejects a revoked bundle through the public HTTPS redemption route",
       context do
    enrollment_id = context.bundle["enrollment_id"]
    node_id = context.bundle["node_id"]

    {1, nil} =
      Repo.update_all(
        from(enrollment in Orchard.Nodes.Enrollment, where: enrollment.id == ^enrollment_id),
        set: [state: :revoked, revoked_at: DateTime.utc_now()]
      )

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "Controller rejected Node Enrollment redemption"
    assert {:ok, enrollment} = NodeEnrollments.fetch(enrollment_id)
    assert enrollment.state == :revoked
    assert enrollment.node.state == :provisioned
    assert enrollment.consumed_at == nil
    assert enrollment.certificate_issuance_outcome == :not_started
    assert enrollment.certificate_result == %{}
    assert Repo.aggregate(InventoryNode, :count, :id) == 1
    assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 0
    assert Repo.get!(InventoryNode, node_id).state == :provisioned
    assert {:ok, %{state: "prepared"}} = Store.load_current(context.identity_root)
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 rejects wrong cluster and wrong Node bindings without mutation",
       context do
    wrong_cluster_id = Ecto.UUID.generate()
    wrong_node_id = Ecto.UUID.generate()

    wrong_cluster_controller =
      Map.put(
        context.bundle["controller"],
        "uri_san",
        "urn:orchard:cluster:#{wrong_cluster_id}:controller:#{context.bundle["controller"]["id"]}"
      )

    cases = [
      wrong_cluster:
        context.bundle
        |> Map.put("cluster_id", wrong_cluster_id)
        |> Map.put("controller", wrong_cluster_controller),
      wrong_node: Map.put(context.bundle, "node_id", wrong_node_id)
    ]

    for {name, tampered_bundle} <- cases do
      case_root = Path.join(context.root, "binding-#{name}")
      Application.put_env(:orchard_cli, :node_identity_root, case_root)
      File.write!(context.bundle_path, Jason.encode!(tampered_bundle))

      assert {:error, message, 1} =
               Node.run(["join", "--enrollment-bundle", context.bundle_path])

      assert message =~ "Controller rejected Node Enrollment redemption"
      assert {:ok, %{state: "prepared"}} = Store.load_current(case_root)
      assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
      assert enrollment.state == :issued
      assert enrollment.node.state == :provisioned
      assert enrollment.certificate_issuance_outcome == :not_started
      assert enrollment.certificate_result == %{}
      assert Repo.aggregate(InventoryNode, :count, :id) == 1
      assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 0
    end

    assert Repo.get(InventoryNode, wrong_node_id) == nil
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 refuses non-leader redemption without consuming the bundle",
       context do
    Application.put_env(:orchard_controller, :control_plane, role: :standby)

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "Controller could not complete Node Enrollment redemption"
    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :issued
    assert enrollment.node.state == :provisioned
    assert enrollment.consumed_at == nil
    assert enrollment.certificate_issuance_outcome == :not_started
    assert enrollment.certificate_result == %{}
    assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 0
    assert {:ok, %{state: "prepared"}} = Store.load_current(context.identity_root)

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    assert {:ok, success} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert success =~ "Node joined and registered"
    assert {:ok, consumed} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert consumed.state == :consumed
    assert consumed.node.state == :registered
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 concurrent HTTPS redemption returns one stored certificate identity",
       context do
    assert {:ok, bundle} = NodeEnrollmentBundle.load(context.bundle_path)
    assert {:ok, prepared} = Store.prepare(context.identity_root, bundle)

    identity =
      Map.put(prepared, :runtime_endpoint, %{
        host: "127.0.0.1",
        hostname: "concurrent-redemption.orchard.test",
        port: 50_061
      })

    start_certificate_issuance_trace()

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn -> PinnedHTTPS.redeem(bundle, identity) end)
      end)
      |> Task.await_many(10_000)

    assert [{:ok, first}, {:ok, second}] = results
    assert first == second
    assert certificate_issuance_call_count() == 1

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :consumed
    assert enrollment.node.state == :registered
    assert enrollment.certificate_result == first
    assert Repo.aggregate(InventoryNode, :count, :id) == 1
    assert Repo.aggregate(Orchard.Nodes.Enrollment, :count, :id) == 1
    assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 1
    assert consumed_audit_count(enrollment.id) == 1
    assert NodeInventory.schedulable_nodes() == []
  end

  @tag :task_2_9
  test "OpenSpec task 2.9 response loss resumes only with the original prepared key and CSR",
       context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.ResponseLossClient
    )

    start_certificate_issuance_trace()

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "could not complete Node Enrollment redemption"
    refute message =~ context.bundle["token"]
    assert_receive {:simulated_response_loss, response}
    assert certificate_issuance_call_count() == 1

    assert {:ok, enrollment} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert enrollment.state == :consumed
    assert enrollment.node.state == :registered
    assert enrollment.certificate_result == response
    assert consumed_audit_count(enrollment.id) == 1
    assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 1

    assert {:ok, prepared} = Store.load_current(context.identity_root)
    assert prepared.state == "prepared"
    prepared_generation_root = current_generation_root(context.identity_root)
    refute File.exists?(Path.join(prepared_generation_root, "node-certificate.pem"))
    refute File.exists?(Path.join(prepared_generation_root, "runtime-ca-certificate.pem"))

    different_identity_root = Path.join(context.root, "different-response-loss-identity")
    Application.put_env(:orchard_cli, :node_identity_root, different_identity_root)
    Application.put_env(:orchard_cli, :node_enrollment_client, PinnedHTTPS)

    assert {:error, rejection, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert rejection =~ "Controller rejected Node Enrollment redemption"
    assert {:ok, different_prepared} = Store.load_current(different_identity_root)
    assert different_prepared.state == "prepared"
    refute different_prepared.csr_fingerprint == prepared.csr_fingerprint
    assert certificate_issuance_call_count() == 1

    assert {:ok, unchanged} = NodeEnrollments.fetch(context.bundle["enrollment_id"])
    assert unchanged.certificate_result == response
    assert consumed_audit_count(unchanged.id) == 1

    Application.put_env(:orchard_cli, :node_identity_root, context.identity_root)

    assert {:ok, success} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert success =~ "Node joined and registered"
    assert certificate_issuance_call_count() == 1
    assert {:ok, registered} = Store.load_current(context.identity_root)
    assert registered.state == "registered"
    assert registered.certificate_identifier == response["certificate_identifier"]
    assert registered.node_certificate_pem == response["node_certificate_pem"]
    assert registered.runtime_ca_certificate_pem == response["runtime_ca_certificate_pem"]
    assert registered.csr_fingerprint == prepared.csr_fingerprint
    assert File.dir?(prepared_generation_root)
    assert Repo.aggregate(InventoryNode, :count, :id) == 1
    assert Repo.aggregate(Orchard.Nodes.Enrollment, :count, :id) == 1
    assert Repo.aggregate(Orchard.Nodes.AdmissionCandidate, :count, :id) == 1
    assert consumed_audit_count(enrollment.id) == 1
  end

  @tag :identity_integrity
  test "OpenSpec task 2.4 refuses identity corruption before finalization", context do
    Application.put_env(
      :orchard_cli,
      :node_enrollment_client,
      OrchardCLI.Commands.NodeJoinTest.CorruptingClient
    )

    assert {:error, message, 1} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert message =~ "protected local Node identity state"

    metadata =
      context.identity_root
      |> current_generation_root()
      |> Path.join("metadata.json")
      |> File.read!()
      |> Jason.decode!()

    assert metadata["state"] == "prepared"
    refute metadata["state"] == "registered"
  end

  defp corrupt_prepared_identity!(root, prepared, corruption, bundle) do
    generation_root = Path.join([root, "generations", prepared.generation_id])
    {:ok, replacement} = PKI.generate_csr(bundle.cluster_id, bundle.node_id)

    case corruption do
      :private_key ->
        File.write!(
          Path.join(generation_root, "node-private-key.pem"),
          replacement.private_key_pem
        )

      :csr ->
        File.write!(Path.join(generation_root, "node-csr.pem"), replacement.csr_pem)

      :metadata ->
        metadata_path = Path.join(generation_root, "metadata.json")
        metadata = metadata_path |> File.read!() |> Jason.decode!()
        changed = Map.put(metadata, "public_key_fingerprint", replacement.public_key_fingerprint)
        File.write!(metadata_path, Jason.encode!(changed))
    end
  end

  defp join_admit_and_configure_runtime!(context, port) do
    node_id = context.bundle["node_id"]
    enrollment_id = context.bundle["enrollment_id"]

    Application.put_env(
      :orchard_cli,
      :node_runtime_endpoint,
      host: "127.0.0.1",
      port: port,
      hostname: "mtls-worker.orchard.test"
    )

    assert {:ok, _join_output} =
             Node.run(["join", "--enrollment-bundle", context.bundle_path])

    assert {:ok, admitted} =
             NodeInventory.admit_node(node_id, %{
               "trust_evidence_ref" => "node-enrollment:#{enrollment_id}",
               "pool_id" => Ecto.UUID.generate(),
               "routing_policy_id" => Ecto.UUID.generate(),
               "capacity_policy_reason" => "approve joined Node capacity"
             })

    assert admitted.node.state == :admitted
    assert NodeInventory.schedulable_nodes() == []

    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(runtime,
        node_id: node_id,
        display_name: "mtls-worker",
        listen_address: [host: "127.0.0.1", port: port],
        node_identity_root: context.identity_root,
        runtime_tls_identity: nil,
        grpc_security: :mutual_tls
      )
    )

    assert [%Target{node_id: ^node_id} = target] =
             Inference.activation_probe_runtime_endpoint_targets()

    target
  end

  defp start_enrolled_tls_server!(port) do
    opts =
      NodeSupervisor.grpc_server_opts()
      |> Keyword.put(:endpoint, OrchardCLI.Commands.NodeJoinTest.Task28Endpoint)

    start_grpc_server!(port, opts)
  end

  # Same enrolled mTLS identity, but GetStatus fails: the Node is reachable and
  # authenticated while its runtime status RPC is unavailable.
  defp start_stalled_tls_server!(port) do
    opts =
      NodeSupervisor.grpc_server_opts()
      |> Keyword.put(:endpoint, OrchardCLI.Commands.NodeJoinTest.StalledRuntimeEndpoint)

    start_supervised!(
      Supervisor.child_spec(
        {GRPC.Server.Supervisor, opts},
        id: {:stalled_grpc_server, port}
      )
    )
  end

  defp start_test_tls_server!(port, identity, expected_controller_uri) do
    credential =
      GRPC.Credential.new(
        ssl: [
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          cacertfile: identity.cacertfile,
          verify: :verify_peer,
          fail_if_no_peer_cert: true,
          verify_fun: PeerVerifier.new(expected_controller_uri)
        ]
      )

    opts = [
      endpoint: OrchardCLI.Commands.NodeJoinTest.Task28Endpoint,
      port: port,
      start_server: true,
      adapter_opts: [ip: {127, 0, 0, 1}, cred: credential]
    ]

    start_grpc_server!(port, opts)
  end

  defp start_grpc_server!(port, opts) do
    start_supervised!(
      Supervisor.child_spec(
        {GRPC.Server.Supervisor, opts},
        id: {:task_2_8_grpc_server, port}
      )
    )
  end

  defp issue_test_node_identity!(root, ca, cluster_id, node_id) do
    {:ok, csr} = PKI.generate_csr(cluster_id, node_id)
    certificate_identity = PKI.certificate_identity(Ecto.UUID.generate(), csr.csr_fingerprint)

    {:ok, certificate} =
      PKI.issue_node_certificate(%{
        ca_private_key_pem: ca.ca_private_key_pem,
        ca_certificate_pem: ca.ca_certificate_pem,
        certificate_identifier: certificate_identity.identifier,
        cluster_id: cluster_id,
        csr_pem: csr.csr_pem,
        node_id: node_id,
        now: DateTime.utc_now(),
        serial: certificate_identity.serial
      })

    File.mkdir_p!(root)
    certfile = Path.join(root, "node-certificate.pem")
    keyfile = Path.join(root, "node-private-key.pem")
    cacertfile = Path.join(root, "runtime-ca-certificate.pem")
    File.write!(certfile, certificate.certificate_pem)
    File.write!(keyfile, csr.private_key_pem)
    File.write!(cacertfile, ca.ca_certificate_pem)

    for path <- [certfile, keyfile, cacertfile], do: File.chmod!(path, 0o600)
    %{certfile: certfile, keyfile: keyfile, cacertfile: cacertfile}
  end

  defp current_node_identity_paths(root) do
    generation_root = current_generation_root(root)

    %{
      certfile: Path.join(generation_root, "node-certificate.pem"),
      keyfile: Path.join(generation_root, "node-private-key.pem"),
      cacertfile: Path.join(generation_root, "runtime-ca-certificate.pem")
    }
  end

  defp assert_authenticated_connection_rejected(target) do
    case GrpcCompatibilityClient.connect(target) do
      {:ok, connection} ->
        try do
          assert {:error, _reason} = GrpcCompatibilityClient.status(connection, timeout: 5_000)
        after
          GrpcCompatibilityClient.disconnect(connection)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp assert_transport_connection_rejected(address, credential) do
    case TransportClient.connect(address, cred: credential) do
      {:ok, channel} ->
        try do
          assert {:error, _reason} = TransportClient.status(channel, timeout: 5_000)
        after
          TransportClient.disconnect(channel)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp emit_liveness_row(label, node_id) do
    node = Repo.get!(InventoryNode, node_id)
    schedulable = Enum.map(NodeInventory.schedulable_nodes(), & &1.id)
    status = StatusBuilder.node_status_map(node)

    IO.puts(
      [
        String.pad_trailing(label, 52),
        String.pad_trailing("state=#{node.state}", 15),
        String.pad_trailing("health=#{node.health}", 20),
        String.pad_trailing("heartbeat=#{node.last_heartbeat_at}", 40),
        String.pad_trailing(capacity_summary(node_id), 44),
        String.pad_trailing("schedulable=#{schedulable == [node_id]}", 19),
        "operator_status=#{operator_scheduling_summary(status)}"
      ]
      |> Enum.join(" ")
    )
  end

  defp operator_scheduling_summary(%{scheduling: scheduling}) do
    "eligible=#{scheduling[:eligible]} reasons=#{inspect(scheduling[:reason_codes])}"
  end

  defp with_debug_logging(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp probe_failure_reason(log) do
    case Regex.run(~r/Activation status probe failed for \S+: (\w+)/, log) do
      [_match, reason] -> reason
      nil -> "unlogged"
    end
  end

  defp capacity_summary(node_id) do
    case DispatchCapacity.get_capacity_evidence(node_id) do
      nil ->
        "capacity=none"

      evidence ->
        "capacity=#{evidence.active_request_count}/#{evidence.runtime_concurrency_limit}@#{evidence.observed_at}"
    end
  end

  defp free_tcp_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp authenticated_status(node_id) do
    %{
      node_metadata: %{
        node_id: node_id,
        display_name: "authenticated-worker",
        hostname: "authenticated-worker.orchard.test",
        listen_host: "10.0.0.72",
        listen_port: 50_071,
        agent_version: "0.1.0",
        worker_backend: "mlx"
      },
      runtime_health: %{ready: true, health_code: "", health_message: ""}
    }
  end

  defp start_https_controller!(tls) do
    start_supervised!(Orchard.API.Endpoint)

    pid =
      start_supervised!({
        Bandit,
        plug: Orchard.API.Endpoint,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        certfile: tls.cert_path,
        keyfile: tls.key_path,
        cipher_suite: :strong,
        startup_log: false
      })

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp current_generation_root(root) do
    generation = root |> Path.join("current") |> File.read!() |> String.trim()
    Path.join([root, "generations", generation])
  end

  defp node_uri(bundle) do
    "urn:orchard:cluster:#{bundle["cluster_id"]}:node:#{bundle["node_id"]}"
  end

  defp private_mode(path) do
    File.stat!(path).mode &&& 0o777
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

  defp consumed_audit_count(enrollment_id) do
    Repo.aggregate(
      from(audit in Orchard.Governance.AuditLog,
        where: audit.target_id == ^enrollment_id and audit.action == "node_enrollment.consumed"
      ),
      :count,
      :id
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
