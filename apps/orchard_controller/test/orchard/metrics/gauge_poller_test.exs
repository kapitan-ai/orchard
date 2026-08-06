defmodule Orchard.Metrics.GaugePollerTest.Source do
  @moduledoc false

  def snapshots(_now) do
    case Application.fetch_env!(:orchard_controller, :gauge_poller_test_snapshot) do
      {:raise, reason} -> raise inspect(reason)
      snapshot -> snapshot
    end
  end
end

defmodule Orchard.Metrics.GaugePollerTest do
  use Orchard.DataCase, async: false

  alias Orchard.DispatchCapacity.{AllocationAuthority, ConformanceFixture}
  alias Orchard.Governance.Tenant
  alias Orchard.Inference.QueueManager
  alias Orchard.Metrics.{GaugePoller, GaugeSnapshotStore, GaugeSource}
  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.Repo
  alias Orchard.Requests.Request

  @source Orchard.Metrics.GaugePollerTest.Source
  @families [
    :scheduler_queue_depth,
    :node_heartbeat_lag,
    :node_available_memory,
    :node_swap_used,
    :active_requests,
    :model_resident
  ]

  setup do
    previous_snapshot =
      Application.get_env(:orchard_controller, :gauge_poller_test_snapshot)

    Application.put_env(:orchard_controller, :gauge_poller_test_snapshot, %{
      scheduler_queue_depth: [],
      node_heartbeat_lag: [],
      node_available_memory: [],
      node_swap_used: [],
      active_requests: [],
      model_resident: []
    })

    restart_metrics_generation(gauge_source: @source, poll_interval_ms: 60_000)
    wait_until_polled()
    QueueManager.reset()

    on_exit(fn ->
      restore_env(:gauge_poller_test_snapshot, previous_snapshot)
    end)

    :ok
  end

  test "SPEC.md §9.1 telemetry poll replaces all six complete gauge families" do
    first = %{
      scheduler_queue_depth: [entry(%{tenant: "tenant-a"}, 2)],
      node_heartbeat_lag: [entry(%{node: "node-a"}, 3.0)],
      node_available_memory: [entry(%{node: "node-a"}, 1_024)],
      node_swap_used: [entry(%{node: "node-a"}, 0)],
      active_requests: [entry(%{node: "node-a", model: "model-a"}, 1)],
      model_resident: [entry(%{node: "node-a", model: "model-a"}, 1)]
    }

    Application.put_env(:orchard_controller, :gauge_poller_test_snapshot, first)
    assert :ok = GaugePoller.poll(source: @source, poll_interval_ms: 100)
    assert Map.keys(GaugeSnapshotStore.snapshots()) |> Enum.sort() == Enum.sort(@families)

    second = %{
      scheduler_queue_depth: [entry(%{tenant: "tenant-a"}, 0)],
      node_heartbeat_lag: [],
      node_available_memory: [],
      node_swap_used: [],
      active_requests: [entry(%{node: "node-a", model: "model-a"}, 0)],
      model_resident: [entry(%{node: "node-a", model: "model-a"}, 0)]
    }

    Application.put_env(:orchard_controller, :gauge_poller_test_snapshot, second)
    assert :ok = GaugePoller.poll(source: @source, poll_interval_ms: 100)

    snapshots = GaugeSnapshotStore.snapshots()
    assert snapshots.scheduler_queue_depth == [entry(%{tenant: "tenant-a"}, 0)]
    assert snapshots.node_heartbeat_lag == []
    assert snapshots.node_available_memory == []
    assert snapshots.node_swap_used == []
    assert snapshots.active_requests == [entry(%{node: "node-a", model: "model-a"}, 0)]
    assert snapshots.model_resident == [entry(%{node: "node-a", model: "model-a"}, 0)]
  end

  test "SPEC.md §9.1 source emits idle zeroes and omits unknown or stale memory and swap" do
    tenant = insert_tenant!()
    now = DateTime.utc_now()
    fresh_node = insert_node!(:active)
    stale_node = insert_node!(:active)
    removed_node = insert_node!(:removed)

    insert_heartbeat!(fresh_node, now,
      available_memory_bytes: nil,
      swap_used_bytes: 0,
      payload: payload("model-idle", "cached", nil)
    )

    insert_heartbeat!(stale_node, DateTime.add(now, -120, :second),
      available_memory_bytes: 2_048,
      swap_used_bytes: 512,
      payload: payload("model-loaded", "loaded", 2)
    )

    insert_heartbeat!(removed_node, now,
      available_memory_bytes: 4_096,
      swap_used_bytes: 0,
      payload: payload("model-removed", "loaded", 1)
    )

    snapshots = GaugeSource.snapshots(now)

    assert entry(%{tenant: tenant.id}, 0) in snapshots.scheduler_queue_depth

    assert Enum.sort(Enum.map(snapshots.node_heartbeat_lag, & &1.labels.node)) ==
             Enum.sort([fresh_node.id, stale_node.id])

    assert snapshots.node_available_memory == []
    assert snapshots.node_swap_used == [entry(%{node: fresh_node.id}, 0)]
    assert entry(%{node: fresh_node.id, model: "model-idle"}, 0) in snapshots.active_requests
    assert entry(%{node: fresh_node.id, model: "model-idle"}, 0) in snapshots.model_resident
    assert entry(%{node: stale_node.id, model: "model-loaded"}, 0) in snapshots.active_requests
    assert entry(%{node: stale_node.id, model: "model-loaded"}, 1) in snapshots.model_resident

    refute Enum.any?(Map.values(snapshots), fn entries ->
             Enum.any?(entries, &(Map.get(&1.labels, :node) == removed_node.id))
           end)
  end

  test "SPEC.md §9.1 active requests use Controller dispatch claims and retain idle zeroes" do
    tenant = insert_tenant!()
    node = insert_node!(:active)
    public_id = "metrics-active-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    insert_heartbeat!(node, now, payload: payload("model-authoritative", "loaded", 7))
    insert_request!(tenant, public_id, "model-authoritative@v1")

    assert {:ok, claim, _evaluation} =
             AllocationAuthority.acquire(node.id, public_id, ConformanceFixture.input())

    assert GaugeSource.snapshots(now).active_requests == [
             entry(%{node: node.id, model: "model-authoritative"}, 1)
           ]

    assert :ok = AllocationAuthority.release(claim)

    assert GaugeSource.snapshots(now).active_requests == [
             entry(%{node: node.id, model: "model-authoritative"}, 0)
           ]
  end

  test "SPEC.md §9.1 an unavailable queue authority fails only the family it owns" do
    node = insert_node!(:active)
    now = DateTime.utc_now()
    insert_heartbeat!(node, now, payload: payload("model-a", "loaded", 1))

    manager = Process.whereis(QueueManager)
    :ok = :sys.suspend(manager)

    on_exit(fn ->
      if Process.alive?(manager), do: :sys.resume(manager)
    end)

    snapshots = GaugeSource.snapshots(now)

    refute Map.has_key?(snapshots, :scheduler_queue_depth)
    assert Enum.any?(snapshots.node_heartbeat_lag, &(&1.labels.node == node.id))
    assert entry(%{node: node.id, model: "model-a"}, 1) in snapshots.model_resident
    assert Map.has_key?(snapshots, :active_requests)

    assert :ok = GaugePoller.poll(source: GaugeSource, poll_interval_ms: 1_000)

    assert Enum.any?(
             GaugeSnapshotStore.snapshots().node_heartbeat_lag,
             &(&1.labels.node == node.id)
           )

    :ok = :sys.resume(manager)
  end

  test "SPEC.md §9.1 poll failure is isolated and expires retained gauges after two intervals" do
    snapshot =
      Map.new(@families, fn family ->
        entries =
          case family do
            :scheduler_queue_depth -> [entry(%{tenant: "tenant-a"}, 1)]
            :node_heartbeat_lag -> [entry(%{node: "node-a"}, 1)]
            :node_available_memory -> [entry(%{node: "node-a"}, 1)]
            :node_swap_used -> [entry(%{node: "node-a"}, 1)]
            :active_requests -> [entry(%{node: "node-a", model: "model-a"}, 1)]
            :model_resident -> [entry(%{node: "node-a", model: "model-a"}, 1)]
          end

        {family, entries}
      end)

    Application.put_env(:orchard_controller, :gauge_poller_test_snapshot, snapshot)
    assert :ok = GaugePoller.poll(source: @source, poll_interval_ms: 30)

    Application.put_env(:orchard_controller, :gauge_poller_test_snapshot, {:raise, :offline})
    assert :ok = GaugePoller.poll(source: @source, poll_interval_ms: 30)
    assert Map.keys(GaugeSnapshotStore.snapshots()) |> Enum.sort() == Enum.sort(@families)

    Process.sleep(80)
    assert GaugeSnapshotStore.snapshots() == %{}
  end

  defp entry(labels, value), do: %{labels: labels, value: value}

  defp insert_tenant! do
    unique = System.unique_integer([:positive])

    %Tenant{}
    |> Tenant.changeset(%{slug: "metrics-#{unique}", name: "Metrics #{unique}"})
    |> Repo.insert!()
  end

  defp insert_request!(tenant, public_id, requested_model) do
    %Request{}
    |> Request.create_changeset(%{
      public_id: public_id,
      endpoint: :responses,
      tenant_id: tenant.id,
      requested_model: requested_model,
      state: :dispatching,
      stream: false,
      payload_capture_mode: :none
    })
    |> Repo.insert!()
  end

  defp insert_node!(state) do
    unique = System.unique_integer([:positive])
    address = "10.90.0.#{rem(unique, 200) + 1}"

    %Node{}
    |> Node.changeset(%{
      hostname: "metrics-#{unique}.local",
      display_name: "metrics-node-#{unique}",
      advertise_addr: address,
      rpc_port: 50_071,
      connect_host: address,
      connect_port: 50_071,
      state: state,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp insert_heartbeat!(node, observed_at, attrs) do
    defaults = %{
      node_id: node.id,
      observed_at: observed_at,
      health: :healthy,
      active_requests: 0,
      payload: %{}
    }

    %NodeHeartbeat{}
    |> NodeHeartbeat.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  defp payload(model, state, active_requests) do
    %{
      "validity" => "valid",
      "placements" => [
        %{
          "model_ref" => %{"model_id" => model, "version" => "v1"},
          "state" => state,
          "capacity" => %{"active_request_count" => active_requests}
        }
      ]
    }
  end

  defp restart_metrics_generation(opts) do
    case Process.whereis(Orchard.Metrics.Supervisor) do
      nil ->
        :ok

      pid ->
        Supervisor.stop(pid)
        wait_until_stopped(Orchard.Metrics.Supervisor)
    end

    start_supervised!({Orchard.Metrics.Supervisor, opts})
  end

  defp wait_until_polled do
    if map_size(GaugeSnapshotStore.snapshots()) == 6 do
      :ok
    else
      Process.sleep(5)
      wait_until_polled()
    end
  end

  defp wait_until_stopped(name) do
    if Process.whereis(name) == nil do
      :ok
    else
      Process.sleep(5)
      wait_until_stopped(name)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
