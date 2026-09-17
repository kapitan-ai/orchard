defmodule Orchard.RuntimeEndpoint.WorkerRecoveryTransportTest do
  use Orchard.DataCase, async: false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    NodeRuntimeService,
    NodeWorkerRecoveryService,
    StatusRequest,
    WorkerRecoveryCommand,
    WorkerRecoveryKey,
    WorkerRecoveryResult
  }

  alias Orchard.Dispatch.GrpcNodeRuntimeClient

  alias Orchard.Node.{
    RuntimeServer,
    RuntimeTLS,
    WorkerRecoveryControlEndpoint,
    WorkerRecoveryControlListener,
    WorkerRecoveryControlServer,
    WorkerRecoveryShutdown
  }

  alias Orchard.Node.Endpoint, as: NodeEndpoint
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.Nodes.Node
  alias Orchard.NodeTrust.Store

  alias Orchard.RuntimeEndpoint.{
    BeamClient,
    GrpcCompatibilityClient,
    ModelRef,
    Operation,
    Target,
    WorkerRecoveryClient
  }

  alias Orchard.TransportTLS.{CertificateIdentity, PeerVerifier}

  @node_id "550e8400-e29b-41d4-a716-446655440000"
  @reasons ~w(worker_restart_backoff worker_restart_in_progress placement_crash_breaker_open placement_recovery_required)a

  defmodule CertificateAdapter do
    def get_cert(der), do: der
  end

  defmodule Manager do
    def inspect_worker_recovery(model, version) do
      send(
        Application.fetch_env!(:orchard_node_agent, :worker_recovery_transport_test_pid),
        {:inspect, model, version}
      )

      {:ok, Application.fetch_env!(:orchard_node_agent, :worker_recovery_transport_test_evidence)}
    end

    def recover_worker_placement(command) do
      send(
        Application.fetch_env!(:orchard_node_agent, :worker_recovery_transport_test_pid),
        {:recover, command}
      )

      if Application.get_env(:orchard_node_agent, :worker_recovery_transport_test_pause, false) do
        send(
          Application.fetch_env!(:orchard_node_agent, :worker_recovery_transport_test_pid),
          {:recovery_paused, self()}
        )

        receive do
          :complete_recovery_transport_test -> :ok
        end
      end

      Application.get_env(
        :orchard_node_agent,
        :worker_recovery_transport_test_result,
        {:ok,
         Application.fetch_env!(:orchard_node_agent, :worker_recovery_transport_test_evidence)}
      )
    end
  end

  setup do
    keys = [
      :runtime,
      :worker_recovery_control_manager,
      :worker_recovery_transport_test_pid,
      :worker_recovery_transport_test_evidence,
      :worker_recovery_transport_test_result,
      :worker_recovery_transport_test_pause
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:orchard_node_agent, &1)})
    material = certificate_material()

    [{:Certificate, der, :not_encrypted}] =
      :public_key.pem_decode(material.controller_certificate_pem)

    {:ok, certificate} = CertificateIdentity.from_der(der)

    identity = %{
      node_id: @node_id,
      controller_uri_san: hd(certificate.uri_sans),
      controller_certificate_identifier: "serial:#{certificate.serial}",
      controller_certificate_fingerprint: certificate.fingerprint
    }

    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      runtime |> Keyword.put(:runtime_tls_identity, identity) |> Keyword.put(:node_id, @node_id)
    )

    Application.put_env(:orchard_node_agent, :worker_recovery_control_manager, Manager)
    Application.put_env(:orchard_node_agent, :worker_recovery_transport_test_pid, self())
    Application.put_env(:orchard_node_agent, :worker_recovery_transport_test_evidence, evidence())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:orchard_node_agent, key, value)
        {key, :error} -> Application.delete_env(:orchard_node_agent, key)
      end)
    end)

    %{
      stream: %GRPC.Server.Stream{adapter: CertificateAdapter, payload: der},
      identity: identity,
      material: material
    }
  end

  test "SPEC §12.2 inspect authenticates before hydration and binds the exact Node", %{
    stream: stream
  } do
    assert %WorkerRecoveryResult{status: 200} =
             WorkerRecoveryControlServer.inspect_worker_recovery_placement(key(), stream)

    assert_received {:inspect, "runtime-model", "v1"}

    for bad_stream <- [
          nil,
          %{operator: true},
          %{stream | payload: nil},
          %{stream | payload: "malformed"}
        ] do
      assert %WorkerRecoveryResult{status: 403} =
               WorkerRecoveryControlServer.inspect_worker_recovery_placement(key(), bad_stream)
    end

    assert %WorkerRecoveryResult{status: 403} =
             WorkerRecoveryControlServer.inspect_worker_recovery_placement(
               %{key() | node_id: "other-node"},
               stream
             )

    assert %WorkerRecoveryResult{status: 422} =
             WorkerRecoveryControlServer.inspect_worker_recovery_placement(
               %{key() | version: " "},
               stream
             )

    refute_received {:inspect, _, _}
  end

  test "SPEC §12.2 a different certificate or incomplete registration cannot confer authority", %{
    stream: stream,
    identity: identity
  } do
    other = certificate_material()

    [{:Certificate, der, :not_encrypted}] =
      :public_key.pem_decode(other.controller_certificate_pem)

    assert %WorkerRecoveryResult{status: 403} =
             WorkerRecoveryControlServer.recover_worker_placement(command(), %{
               stream
               | payload: der
             })

    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    for patch <- [
          %{node_id: Ecto.UUID.generate()},
          %{controller_certificate_fingerprint: "wrong"},
          %{controller_certificate_identifier: "serial:wrong"},
          %{controller_uri_san: "wrong"},
          %{controller_certificate_fingerprint: nil}
        ] do
      Application.put_env(
        :orchard_node_agent,
        :runtime,
        runtime
        |> Keyword.put(:runtime_tls_identity, Map.merge(identity, patch))
        |> Keyword.put(:node_identity_root, nil)
      )

      assert %WorkerRecoveryResult{status: 403} =
               WorkerRecoveryControlServer.recover_worker_placement(command(), stream)
    end

    refute_received {:recover, _}
  end

  test "SPEC §12.2 typed reload roundtrip preserves key and concurrency fences", %{stream: stream} do
    request = %{
      command()
      | action: "reload",
        load_request: %EnsureModelLoadedRequest{
          node_id: @node_id,
          model_id: "runtime-model",
          version: "v1",
          artifact_source_uri: "file:///authorized/bundle"
        }
    }

    decoded = request |> WorkerRecoveryCommand.encode() |> WorkerRecoveryCommand.decode()
    assert decoded == request

    assert %WorkerRecoveryResult{status: 200} =
             WorkerRecoveryControlServer.recover_worker_placement(decoded, stream)

    assert_received {:recover, forwarded}
    assert forwarded.key == %{node_id: @node_id, model_id: "runtime-model", version: "v1"}
    assert forwarded.expected_epoch == "epoch-current"
    assert forwarded.expected_revision == 7
    assert forwarded.command_id == "operator-command"
    assert forwarded.load_request == request.load_request

    assert %WorkerRecoveryResult{status: 422} =
             WorkerRecoveryControlServer.recover_worker_placement(
               %{decoded | load_request: %{decoded.load_request | version: "v2"}},
               stream
             )

    refute_received {:recover, _}
  end

  test "SPEC §12.2 invalid and stale commands cannot gain force authority", %{stream: stream} do
    for patch <- [
          %{expected_epoch: ""},
          %{command_id: ""},
          %{reason: " "},
          %{action: "force"},
          %{action: "reload"}
        ] do
      assert %WorkerRecoveryResult{status: 422} =
               WorkerRecoveryControlServer.recover_worker_placement(
                 Map.merge(command(), patch),
                 stream
               )
    end

    refute_received {:recover, _}

    Application.put_env(
      :orchard_node_agent,
      :worker_recovery_transport_test_result,
      {:error, :conflict}
    )

    assert %WorkerRecoveryResult{status: 409} =
             WorkerRecoveryControlServer.recover_worker_placement(command(), stream)

    assert_received {:recover, %{expected_epoch: "epoch-current", expected_revision: 7}}
  end

  test "SPEC §12.2 raw BEAM and plaintext gRPC cannot inspect or clear with caller flags" do
    ref = %ModelRef{model_id: "runtime-model", version: "v1"}

    connection = %GrpcCompatibilityClient{security: :plaintext_compatibility, target: target()}

    assert {:error, :permission_denied} =
             GrpcCompatibilityClient.inspect_worker_recovery(connection, ref)

    assert {:error, :permission_denied} =
             GrpcCompatibilityClient.recover_worker_placement(connection, %{}, operator: true)

    # The BEAM adapter also goes through pinned mTLS rather than calling its raw facade.
    beam = %BeamClient{target: Target.beam(@node_id, address: node())}
    assert {:error, _} = BeamClient.inspect_worker_recovery(beam, ref)
    refute_received {:inspect, _, _}
    refute_received {:recover, _}
  end

  test "SPEC §12.2 client validates typed exact-key reload without rewriting epoch/revision" do
    key = evidence().key
    input = command_map()

    assert {:ok, wire, ^key} =
             WorkerRecoveryClient.request(target(), :recover_worker_placement, input)

    assert wire.expected_revision == 7
    assert wire.expected_epoch == "epoch-current"

    for bad <- [
          %{input | key: %{key | version: "v2"}},
          %{input | key: %{key | node_id: "other"}},
          %{input | load_request: nil}
        ] do
      assert {:error, :invalid_command} =
               WorkerRecoveryClient.request(target(), :recover_worker_placement, bad)
    end
  end

  test "SPEC §12.2 evidence is bounded, exact-key and fail-closed" do
    key = evidence().key
    assert {:ok, result} = WorkerRecoveryClient.decode_result(response(evidence()), key)
    assert result == evidence()

    for patch <- [
          %{key: %{key | version: "v2"}},
          %{epoch: ""},
          %{state: "legacy"},
          %{eligible: true},
          %{reason: "unknown"},
          %{revision: -1}
        ] do
      assert {:error, :unavailable} =
               WorkerRecoveryClient.decode_result(response(Map.merge(evidence(), patch)), key)
    end

    for json <- ["{}", "[]", "not-json", String.duplicate("x", 4097)] do
      assert {:error, :unavailable} =
               WorkerRecoveryClient.decode_result(
                 %WorkerRecoveryResult{status: 200, record_json: json},
                 key
               )
    end

    for {status, reason} <- [
          {403, :permission_denied},
          {409, :conflict},
          {422, :invalid_command},
          {503, :unavailable}
        ] do
      assert {:error, ^reason} =
               WorkerRecoveryClient.decode_result(%WorkerRecoveryResult{status: status}, key)
    end
  end

  test "SPEC §12.2 structured refusals precede load-failure mapping and preserve §5.10 vocabulary" do
    for reason <- @reasons do
      response = %EnsureModelLoadedResponse{
        placement_state: :PLACEMENT_STATE_FAILED,
        failure_code: "worker_unavailable",
        recovery_refusal: Atom.to_string(reason)
      }

      assert {:error, {:worker_recovery_refused, ^reason}} =
               WorkerRecoveryClient.ensure_result(response)

      assert RuntimeServer.safe_failure_reason_code({:worker_recovery_refused, reason}) ==
               "model_busy"

      assert response ==
               response
               |> EnsureModelLoadedResponse.encode()
               |> EnsureModelLoadedResponse.decode()
    end

    assert {:error, :invalid_worker_recovery_refusal} =
             WorkerRecoveryClient.ensure_result(%EnsureModelLoadedResponse{
               recovery_refusal: "unknown"
             })

    assert {:ok, %{placement_state: :failed, failure_code: "worker_unavailable"}} =
             WorkerRecoveryClient.ensure_result(%EnsureModelLoadedResponse{
               placement_state: :PLACEMENT_STATE_FAILED,
               failure_code: "worker_unavailable"
             })

    assert RuntimeServer.safe_failure_reason_code(:worker_unavailable) == "worker_unavailable"

    assert RuntimeServer.safe_failure_reason_code({:worker_recovery_refused, :unknown}) ==
             "runtime_error"
  end

  test "SPEC §12.2 combined gRPC mode keeps the ordinary inference listener credential", %{
    material: material
  } do
    {identity_root, _credential} = registered_identity!(material)
    {:ok, identity} = RuntimeTLS.load_registered_identity(identity_root)
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      runtime
      |> Keyword.put(:runtime_grpc_listener_enabled, true)
      |> Keyword.put(:grpc_security, :mutual_tls)
      |> Keyword.put(:runtime_tls_identity, identity)
      |> Keyword.put(:worker_recovery_control_enabled, true)
      |> Keyword.put(:node_identity_root, nil)
      |> Keyword.put(:listen_address, host: "127.0.0.1", port: free_port!())
    )

    assert WorkerRecoveryControlListener.enabled?()

    opts = NodeSupervisor.grpc_server_opts()
    assert opts[:endpoint] == NodeEndpoint
    assert opts[:adapter_opts][:cred]
  end

  test "SPEC §12.2 BEAM mode starts a recovery-only pinned TLS listener", %{material: material} do
    {identity_root, credential} = registered_identity!(material)
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      runtime
      |> Keyword.put(:runtime_grpc_listener_enabled, false)
      |> Keyword.put(:grpc_security, :plaintext_compatibility)
      |> Keyword.put(:runtime_tls_identity, nil)
      |> Keyword.put(:worker_recovery_control_enabled, true)
      |> Keyword.put(:node_identity_root, identity_root)
      |> Keyword.put(:listen_address, host: "127.0.0.1", port: free_port!())
    )

    opts = NodeSupervisor.grpc_server_opts()
    assert opts[:endpoint] == WorkerRecoveryControlEndpoint
    assert opts[:adapter_opts][:cred]
    assert WorkerRecoveryControlListener.enabled?()
    assert {:ok, {_flags, children}} = NodeSupervisor.init([])
    assert Enum.any?(children, &(&1.id == WorkerRecoveryControlListener))
    assert List.last(children).id == WorkerRecoveryShutdown
    start_supervised!({GRPC.Server.Supervisor, opts})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{opts[:port]}", cred: credential)
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    target = Target.grpc_compat(host: "127.0.0.1", port: opts[:port], node_id: @node_id)

    connection = %GrpcCompatibilityClient{
      channel: channel,
      target: target,
      security: {:mutual_tls, credential, nil}
    }

    ref = %ModelRef{model_id: "runtime-model", version: "v1"}

    assert {:ok, inspected} =
             GrpcCompatibilityClient.inspect_worker_recovery(connection, ref, timeout: 2_000)

    assert inspected == evidence()
    assert_receive {:inspect, "runtime-model", "v1"}

    assert {:ok, _} =
             GrpcCompatibilityClient.recover_worker_placement(connection, command_map(),
               timeout: 2_000
             )

    assert_receive {:recover,
                    %{action: "reload", expected_epoch: "epoch-current", expected_revision: 7}}

    assert {:error, %GRPC.RPCError{status: 13, message: "status got is 404 instead of 200"}} =
             NodeRuntimeService.Stub.get_status(
               channel,
               %StatusRequest{},
               timeout: 2_000
             )

    Application.put_env(:orchard_node_agent, :worker_recovery_transport_test_pause, true)

    pending =
      Task.async(fn ->
        GrpcCompatibilityClient.recover_worker_placement(connection, command_map(), timeout: 100)
      end)

    assert_receive {:recover, _}
    assert_receive {:recovery_paused, server}
    assert {:error, :unavailable} = Task.await(pending)
    send(server, :complete_recovery_transport_test)
    Application.put_env(:orchard_node_agent, :worker_recovery_transport_test_pause, false)
    refute_received {:recover, _}

    {:ok, identity} = RuntimeTLS.load_registered_identity(identity_root)

    anonymous =
      GRPC.Credential.new(
        ssl: [
          cacertfile: identity.cacertfile,
          verify: :verify_peer,
          server_name_indication: :disable,
          verify_fun: PeerVerifier.new(identity.node_uri_san)
        ]
      )

    {:ok, anonymous_channel} =
      GrpcNodeRuntimeClient.connect(target.address, cred: anonymous)

    on_exit(fn -> GRPC.Stub.disconnect(anonymous_channel) end)

    assert {:error, _} =
             NodeWorkerRecoveryService.Stub.inspect_worker_recovery_placement(
               anonymous_channel,
               key(),
               timeout: 500
             )

    refute_received {:inspect, _, _}

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Application.fetch_env!(:orchard_node_agent, :runtime)
      |> Keyword.put(:node_identity_root, nil)
    )

    assert_raise RuntimeError, ~r/requires registered mTLS identity/, fn ->
      NodeSupervisor.grpc_server_opts()
    end
  end

  for mode <- [:peer_grant, :shared_cookie] do
    @tag recovery_binding_mode: mode
    test "SPEC §12.2 configured #{mode} BEAM client uses registered pinned mTLS control", %{
      recovery_binding_mode: mode
    } do
      root =
        Path.join(
          System.tmp_dir!(),
          "orchard-recovery-beam-#{System.unique_integer([:positive])}"
        )

      configs = [:control_plane, :node_trust, :beam_peer_grants, :runtime_endpoint, :inference]
      previous = Map.new(configs, &{&1, Application.fetch_env(:orchard_controller, &1)})

      on_exit(fn ->
        File.rm_rf!(root)

        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:orchard_controller, key, value)
          {key, :error} -> Application.delete_env(:orchard_controller, key)
        end)
      end)

      File.mkdir_p!(root)
      trust_root = Path.join(root, "trust")
      authorization_root = Path.join(root, "beam-authority")
      Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
      Application.put_env(:orchard_controller, :node_trust, root: trust_root)

      Application.put_env(:orchard_controller, :beam_peer_grants,
        enabled: mode == :peer_grant,
        authorization_root_path: authorization_root
      )

      Application.put_env(:orchard_controller, :runtime_endpoint, transport: :beam)
      now = DateTime.utc_now()
      assert {:ok, trust} = Orchard.NodeTrust.initialize(root: trust_root, now: now)

      assert {:ok, _} =
               Orchard.ControllerInstances.ensure_local(
                 private_ipv4: "10.0.0.10",
                 membership_scope: :remote_beam,
                 node_trust_root: trust_root,
                 authorization_root_path: authorization_root,
                 now: now
               )

      assert {:ok, created} =
               Orchard.NodeEnrollments.create(
                 %{
                   cluster_id: trust.cluster_id,
                   expected_controller_id: trust.controller_id,
                   trust_authority_id: trust.trust_authority_id,
                   creator_type: "operator",
                   expires_at: DateTime.add(now, 3600, :second),
                   node: %{display_name: "recovery-transport"}
                 },
                 now: now
               )

      node_id = created.enrollment.node_id
      assert {:ok, _} = Orchard.NodeEnrollments.mark_issued(created.enrollment.id, now: now)
      assert {:ok, csr} = Orchard.NodeEnrollment.PKI.generate_csr(trust.cluster_id, node_id)

      assert {:ok, _} =
               Orchard.NodeEnrollments.redeem(
                 created.enrollment.id,
                 %{
                   cluster_id: trust.cluster_id,
                   controller_id: trust.controller_id,
                   csr_pem: csr.csr_pem,
                   node_id: node_id,
                   runtime_endpoint: %{
                     host: "10.0.0.20",
                     hostname: "recovery-transport.test",
                     port: 50_071
                   },
                   token: created.bootstrap_token
                 },
                 now: now
               )

      assert {:ok, %{grants: grants}} =
               Orchard.Nodes.admit_node(
                 node_id,
                 %{
                   trust_evidence_ref: "registration-audit:#{Ecto.UUID.generate()}",
                   pool_id: Ecto.UUID.generate(),
                   routing_policy_id: Ecto.UUID.generate(),
                   capacity_policy_reason: "transport regression"
                 },
                 now: now
               )

      assert {:ok, material} = Store.load_current(trust_root)
      {identity_root, _credential} = registered_identity!(material, node_id)
      assert {:ok, identity} = RuntimeTLS.load_registered_identity(identity_root)
      # The live certificate must be the one pinned by consumed enrollment and its grant.
      enrollment = Repo.get!(Orchard.Nodes.Enrollment, created.enrollment.id)
      original = enrollment.certificate_result

      assert {:ok, node_certificate} =
               CertificateIdentity.from_pem(original["node_certificate_pem"])

      peer = %Orchard.RuntimeEndpoint.AuthenticatedPeer{
        node_id: node_id,
        enrollment_id: enrollment.id,
        node_uri_san: original["node_uri_san"],
        certificate_identifier: enrollment.certificate_identifier,
        certificate_serial: node_certificate.serial,
        certificate_fingerprint: node_certificate.fingerprint,
        runtime_trust_spki_sha256: original["runtime_trust_spki_sha256"]
      }

      case grants do
        [grant] ->
          assert {:ok, _} =
                   Orchard.BeamPeerGrants.deliver(
                     %{
                       grant_id: grant.id,
                       generation: grant.generation,
                       controller_id: grant.controller_id
                     },
                     peer,
                     now: now
                   )

        [] ->
          assert mode == :shared_cookie
      end

      File.write!(identity.certfile, original["node_certificate_pem"])
      File.chmod!(identity.certfile, 0o600)
      File.write!(identity.keyfile, csr.private_key_pem)
      File.chmod!(identity.keyfile, 0o600)
      metadata_path = Path.join(Path.dirname(identity.certfile), "metadata.json")

      metadata =
        metadata_path
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("certificate_identifier", enrollment.certificate_identifier)

      write_private!(metadata_path, Jason.encode!(metadata))
      assert {:ok, identity} = RuntimeTLS.load_registered_identity(identity_root)
      port = free_port!()

      Repo.get!(Node, node_id)
      |> Ecto.Changeset.change(connect_host: "127.0.0.1", connect_port: port)
      |> Repo.update!()

      runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        runtime
        |> Keyword.put(:node_id, node_id)
        |> Keyword.put(:runtime_tls_identity, identity)
        |> Keyword.put(:node_identity_root, identity_root)
        |> Keyword.put(:grpc_security, :mutual_tls)
        |> Keyword.put(:runtime_grpc_listener_enabled, false)
        |> Keyword.put(:worker_recovery_control_enabled, true)
        |> Keyword.put(:listen_address, host: "127.0.0.1", port: port)
      )

      start_supervised!({GRPC.Server.Supervisor, NodeSupervisor.grpc_server_opts()})
      target = recovery_beam_target(mode, node_id)
      assert target.transport == :beam
      assert {:ok, control_target} = Orchard.Nodes.worker_recovery_control_target(target)
      assert control_target.transport == :grpc_compat
      assert control_target.node_id == node_id
      assert control_target.address == [host: "127.0.0.1", port: port]
      assert control_target.metadata.certificate_fingerprint == node_certificate.fingerprint
      assert {:ok, ^control_target} = Orchard.Nodes.worker_recovery_control_target(node_id)
      current = put_in(evidence(), [:key, :node_id], node_id)
      Application.put_env(:orchard_node_agent, :worker_recovery_transport_test_evidence, current)
      connection = %BeamClient{target: target}

      assert {:ok, ^current} =
               BeamClient.inspect_worker_recovery(
                 connection,
                 %ModelRef{model_id: "runtime-model", version: "v1"},
                 timeout: 2_000
               )

      assert_receive {:inspect, "runtime-model", "v1"}

      command =
        command_map()
        |> put_in([:key, :node_id], node_id)
        |> put_in([:load_request, Access.key(:node_id)], node_id)

      assert {:ok, ^current} =
               BeamClient.recover_worker_placement(connection, command, timeout: 2_000)

      assert_receive {:recover, %{key: %{node_id: ^node_id}}}
      if mode == :shared_cookie, do: assert_shared_cookie_binding_rejections(target, enrollment)
    end
  end

  defp recovery_beam_target(:peer_grant, _node_id) do
    assert {:ok, [target]} = Orchard.Nodes.activation_probe_runtime_endpoint_targets()
    target
  end

  defp recovery_beam_target(:shared_cookie, node_id) do
    target =
      Target.normalize(%{
        transport: :beam,
        address: :"orchard_node_agent@127.0.0.1",
        node_id: node_id,
        metadata: %{source_dev: true}
      })

    config = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      config
      |> Keyword.put(:allow_static_runtime_target_fallback, true)
      |> Keyword.put(:runtime_endpoint_client_impl, BeamClient)
      |> Keyword.put(:runtime_endpoint_targets, [target])
    )

    assert target.node_id == node_id
    assert Repo.aggregate(Orchard.BeamPeerGrants.Grant, :count) == 0
    target
  end

  defp assert_shared_cookie_binding_rejections(target, enrollment) do
    node_id = enrollment.node_id
    assert {:ok, expected} = WorkerRecoveryClient.control_target(target)
    # Caller metadata is never used to build credentials or choose a control address.
    assert {:ok, ^expected} =
             WorkerRecoveryClient.control_target(%{
               target
               | metadata: %{source: :trusted_node_inventory, certificate_fingerprint: "forged"}
             })

    assert {:error, :permission_denied} =
             WorkerRecoveryClient.control_target(%{target | node_id: Ecto.UUID.generate()})

    assert {:ok, ^expected} =
             WorkerRecoveryClient.control_target(%{
               target
               | address: :"orchard_node_agent@127.0.0.2",
                 node_id: node_id
             })

    assert {:ok, ^expected} =
             WorkerRecoveryClient.control_target(%{
               target
               | address: :"orchard_node_agent@127.0.0.2"
             })

    node = Repo.get!(Node, node_id)
    Repo.update!(Ecto.Changeset.change(node, state: :registered))
    assert {:error, :permission_denied} = WorkerRecoveryClient.control_target(target)
    Repo.update!(Ecto.Changeset.change(Repo.get!(Node, node_id), state: node.state))
    Repo.update!(Ecto.Changeset.change(enrollment, certificate_result: %{}))
    assert {:error, :permission_denied} = WorkerRecoveryClient.control_target(target)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Orchard.Nodes.Enrollment, enrollment.id),
        certificate_result: enrollment.certificate_result
      )
    )

    other_id = Ecto.UUID.generate()

    clone_row!(node, %{
      id: other_id,
      display_name: "ambiguous-control-locator",
      advertise_addr: "10.0.0.21",
      canonical_beam_name: nil,
      connect_port: free_port!()
    })

    clone_row!(enrollment, %{
      id: Ecto.UUID.generate(),
      node_id: other_id,
      token_prefix: "ambiguous-control",
      token_hash: "ambiguous-control-hash",
      certificate_identifier: "serial:999"
    })

    # A separate malformed row cannot redirect an identity-bound recovery target.
    assert {:ok, ^expected} = WorkerRecoveryClient.control_target(target)

    assert {:ok, ^expected} =
             WorkerRecoveryClient.control_target(%{target | node_id: node_id})

    refute_received {:inspect, _, _}
    refute_received {:recover, _}
  end

  defp clone_row!(%module{} = row, overrides) do
    attrs =
      row |> Map.from_struct() |> Map.take(module.__schema__(:fields)) |> Map.merge(overrides)

    Repo.insert!(struct!(module, attrs))
  end

  defp registered_identity!(material, node_id \\ @node_id) do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-recovery-transport-#{System.unique_integer([:positive])}"
      )

    generation = Ecto.UUID.generate()
    generation_root = Path.join([root, "generations", generation])
    File.mkdir_p!(generation_root)

    for directory <- [root, Path.join(root, "generations"), generation_root],
        do: File.chmod!(directory, 0o700)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, csr} = Orchard.NodeEnrollment.PKI.generate_csr(material.cluster_id, node_id)

    {:ok, issued} =
      Orchard.NodeEnrollment.PKI.issue_node_certificate(%{
        csr_pem: csr.csr_pem,
        cluster_id: material.cluster_id,
        node_id: node_id,
        ca_private_key_pem: material.ca_private_key_pem,
        ca_certificate_pem: material.ca_certificate_pem,
        serial: 42,
        certificate_identifier: "serial:42",
        now: DateTime.utc_now()
      })

    {:ok, controller} = CertificateIdentity.from_pem(material.controller_certificate_pem)

    metadata = %{
      state: "registered",
      generation_id: generation,
      enrollment_id: Ecto.UUID.generate(),
      cluster_id: material.cluster_id,
      node_id: node_id,
      controller_id: material.controller_id,
      controller_uri_san: hd(controller.uri_sans),
      controller_certificate_identifier: "serial:#{controller.serial}",
      controller_certificate_fingerprint: controller.fingerprint,
      node_uri_san: issued.node_uri_san,
      certificate_identifier: "serial:42",
      runtime_trust_spki_sha256: material.ca_spki_fingerprint
    }

    files = %{
      "metadata.json" => Jason.encode!(metadata),
      "node-certificate.pem" => issued.certificate_pem,
      "node-private-key.pem" => csr.private_key_pem,
      "runtime-ca-certificate.pem" => material.ca_certificate_pem,
      "controller-certificate.pem" => material.controller_certificate_pem
    }

    Enum.each(files, fn {name, content} ->
      write_private!(Path.join(generation_root, name), content)
    end)

    write_private!(Path.join(root, "current"), generation <> "\n")
    controller_key = Path.join(root, "controller-key.pem")
    write_private!(controller_key, material.controller_private_key_pem)

    {:ok, identity} =
      RuntimeTLS.load_registered_identity(root, require_controller_certificate: true)

    credential =
      GRPC.Credential.new(
        ssl: [
          certfile: identity.controller_certfile,
          keyfile: controller_key,
          cacertfile: identity.cacertfile,
          verify: :verify_peer,
          server_name_indication: :disable,
          verify_fun:
            PeerVerifier.new(identity.node_uri_san,
              fingerprint: identity.certificate_fingerprint
            )
        ]
      )

    {root, credential}
  end

  defp write_private!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o600)
  end

  defp free_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp certificate_material do
    {:ok, material} =
      Orchard.NodeTrust.PKI.generate(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        DateTime.utc_now()
      )

    material
  end

  defp key, do: %WorkerRecoveryKey{node_id: @node_id, model_id: "runtime-model", version: "v1"}

  defp command,
    do: %WorkerRecoveryCommand{
      key: key(),
      expected_epoch: "epoch-current",
      expected_revision: 7,
      command_id: "operator-command",
      action: "clear",
      reason: "operator cleanup"
    }

  defp target, do: Target.grpc_compat(host: "127.0.0.1", port: 15_379, node_id: @node_id)

  defp evidence,
    do: %{
      key: %{node_id: @node_id, model_id: "runtime-model", version: "v1"},
      epoch: "epoch-current",
      owner_epoch: "epoch-current",
      revision: 7,
      state: "open",
      hydrated: true,
      eligible: false,
      reason: "placement_crash_breaker_open"
    }

  defp response(evidence),
    do: %WorkerRecoveryResult{status: 200, record_json: Jason.encode!(evidence)}

  defp command_map do
    %{
      key: evidence().key,
      expected_epoch: "epoch-current",
      expected_revision: 7,
      command_id: "operator-command",
      action: "reload",
      reason: "operator cleanup",
      load_request: %Operation.EnsureModelLoadedRequest{
        node_id: @node_id,
        model_ref: %ModelRef{model_id: "runtime-model", version: "v1"}
      }
    }
  end
end
