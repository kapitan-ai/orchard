defmodule Orchard.RuntimeEndpoint.BeamClientTest do
  use Orchard.DataCase, async: false

  alias Orchard.BeamPeerGrants
  alias Orchard.ControllerInstances
  alias Orchard.DispatchCapacity
  alias Orchard.Inference
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.NodeEnrollment.PKI
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.NodeTrust

  alias Orchard.RuntimeEndpoint.{
    AuthenticatedPeer,
    BeamClient,
    GrpcCompatibilityClient,
    ModelRef,
    Observation,
    Operation,
    Target
  }

  alias Orchard.TransportTLS.CertificateIdentity

  @node_id "550e8400-e29b-41d4-a716-446655440000"

  setup do
    previous_config = Application.get_env(:orchard_controller, :runtime_endpoint)
    previous_grants = Application.get_env(:orchard_controller, :beam_peer_grants)
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    if Process.whereis(:beam_client_test_pid), do: Process.unregister(:beam_client_test_pid)
    Process.register(self(), :beam_client_test_pid)

    on_exit(fn ->
      restore_runtime_endpoint_config(previous_config)
      restore_peer_grant_config(previous_grants)
      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.delete_env(:orchard_controller, :beam_client_reported_node_id)
      Application.delete_env(:orchard_controller, :authenticated_grpc_status)

      if Process.whereis(:beam_client_test_pid) == self() do
        Process.unregister(:beam_client_test_pid)
      end
    end)

    :ok
  end

  defmodule Server do
    alias Orchard.RuntimeEndpoint.{Observation, Operation}

    def status(target, _opts) do
      {:ok, Observation.new(endpoint_id: target.id, target: target, availability: :available)}
    end

    def ensure_model_loaded(%Operation.EnsureModelLoadedRequest{}, _opts) do
      {:ok, %Operation.EnsureModelLoadedResult{already_loaded: true, placement_state: :loaded}}
    end

    def unload_model(%Operation.UnloadModelRequest{}, _opts) do
      {:ok, %Operation.Ack{ok: true, message: "unloaded"}}
    end

    def execute_inference(%Operation.ExecuteRequest{} = request, owner, stream_ref, _opts) do
      send(
        owner,
        {:runtime_endpoint_event, stream_ref, request.request_id,
         Orchard.InferenceEvent.accepted(1)}
      )

      send(owner, {:runtime_endpoint_done, stream_ref, :ok})
      {:ok, self()}
    end

    def cancel_inference(%Operation.CancelRequest{}, _opts), do: :ok

    def score_prefix_cache(%Operation.PrefixCacheScoreRequest{}, _opts) do
      {:ok, %Operation.PrefixCacheScoreResult{status_code: "ok", score_tier: "resident"}}
    end
  end

  defmodule RawInventoryServer do
    alias Orchard.RuntimeEndpoint.Observation

    # Simulates a Node-built Observation term that bypassed local normalization.
    def status(target, _opts) do
      observation =
        Observation.new(endpoint_id: target.id, target: target, availability: :available)

      inventory = Application.get_env(:orchard_controller, :beam_client_test_host_inventory)
      {:ok, %{observation | host_inventory: inventory}}
    end
  end

  defmodule FutureObservationServer do
    alias Orchard.Nodes.Node
    alias Orchard.Repo
    alias Orchard.RuntimeEndpoint.Observation

    def status(target, _opts) do
      remote_observed_at = Process.get({__MODULE__, :remote_observed_at})

      attrs =
        case Repo.get(Node, target.node_id) do
          nil ->
            %{
              endpoint_id: target.id,
              target: target,
              observed_at: remote_observed_at,
              availability: :available,
              aggregate_active_request_count: 0,
              aggregate_max_concurrency: 2
            }

          node ->
            %{
              endpoint_id: target.id,
              target: target,
              observed_at: remote_observed_at,
              availability: :available,
              aggregate_active_request_count: 0,
              aggregate_max_concurrency: 2,
              metadata: %{
                node_id:
                  Application.get_env(:orchard_controller, :beam_client_reported_node_id, node.id),
                display_name: node.display_name,
                hostname: node.hostname,
                listen_host: node.connect_host,
                listen_port: node.connect_port,
                agent_version: "0.5.0-dev"
              },
              health: %{ready: true, health_code: "", health_message: ""}
            }
        end

      {:ok, Observation.new(attrs)}
    end
  end

  defmodule ConnectedBeamClient do
    def connect(target) do
      {:ok,
       %Orchard.RuntimeEndpoint.BeamClient{
         authenticated_peer: Process.get(:authenticated_status_peer),
         node: node(),
         server_module: FutureObservationServer,
         target: target
       }}
    end

    defdelegate status(connection, opts), to: Orchard.RuntimeEndpoint.BeamClient
    defdelegate disconnect(connection), to: Orchard.RuntimeEndpoint.BeamClient
  end

  defmodule StatusServer do
    use GRPC.Server, service: Orchard.Cluster.V1.NodeRuntimeService.Service

    def get_status(_request, _stream) do
      Application.fetch_env!(:orchard_controller, :authenticated_grpc_status)
    end
  end

  defmodule StatusEndpoint do
    use GRPC.Endpoint
    run(StatusServer)
  end

  defmodule RaisingServer do
    def execute_inference(_request, _owner, _stream_ref, _opts), do: raise("boom")
    def score_prefix_cache(_request, _opts), do: raise("boom")
  end

  defmodule SlowServer do
    alias Orchard.RuntimeEndpoint.Operation

    def ensure_model_loaded(%Operation.EnsureModelLoadedRequest{}, _opts) do
      if test_pid = Process.whereis(:beam_client_test_pid) do
        send(test_pid, {:slow_server_started, self()})
      end

      receive do
        :finish_load ->
          {:ok,
           %Operation.EnsureModelLoadedResult{already_loaded: true, placement_state: :loaded}}
      after
        5_000 ->
          {:ok,
           %Operation.EnsureModelLoadedResult{already_loaded: true, placement_state: :loaded}}
      end
    end
  end

  test "connect rejects unsupported target transports" do
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071)

    assert {:error, {:unsupported_transport, :grpc_compat}} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5 connect normalizes prebuilt BEAM targets at the client boundary" do
    target = %Target{
      id: "source-dev-node-agent",
      transport: :beam,
      address: Atom.to_string(node()),
      node_id: @node_id,
      metadata: %{server_module: Server}
    }

    assert {:ok, %BeamClient{target: %Target{address: address}}} = BeamClient.connect(target)
    assert address == Atom.to_string(node())
  end

  test "SPEC.md §7.5.0 unknown BEAM names use the stable operator failure" do
    target = Target.beam(@node_id, address: "orchard_node_agent_missing@10.0.0.20")

    assert {:error, :beam_target_unknown} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 production BEAM rejects a static target before connection" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)
    put_peer_grant_beam_config()

    target =
      Target.beam(@node_id,
        address: Atom.to_string(node()),
        metadata: %{server_module: Server}
      )

    assert {:error, :beam_target_not_in_trusted_inventory} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 source dev cannot bypass peer-grant BEAM guardrails" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)
    Application.put_env(:orchard_controller, :runtime_endpoint, [])

    target = Target.beam(@node_id, address: Atom.to_string(node()))

    assert {:error, :beam_distribution_disabled} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 claimed inventory provenance without a grant fails closed" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)
    put_peer_grant_beam_config()

    target =
      Target.beam(@node_id,
        address: Atom.to_string(node()),
        metadata: %{
          source: :trusted_node_inventory,
          server_module: Server
        }
      )

    assert {:error, :beam_peer_grant_missing} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 fabricated grant provenance fails closed" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)
    put_peer_grant_beam_config()

    target =
      Target.beam(@node_id,
        address: Atom.to_string(node()),
        metadata: %{
          grant_id: "7caf0b96-8fe3-467a-b072-f36906f5a670",
          source: :trusted_node_inventory,
          server_module: Server
        }
      )

    assert {:error, :beam_peer_grant_missing} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5.0 production grants never default to gRPC compatibility" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)

    inference =
      :orchard_controller
      |> Application.fetch_env!(:inference)
      |> Keyword.delete(:runtime_endpoint_client_impl)

    Application.put_env(:orchard_controller, :inference, inference)

    assert Inference.runtime_endpoint_client() == BeamClient
  end

  test "SPEC.md §7.5.0 production grant mode validates without a shared cookie" do
    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: true)

    put_beam_config(
      enabled: true,
      node_name: "orchard_controller_550e8400e29b41d4a716446655440000@10.0.0.5",
      cookie_file: nil,
      admitted_services: [],
      allowed_cidrs: [],
      listen_host: "10.0.0.5"
    )

    target =
      Target.beam(@node_id,
        address: "orchard_node_agent_550e8400e29b41d4a716446655440000@10.0.0.42",
        metadata: %{
          grant_id: "7caf0b96-8fe3-467a-b072-f36906f5a670",
          source: :trusted_node_inventory
        }
      )

    assert {:error, :beam_peer_grant_missing} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5 enabled config applies guardrails before local BEAM RPC" do
    put_beam_config(
      enabled: true,
      node_name: "orchard_controller@10.0.0.5",
      cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
      admitted_services: ["orchard_node_agent"],
      allowed_cidrs: ["10.0.0.0/24"],
      listen_host: "10.0.0.5"
    )

    target = Target.beam(@node_id, address: node(), metadata: %{server_module: Server})

    assert {:error, reason} = BeamClient.connect(target)
    assert reason in [:beam_distribution_unavailable, :beam_node_identity_mismatch]
  end

  test "serves Runtime Endpoint operations over the BEAM client contract" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: Server})

    assert {:ok, connection} = BeamClient.connect(target)
    assert {:ok, %Observation{availability: :available}} = BeamClient.status(connection, [])

    load_request = %Operation.EnsureModelLoadedRequest{model_ref: model_ref}

    assert {:ok, %{already_loaded: true, placement_state: :loaded}} =
             BeamClient.ensure_model_loaded(connection, load_request, [])

    unload_request = %Operation.UnloadModelRequest{model_ref: model_ref}

    assert {:ok, %Operation.Ack{ok: true}} =
             BeamClient.unload_model(connection, unload_request, [])

    execute_request = %Operation.ExecuteRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      rendered_prompt_utf8: "hello",
      input_tokens: 1
    }

    assert {:ok, stream_ref} =
             BeamClient.execute_inference(connection, execute_request, owner: self())

    assert_receive {:runtime_endpoint_event, ^stream_ref, "req_1", %InferenceEvent{}}
    assert_receive {:runtime_endpoint_done, ^stream_ref, :ok}

    cancel_request = %Operation.CancelRequest{
      request_id: "req_1",
      controller_session_id: "session_1"
    }

    assert :ok = BeamClient.cancel_inference(connection, cancel_request, [])

    score_request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "ok", score_tier: "resident"}} =
             BeamClient.score_prefix_cache(connection, score_request, [])

    assert :ok = BeamClient.disconnect(connection)
  end

  describe "SPEC.md §4.1 BEAM host inventory bound" do
    setup do
      on_exit(fn ->
        Application.delete_env(:orchard_controller, :beam_client_test_host_inventory)
      end)
    end

    test "a bounded Node inventory is kept and an unbounded or foreign term is absent" do
      target =
        Target.beam(@node_id,
          address: node(),
          metadata: %{server_module: RawInventoryServer, source_dev: true}
        )

      valid = beam_test_inventory()
      oversized = put_in(valid.cpu.model_name, String.duplicate("x", 300))

      provider = %Orchard.Cluster.V1.AcceleratorProviderObservation{
        vendor: :ACCELERATOR_VENDOR_NVIDIA
      }

      improper_top = %{valid | accelerator_providers: [provider | :tail]}
      improper_nested = %{valid | accelerator_providers: [%{provider | devices: [:d | :tail]}]}

      inventories = [
        valid,
        oversized,
        %{schema_version: 1},
        {:raw, self()},
        improper_top,
        improper_nested,
        %{valid | __unknown_fields__: :bogus},
        Map.delete(valid, :__unknown_fields__),
        %{valid | __unknown_fields__: [{4, 2, <<0xFF>>}]}
      ]

      results =
        for inventory <- inventories do
          Application.put_env(:orchard_controller, :beam_client_test_host_inventory, inventory)
          assert {:ok, connection} = BeamClient.connect(target)
          assert {:ok, observation} = BeamClient.status(connection, [])
          observation.host_inventory
        end

      assert results == [valid, nil, nil, nil, nil, nil, nil, nil, nil]
    end
  end

  test "issue #201 SPEC §4.6.1 source-dev BEAM status uses Controller receive time" do
    target =
      Target.beam(@node_id,
        address: node(),
        metadata: %{server_module: FutureObservationServer, source_dev: true}
      )

    remote_observed_at = DateTime.add(DateTime.utc_now(), 5, :minute)
    Process.put({FutureObservationServer, :remote_observed_at}, remote_observed_at)
    on_exit(fn -> Process.delete({FutureObservationServer, :remote_observed_at}) end)

    assert {:ok, connection} = BeamClient.connect(target)
    before_status = DateTime.utc_now()
    assert {:ok, observation} = BeamClient.status(connection, [])
    after_status = DateTime.utc_now()

    assert DateTime.compare(observation.observed_at, before_status) in [:eq, :gt]
    assert DateTime.compare(observation.observed_at, after_status) in [:eq, :lt]
    refute observation.observed_at == remote_observed_at
  end

  test "issue #201 SPEC §4.6.2 authenticated BEAM status shares Controller receive time with evidence" do
    {target, peer} = authenticated_beam_fixture!()
    target = put_in(target.metadata[:server_module], FutureObservationServer)
    remote_observed_at = DateTime.add(DateTime.utc_now(), 5, :minute)
    Process.put({FutureObservationServer, :remote_observed_at}, remote_observed_at)
    on_exit(fn -> Process.delete({FutureObservationServer, :remote_observed_at}) end)

    connection = %BeamClient{
      authenticated_peer: peer,
      node: node(),
      server_module: FutureObservationServer,
      target: target
    }

    before_status = DateTime.utc_now()
    assert {:ok, observation} = BeamClient.status(connection, [])
    after_status = DateTime.utc_now()
    evidence = DispatchCapacity.get_capacity_evidence(target.node_id)

    assert DateTime.compare(observation.observed_at, before_status) in [:eq, :gt]
    assert DateTime.compare(observation.observed_at, after_status) in [:eq, :lt]
    refute observation.observed_at == remote_observed_at
    assert evidence.observed_at == observation.observed_at
  end

  test "SPEC §7.3 authenticated snapshot reads preserve domain rows; default status observes" do
    {target, peer} = authenticated_beam_fixture!()
    Process.put(:authenticated_status_peer, peer)
    previous_console = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(:orchard_controller, :console,
      runtime_endpoint_client_impl: ConnectedBeamClient
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous_console) end)
    {source, capacity_grant} = seed_capacity_source(peer.node_id)
    before_rows = domain_rows()

    assert {:ok, %{node_metadata: %{node_id: node_id}}} =
             OrchardConsole.Runtime.snapshot(target: target, observe?: false, timeout: 2_000)

    assert node_id == peer.node_id
    assert domain_rows() == before_rows
    assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]
    assert Repo.get!(Node, node_id).state == :admitted

    assert {:ok, connection} = ConnectedBeamClient.connect(target)
    assert {:ok, _observation} = BeamClient.status(connection)
    assert Repo.get!(Node, node_id).state == :active
    assert DispatchCapacity.get_capacity_evidence(node_id)
    refute domain_rows() == before_rows

    Application.put_env(:orchard_controller, :control_plane, role: :standby)
    active_rows = domain_rows()
    assert {:ok, _observation} = BeamClient.status(connection, timeout: 2_000, observe?: false)
    assert domain_rows() == active_rows
    assert :ok = QueueManager.release(capacity_grant)
  end

  test "SPEC §7.3 authenticated read rejects invalid peers without clearing capacity" do
    {target, peer} = authenticated_beam_fixture!()

    connection = %BeamClient{
      authenticated_peer: peer,
      node: node(),
      server_module: FutureObservationServer,
      target: target
    }

    assert {:ok, _} = BeamClient.status(connection)
    assert DispatchCapacity.get_capacity_evidence(peer.node_id)
    {source, capacity_grant} = seed_capacity_source(peer.node_id)
    before_rows = domain_rows()

    for invalid <- [
          %{connection | authenticated_peer: %{peer | certificate_identifier: "wrong"}},
          %{connection | authenticated_peer: %{peer | certificate_fingerprint: "wrong"}},
          %{connection | authenticated_peer: %{peer | enrollment_id: Ecto.UUID.generate()}},
          %{connection | authenticated_peer: %{peer | node_id: Ecto.UUID.generate()}},
          %{connection | target: %{target | address: "wrong@10.0.0.20"}}
        ] do
      assert {:error, :beam_peer_observation_rejected} =
               BeamClient.status(invalid, observe?: false)

      assert domain_rows() == before_rows
      assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]
    end

    Application.put_env(:orchard_controller, :beam_client_reported_node_id, Ecto.UUID.generate())

    assert {:error, :beam_peer_observation_rejected} =
             BeamClient.status(connection, observe?: false)

    assert domain_rows() == before_rows
    Application.delete_env(:orchard_controller, :beam_client_reported_node_id)
    assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]

    enrollment = Repo.get!(Enrollment, peer.enrollment_id)
    grant = Repo.get!(BeamPeerGrants.Grant, target.metadata.grant_id)
    node = Repo.get!(Node, peer.node_id)

    for {record, changes} <- [
          {enrollment, [state: :revoked, revoked_at: DateTime.utc_now()]},
          {enrollment, [certificate_result: %{}]},
          {grant, [state: :revoked, revoked_at: DateTime.utc_now()]},
          {grant,
           [
             not_before_at: DateTime.add(DateTime.utc_now(), -2, :second),
             expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
           ]},
          {node, [state: :registered]}
        ] do
      record |> Ecto.Changeset.change(changes) |> Repo.update!()
      rejected_rows = domain_rows()

      assert {:error, :beam_peer_observation_rejected} =
               BeamClient.status(connection, observe?: false)

      assert domain_rows() == rejected_rows
      assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]

      record
      |> Repo.reload!()
      |> Ecto.Changeset.change(
        Keyword.new(changes, fn {key, _} -> {key, Map.fetch!(record, key)} end)
      )
      |> Repo.update!()

      assert {:ok, _} = BeamClient.status(connection, observe?: false)
    end

    assert :ok = QueueManager.release(capacity_grant)
  end

  test "SPEC §7.3 mTLS compatibility reads preserve rows and reject unverified status" do
    {_target, peer} = authenticated_beam_fixture!()
    connection = authenticated_grpc_connection!(peer)
    before_rows = domain_rows()

    assert {:ok, observation} = GrpcCompatibilityClient.status(connection, observe?: false)
    assert observation.metadata.node_id == peer.node_id
    assert domain_rows() == before_rows

    assert {:ok, _} = GrpcCompatibilityClient.status(connection)
    assert Repo.get!(Node, peer.node_id).state == :active
    assert DispatchCapacity.get_capacity_evidence(peer.node_id)
    refute domain_rows() == before_rows
    {source, capacity_grant} = seed_capacity_source(peer.node_id)
    active_rows = domain_rows()

    {:mutual_tls, credential, _peer} = connection.security

    invalid = %{
      connection
      | security: {:mutual_tls, credential, %{peer | certificate_identifier: "wrong"}}
    }

    assert {:error, :authenticated_observation_rejected} =
             GrpcCompatibilityClient.status(invalid, observe?: false)

    assert domain_rows() == active_rows
    assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]

    response = Application.fetch_env!(:orchard_controller, :authenticated_grpc_status)

    Application.put_env(:orchard_controller, :authenticated_grpc_status, %{
      response
      | node_metadata: %{response.node_metadata | node_id: Ecto.UUID.generate()}
    })

    assert {:error, :authenticated_observation_rejected} =
             GrpcCompatibilityClient.status(connection, observe?: false)

    assert domain_rows() == active_rows
    Application.put_env(:orchard_controller, :authenticated_grpc_status, response)

    Repo.get!(Enrollment, peer.enrollment_id)
    |> Ecto.Changeset.change(state: :revoked, revoked_at: DateTime.utc_now())
    |> Repo.update!()

    revoked_rows = domain_rows()

    assert {:error, :authenticated_observation_rejected} =
             GrpcCompatibilityClient.status(connection, observe?: false)

    assert domain_rows() == revoked_rows
    assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]
    assert :ok = QueueManager.release(capacity_grant)
  end

  defp seed_capacity_source(node_id) do
    source = {:node, node_id, :cold}

    assert {:queued, ticket} =
             QueueManager.acquire(
               %{
                 request_id: Ecto.UUID.generate(),
                 public_id: "read-probe",
                 tenant_id: Ecto.UUID.generate(),
                 model_id: "read-probe",
                 version: "v1",
                 caller_pid: self()
               },
               config: [
                 enabled: true,
                 capacity: 0,
                 max_queued_per_tenant: 32,
                 max_wait_ms: 60_000
               ]
             )

    assert :ok = QueueManager.refresh_capacity("read-probe", "v1", 2, source: source)
    assert {:ok, grant} = QueueManager.await(ticket)
    assert QueueManager.active_capacity_source_lanes(source) == [{"read-probe", "v1"}]

    on_exit(fn ->
      QueueManager.release(grant)
      QueueManager.clear_capacity_source(source)
    end)

    {source, grant}
  end

  defp authenticated_grpc_connection!(peer) do
    assert {:ok, paths} = NodeTrust.runtime_client_generation_paths()
    enrollment = Repo.get!(Enrollment, peer.enrollment_id)
    certfile = Path.join(Path.dirname(paths.certfile), "status-node-cert.pem")
    keyfile = Path.join(Path.dirname(paths.certfile), "status-node-key.pem")
    File.write!(certfile, enrollment.certificate_result["node_certificate_pem"])
    File.write!(keyfile, Process.get({:node_private_key, peer.node_id}))
    File.chmod!(keyfile, 0o600)

    credential =
      GRPC.Credential.new(
        ssl: [
          certfile: certfile,
          keyfile: keyfile,
          cacertfile: paths.cacertfile,
          verify: :verify_peer,
          fail_if_no_peer_cert: true
        ]
      )

    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    start_supervised!(
      {GRPC.Server.Supervisor,
       endpoint: StatusEndpoint,
       port: port,
       start_server: true,
       adapter_opts: [ip: {127, 0, 0, 1}, cred: credential]}
    )

    node =
      Repo.get!(Node, peer.node_id)
      |> Ecto.Changeset.change(connect_host: "127.0.0.1", connect_port: port)
      |> Repo.update!()

    Application.put_env(:orchard_controller, :beam_peer_grants, enabled: false)
    assert {:ok, [target]} = Nodes.activation_probe_runtime_endpoint_targets()
    assert target.transport == :grpc_compat

    Application.put_env(
      :orchard_controller,
      :authenticated_grpc_status,
      %Orchard.Cluster.V1.StatusResponse{
        node_metadata: %Orchard.Cluster.V1.RuntimeNodeMetadata{
          node_id: node.id,
          display_name: node.display_name,
          hostname: node.hostname,
          listen_host: node.connect_host,
          listen_port: port
        },
        runtime_health: %Orchard.Cluster.V1.RuntimeHealth{ready: true},
        max_concurrency: 2
      }
    )

    assert {:ok, connection} = GrpcCompatibilityClient.connect(target)
    assert {:mutual_tls, _, ^peer} = connection.security
    on_exit(fn -> GrpcCompatibilityClient.disconnect(connection) end)
    connection
  end

  defp domain_rows do
    %{rows: tables} = Repo.query!("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")

    Map.new(tables, fn [table] ->
      quoted = String.replace(table, "\"", "\"\"")
      %{rows: rows} = Repo.query!(~s|SELECT to_jsonb(t) FROM "#{quoted}" t|)
      {table, Enum.sort(rows)}
    end)
  end

  test "prefix-cache scoring fails open when a BEAM target is unavailable" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: :definitely_missing@localhost)

    request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "unavailable"}} =
             BeamClient.score_prefix_cache(target, request, [])
  end

  test "SPEC.md §7.5.0 unavailable BEAM peers use the stable operator failure" do
    target = Target.beam(@node_id, address: :definitely_missing@localhost)

    connection = %BeamClient{
      authenticated_peer: nil,
      node: :definitely_missing@localhost,
      server_module: Server,
      target: target
    }

    assert {:error, :beam_node_unavailable} = BeamClient.status(connection, timeout: 100)
  end

  test "local BEAM server startup failures send dispatcher-safe completion" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: RaisingServer})
    assert {:ok, connection} = BeamClient.connect(target)

    request = %Operation.ExecuteRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      rendered_prompt_utf8: "hello",
      input_tokens: 1
    }

    assert {:ok, stream_ref} = BeamClient.execute_inference(connection, request, owner: self())

    assert_receive {:runtime_endpoint_done, ^stream_ref, {:error, :beam_rpc_failed}}
  end

  test "prefix-cache scoring fails open when a local BEAM server raises" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: RaisingServer})
    assert {:ok, connection} = BeamClient.connect(target)

    request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "error"}} =
             BeamClient.score_prefix_cache(connection, request, [])
  end

  test "issue #222 local BEAM ensure_model_loaded honors explicit timeout" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: SlowServer})
    assert {:ok, connection} = BeamClient.connect(target)

    request = %Operation.EnsureModelLoadedRequest{model_ref: model_ref}

    caller = self()

    client_pid =
      spawn(fn ->
        result = BeamClient.ensure_model_loaded(connection, request, timeout: 50)
        send(caller, {:beam_client_returned, self(), result})

        receive do
          {:report_messages, recipient} ->
            send(recipient, {:beam_client_messages, Process.info(self(), :messages)})
        end
      end)

    client_monitor = Process.monitor(client_pid)

    on_exit(fn ->
      if Process.alive?(client_pid), do: Process.exit(client_pid, :kill)
    end)

    assert_receive {:slow_server_started, wrapper_pid}, 1_000
    wrapper_monitor = Process.monitor(wrapper_pid)

    assert_receive {:beam_client_timeout_cleanup, ^client_pid, ^wrapper_pid, tag}, 1_000
    send(client_pid, {:result, tag, :late_result})
    send(client_pid, {:continue_timeout_cleanup, tag})

    assert_receive {:beam_client_returned, ^client_pid, {:error, :beam_node_timeout}}, 1_000
    assert_receive {:DOWN, ^wrapper_monitor, :process, ^wrapper_pid, :killed}, 1_000

    send(client_pid, {:report_messages, self()})

    assert_receive {:beam_client_messages, {:messages, messages}}, 1_000

    refute Enum.any?(messages, fn
             {:result, tag, _result} when is_reference(tag) -> true
             _message -> false
           end)

    assert_receive {:DOWN, ^client_monitor, :process, ^client_pid, :normal}, 1_000
  end

  defp beam_test_inventory do
    %Orchard.Cluster.V1.HostInventoryObservation{
      schema_version: 1,
      observed_at_unix_ms: 1_789_743_600_000,
      authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY,
      cpu: %Orchard.Cluster.V1.HostCpuObservation{architecture: "x86_64"}
    }
  end

  defp authenticated_beam_fixture! do
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)
    previous_node_trust = Application.get_env(:orchard_controller, :node_trust)

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-beam-client-issue-201-#{System.unique_integer([:positive, :monotonic])}"
      )

    trust_root = Path.join(root, "node-trust")
    authorization_root = Path.join(root, "beam-authorization-root")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)

    Application.put_env(:orchard_controller, :beam_peer_grants,
      enabled: true,
      authorization_root_path: authorization_root
    )

    on_exit(fn ->
      File.rm_rf!(root)
      restore_application_env(:control_plane, previous_control_plane)
      restore_application_env(:node_trust, previous_node_trust)
    end)

    now = DateTime.utc_now()
    assert {:ok, trust} = NodeTrust.initialize(root: trust_root, now: now)

    assert {:ok, _controller} =
             ControllerInstances.ensure_local(
               private_ipv4: "10.0.0.10",
               membership_scope: :remote_beam,
               node_trust_root: trust_root,
               authorization_root_path: authorization_root,
               now: now
             )

    node = register_authenticated_node!(trust, now)

    admission_attrs = %{
      trust_evidence_ref: "registration-audit:#{Ecto.UUID.generate()}",
      pool_id: Ecto.UUID.generate(),
      routing_policy_id: Ecto.UUID.generate(),
      capacity_policy_reason: "approved for issue #201 regression"
    }

    assert {:ok, %{grants: [grant]}} =
             Nodes.admit_node(node.id, admission_attrs, now: now)

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
    {target, peer}
  end

  defp register_authenticated_node!(trust, now) do
    assert {:ok, created} =
             NodeEnrollments.create(
               %{
                 cluster_id: trust.cluster_id,
                 expected_controller_id: trust.controller_id,
                 trust_authority_id: trust.trust_authority_id,
                 creator_type: "operator",
                 expires_at: DateTime.add(now, 1, :hour),
                 node: %{display_name: "beam-client-issue-201"}
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
                   host: "10.0.0.20",
                   hostname: "beam-client-issue-201.orchard.test",
                   port: 50_071
                 },
                 token: created.bootstrap_token
               },
               now: now
             )

    Repo.get!(Node, created.enrollment.node_id)
  end

  defp authenticated_peer!(node_id) do
    enrollment = Repo.one!(from(enrollment in Enrollment, where: enrollment.node_id == ^node_id))
    result = enrollment.certificate_result
    assert {:ok, certificate} = CertificateIdentity.from_pem(result["node_certificate_pem"])

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

  defp restore_application_env(key, nil),
    do: Application.delete_env(:orchard_controller, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:orchard_controller, key, value)

  defp put_beam_config(config) do
    Application.put_env(:orchard_controller, :runtime_endpoint, beam: config)
  end

  defp put_peer_grant_beam_config do
    put_beam_config(
      enabled: true,
      node_name: "orchard_controller_550e8400e29b41d4a716446655440000@10.0.0.5",
      cookie_file: nil,
      admitted_services: [],
      allowed_cidrs: [],
      listen_host: "10.0.0.5"
    )
  end

  defp restore_runtime_endpoint_config(nil) do
    Application.delete_env(:orchard_controller, :runtime_endpoint)
  end

  defp restore_runtime_endpoint_config(config) do
    Application.put_env(:orchard_controller, :runtime_endpoint, config)
  end

  defp restore_peer_grant_config(nil) do
    Application.delete_env(:orchard_controller, :beam_peer_grants)
  end

  defp restore_peer_grant_config(config) do
    Application.put_env(:orchard_controller, :beam_peer_grants, config)
  end
end
