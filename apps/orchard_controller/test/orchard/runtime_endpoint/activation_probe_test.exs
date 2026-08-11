defmodule Orchard.RuntimeEndpoint.ActivationProbeTest do
  use Orchard.DataCase, async: false

  alias Orchard.Inference
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, Node, NodeHeartbeat}
  alias Orchard.RuntimeEndpoint.ActivationProbe
  alias Orchard.RuntimeEndpoint.{Observation, Target}

  defmodule FailingClient do
    def connect(_target), do: {:error, :authenticated_transport_failed}
    def disconnect(_connection), do: :ok
    def status(_connection, _opts), do: {:error, :authenticated_transport_failed}
  end

  defmodule RejectingClient do
    def connect(target), do: {:ok, %{target: target}}
    def disconnect(_connection), do: :ok

    def status(_connection, _opts), do: {:error, :authenticated_observation_rejected}
  end

  defmodule IdleClient do
    def connect(target), do: {:ok, %{target: target}}
    def disconnect(_connection), do: :ok
    def status(_connection, _opts), do: {:ok, %{}}
  end

  defmodule DiscoveryClient do
    def connect(target), do: {:ok, %{target: target}}
    def disconnect(_connection), do: :ok

    def status(%{target: target}, _opts) do
      node_id = Process.get(:activation_probe_discovery_node_id)

      {:ok,
       Observation.new(%{
         endpoint_id: target.id,
         target: target,
         availability: :available,
         aggregate_active_request_count: 0,
         aggregate_max_concurrency: 1,
         metadata: %{
           node_id: node_id,
           display_name: "discovered-beam",
           hostname: "discovered-beam.local",
           listen_host: "127.0.0.1",
           listen_port: 50_071
         },
         health: %{ready: true},
         placements: []
       })}
    end
  end

  defmodule RaisingHeartbeatContext do
    def prune_expired(_observed_at), do: raise("retention unavailable")
  end

  setup do
    previous = Application.get_env(:orchard_controller, :activation_probe, [])

    Application.put_env(
      :orchard_controller,
      :activation_probe,
      Keyword.merge(previous,
        allowed_clients: [FailingClient, RejectingClient, IdleClient, DiscoveryClient],
        interval_ms: 5_000
      )
    )

    on_exit(fn ->
      if previous == [] do
        Application.delete_env(:orchard_controller, :activation_probe)
      else
        Application.put_env(:orchard_controller, :activation_probe, previous)
      end
    end)

    :ok
  end

  test "SPEC.md §4.5 probe interval is strictly below freshness and unreachable thresholds" do
    assert ActivationProbe.interval_ms() == 5_000
    assert :ok = ActivationProbe.assert_interval_contract!(5_000)

    assert_raise ArgumentError, ~r/unreachable/, fn ->
      ActivationProbe.assert_interval_contract!(15_000)
    end

    previous = Application.get_env(:orchard_controller, :inference, [])

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous || [],
        node_unreachable_threshold_ms: 40_000,
        node_freshness_threshold_ms: 30_000
      )
    )

    on_exit(fn ->
      if previous in [nil, []] do
        Application.delete_env(:orchard_controller, :inference)
      else
        Application.put_env(:orchard_controller, :inference, previous)
      end
    end)

    assert_raise ArgumentError, ~r/freshness/, fn ->
      ActivationProbe.assert_interval_contract!(30_000)
    end
  end

  test "SPEC.md §4.5 misconfigured interval clamps at init instead of blocking Controller boot" do
    assert {:ok, pid} = start_supervised({ActivationProbe, interval: 60_000})

    assert %{interval: interval} = :sys.get_state(pid)
    assert interval < Inference.node_unreachable_threshold_ms()
    assert interval < Inference.node_freshness_threshold_ms()
    assert :ok = ActivationProbe.assert_interval_contract!(interval)
  end

  test "SPEC.md §4.5 clamped interval never drops below the busy-loop floor" do
    previous = Application.get_env(:orchard_controller, :inference, [])

    on_exit(fn ->
      if previous in [nil, []] do
        Application.delete_env(:orchard_controller, :inference)
      else
        Application.put_env(:orchard_controller, :inference, previous)
      end
    end)

    put_unreachable_threshold!(previous, 3_000)

    assert {:ok, tight} = start_supervised({ActivationProbe, interval: 60_000})
    assert %{interval: 1_500} = :sys.get_state(tight)
    assert :ok = stop_supervised(ActivationProbe)

    put_unreachable_threshold!(previous, 15)

    assert {:ok, pathological} = start_supervised({ActivationProbe, interval: 60_000})
    assert %{interval: 5_000} = :sys.get_state(pathological)
  end

  test "SPEC.md §4.5 transport failure during probe demotes active node" do
    hb_time = DateTime.utc_now()

    node =
      insert_active_node!(%{
        advertise_addr: "10.0.1.10",
        rpc_port: 9444,
        connect_host: "10.0.1.10",
        connect_port: 9444,
        last_heartbeat_at: hb_time,
        health: :healthy
      })

    target =
      Target.grpc_compat(
        host: "10.0.1.10",
        port: 9444,
        node_id: node.id,
        metadata: %{authorization: :inference_dispatch, source: :trusted_node_inventory}
      )

    observed_at = DateTime.add(hb_time, 5, :second)

    assert {:ok, []} =
             ActivationProbe.run_once(
               client: FailingClient,
               timeout: 50,
               observed_at: observed_at,
               targets: [target]
             )

    assert Repo.get!(Node, node.id).health == :degraded
    assert Repo.aggregate(NodeHeartbeat, :count) == 0
  end

  test "SPEC.md §4.5 seam rejection during probe does not demote" do
    hb_time = DateTime.utc_now()

    node =
      insert_active_node!(%{
        advertise_addr: "10.0.1.11",
        rpc_port: 9444,
        connect_host: "10.0.1.11",
        connect_port: 9444,
        last_heartbeat_at: hb_time,
        health: :healthy
      })

    target =
      Target.grpc_compat(
        host: "10.0.1.11",
        port: 9444,
        node_id: node.id,
        metadata: %{authorization: :inference_dispatch, source: :trusted_node_inventory}
      )

    assert {:ok, []} =
             ActivationProbe.run_once(
               client: RejectingClient,
               timeout: 50,
               observed_at: DateTime.add(hb_time, 5, :second),
               targets: [target]
             )

    reloaded = Repo.get!(Node, node.id)
    assert reloaded.health == :healthy
    assert Repo.aggregate(NodeHeartbeat, :count) == 0
  end

  test "SPEC.md §8.5 retention failure cannot interrupt the leader probe seam" do
    assert {:ok, []} =
             ActivationProbe.run_once(
               client: IdleClient,
               heartbeat_context: RaisingHeartbeatContext,
               targets: []
             )
  end

  test "SPEC.md §4.5 standby controller run_once writes nothing" do
    previous = Application.get_env(:orchard_controller, :control_plane, [])

    Application.put_env(
      :orchard_controller,
      :control_plane,
      Keyword.put(previous || [], :role, :standby)
    )

    on_exit(fn ->
      if previous in [nil, []] do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous)
      end
    end)

    assert {:error, :controller_standby} =
             ActivationProbe.run_once(client: IdleClient, timeout: 50)

    assert Nodes.sweep_stale_node_heartbeats() == :noop
  end

  test "issue #192 configured discovery bootstrap creates pending_observed candidate" do
    node_id = Ecto.UUID.generate()
    Process.put(:activation_probe_discovery_node_id, node_id)

    target =
      Target.normalize(%{
        transport: :beam,
        address: :"orchard_node_agent@192.168.88.9",
        metadata: %{source_dev: true}
      })

    assert Repo.aggregate(Node, :count) == 0
    assert Nodes.list_admission_candidates() == []

    assert {:ok, [%{target_id: target_id, status: :observed}]} =
             ActivationProbe.run_once(
               client: DiscoveryClient,
               timeout: 50,
               targets: [],
               discovery_targets: [target]
             )

    assert target_id == target.id
    assert Repo.get(Node, node_id) == nil

    assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
    assert candidate.admission_category == :pending_observed
    assert candidate.endpoint_transport == :beam
    assert candidate.endpoint_target == "orchard_node_agent@192.168.88.9"
    assert candidate.target_ref == "orchard_node_agent@192.168.88.9"
    assert candidate.observed_identity["claimed_node_id"] == node_id
  end

  test "issue #192 discovery failures do not invent node demotion rows" do
    target =
      Target.normalize(%{
        transport: :beam,
        address: :"orchard_node_agent@192.168.88.10",
        metadata: %{source_dev: true}
      })

    assert {:ok, []} =
             ActivationProbe.run_once(
               client: FailingClient,
               timeout: 50,
               targets: [],
               discovery_targets: [target]
             )

    assert Repo.aggregate(Node, :count) == 0
    assert Nodes.list_admission_candidates() == []
  end

  test "issue #192 gRPC compatibility discovery stays ephemeral" do
    node_id = Ecto.UUID.generate()
    Process.put(:activation_probe_discovery_node_id, node_id)

    target =
      Target.grpc_compat(
        host: "10.0.0.42",
        port: 50_071,
        metadata: %{source_dev: true}
      )

    assert {:ok, [%{target_id: target_id, status: :observed}]} =
             ActivationProbe.run_once(
               client: DiscoveryClient,
               timeout: 50,
               targets: [],
               discovery_targets: [target]
             )

    assert target_id == target.id
    assert Repo.get(Node, node_id) == nil
    assert Nodes.list_admission_candidates() == []
  end

  test "issue #192 binary and atom BEAM addresses normalize to one candidate identity" do
    node_id = Ecto.UUID.generate()
    Process.put(:activation_probe_discovery_node_id, node_id)

    atom_target =
      Target.normalize(%{
        transport: :beam,
        address: :"orchard_node_agent@10.0.0.9",
        metadata: %{source_dev: true}
      })

    binary_target =
      Target.normalize(%{
        transport: :beam,
        address: "orchard_node_agent@10.0.0.9",
        metadata: %{source_dev: true}
      })

    assert {:ok, [%{status: :observed}]} =
             ActivationProbe.run_once(
               client: DiscoveryClient,
               timeout: 50,
               targets: [],
               discovery_targets: [atom_target]
             )

    assert {:ok, [%{status: :observed}]} =
             ActivationProbe.run_once(
               client: DiscoveryClient,
               timeout: 50,
               targets: [],
               discovery_targets: [binary_target],
               observed_at: DateTime.add(DateTime.utc_now(), 1, :second)
             )

    assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
    assert candidate.endpoint_target == "orchard_node_agent@10.0.0.9"
    assert candidate.target_ref == "orchard_node_agent@10.0.0.9"
    assert Repo.get(Node, node_id) == nil
  end

  test "issue #192 discovery does not mutate existing registered placeholder nodes" do
    node_id = Ecto.UUID.generate()
    Process.put(:activation_probe_discovery_node_id, node_id)

    node =
      insert_active_node!(%{
        id: node_id,
        state: :registered,
        display_name: "registered-placeholder",
        hostname: "registered-placeholder.local",
        advertise_addr: "10.0.1.20",
        rpc_port: 9444,
        connect_host: "10.0.1.20",
        connect_port: 9444,
        health: :unreachable,
        last_heartbeat_at: nil
      })

    # insert_active_node! forces active; rewrite to registered placeholder shape.
    node =
      node
      |> Ecto.Changeset.change(%{state: :registered, health: :unreachable})
      |> Repo.update!()

    target =
      Target.normalize(%{
        transport: :beam,
        address: :"orchard_node_agent@192.168.88.9",
        metadata: %{source_dev: true}
      })

    assert {:ok, [%{status: :observed}]} =
             ActivationProbe.run_once(
               client: DiscoveryClient,
               timeout: 50,
               targets: [],
               discovery_targets: [target]
             )

    reloaded = Repo.get!(Node, node.id)
    assert reloaded.state == :registered
    assert reloaded.display_name == "registered-placeholder"
    assert reloaded.advertise_addr == "10.0.1.20"
    assert reloaded.health == :unreachable

    assert [%AdmissionCandidate{} = candidate] = Nodes.list_admission_candidates()
    assert candidate.endpoint_target == "orchard_node_agent@192.168.88.9"
    assert candidate.observed_identity["claimed_node_id"] == node_id
  end

  defp put_unreachable_threshold!(previous, threshold_ms) do
    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous || [], node_unreachable_threshold_ms: threshold_ms)
    )
  end

  defp insert_active_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "probe-host-#{unique}.local",
          display_name: "probe-node-#{unique}",
          advertise_addr: "10.20.#{rem(unique, 200)}.#{rem(unique, 200) + 1}",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          capabilities: %{},
          tool_readiness: %{}
        },
        overrides
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end
end
