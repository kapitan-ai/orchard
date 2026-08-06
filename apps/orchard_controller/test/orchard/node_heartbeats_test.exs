defmodule Orchard.NodeHeartbeatsTest do
  use Orchard.DataCase, async: false

  alias Orchard.Inference.QueueManager
  alias Orchard.NodeHeartbeats
  alias Orchard.NodeHeartbeats.Payload
  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.RuntimeEndpoint.{Observation, Target}

  setup do
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)

    previous_max_bytes =
      Application.get_env(:orchard_controller, :node_heartbeat_payload_max_bytes)

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)
    Application.put_env(:orchard_controller, :node_heartbeat_payload_max_bytes, 262_144)

    on_exit(fn ->
      restore_env(:control_plane, previous_control_plane)
      restore_env(:node_heartbeat_payload_max_bytes, previous_max_bytes)
    end)

    :ok
  end

  test "ADR 0017 schema-v1 payload is closed, bounded, and excludes sensitive fields" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071, node_id: node_id)
    fingerprint = "hmac-sha256:" <> String.duplicate("a", 64)

    observation = %{
      endpoint_id: String.duplicate("e", 700),
      availability: :available,
      worker_state: :idle,
      aggregate_active_request_count: 2,
      aggregate_max_concurrency: 4,
      placements:
        Enum.map(1..40, fn index ->
          %{
            model_ref: %{
              model_id: "model-#{index}-" <> String.duplicate("m", 200),
              version: "version-" <> String.duplicate("v", 100)
            },
            state: :loaded,
            capacity: %{
              active_request_count: 1,
              max_concurrency: 2,
              source: String.duplicate("s", 120)
            },
            last_used_at: ~U[2026-08-03 08:00:00.000000Z],
            diagnostics: %{api_token: "placement-secret"}
          }
        end),
      runtime_memory_budgets: [
        %{
          model_ref: "model@v1",
          mode: String.duplicate("x", 80),
          budget_available: true,
          headroom_available: true,
          status_code: "ok",
          status_message: String.duplicate("m", 400),
          source: String.duplicate("s", 100),
          target_working_set_bytes: 1_024,
          dsn: "postgres://secret"
        }
      ],
      worker_crash_counters: [
        %{model_id: "model-a", count: 2, counter_version: "epoch-1"},
        %{model_id: "model-b", count: 3, counter_version: "epoch-1"},
        %{model_id: "model-c", count: 4, counter_version: "epoch-1"},
        %{model_id: "model-d", count: 5, counter_version: "epoch-1"},
        %{model_id: "model-e", count: 6, counter_version: "epoch-1"}
      ],
      runtime_prefix_cache_statuses: [
        %{
          model_ref: "model@v1",
          implementation: "mlx",
          enabled: true,
          entry_count: 1,
          total_bytes: 512,
          hits: 3,
          misses: 1,
          status_code: "ok",
          prefix_cache_fingerprints: [fingerprint],
          api_key: "prefix-secret"
        }
      ],
      supports_prompt_token_ids: true,
      credentials: "top-secret",
      tenant_id: Ecto.UUID.generate(),
      prompt: "private prompt",
      response: "private response",
      metadata: %{session_id: "tool-session"}
    }

    payload = Payload.build(target, observation, node_id: node_id)

    assert Map.keys(payload) |> Enum.sort() ==
             ~w(
               aggregate_active_request_count
               aggregate_capacity_evidence
               aggregate_max_concurrency
               availability
               endpoint_id
               placements
               runtime_memory_budgets
               runtime_prefix_cache_statuses
               schema_version
               supports_prompt_token_ids
               target
               validity
               worker_crash_counters
               worker_state
             )

    assert payload["schema_version"] == 1
    assert payload["validity"] == "valid"
    assert payload["supports_prompt_token_ids"] == true
    assert byte_size(payload["endpoint_id"]) == 512
    assert length(payload["placements"]) == 40

    assert Enum.map(payload["worker_crash_counters"], & &1["model_id"]) ==
             ~w(model-a model-b model-c model-d)

    assert Enum.all?(payload["worker_crash_counters"], fn counter ->
             Map.keys(counter) |> Enum.sort() == ~w(count counter_version model_id)
           end)

    assert String.length(get_in(payload, ["placements", Access.at(0), "model_ref", "model_id"])) +
             String.length(get_in(payload, ["placements", Access.at(0), "model_ref", "version"])) +
             1 <= 160

    memory_budget = payload["runtime_memory_budgets"] |> List.first()
    assert memory_budget["budget_available"] == true
    assert memory_budget["headroom_available"] == true

    prefix_status = payload["runtime_prefix_cache_statuses"] |> List.first()
    assert prefix_status["enabled"] == true
    assert prefix_status["prefix_cache_fingerprint_count"] == 1
    assert prefix_status["prefix_cache_warmth_indicator"] == true
    refute Map.has_key?(prefix_status, "prefix_cache_fingerprints")

    encoded = Jason.encode!(payload)
    refute encoded =~ "top-secret"
    refute encoded =~ "placement-secret"
    refute encoded =~ "postgres://secret"
    refute encoded =~ "prefix-secret"
    refute encoded =~ fingerprint
    refute encoded =~ "private prompt"
    refute encoded =~ "private response"
    refute encoded =~ "tool-session"
    refute encoded =~ "tenant_id"
    refute encoded =~ "acquirable"
    refute encoded =~ "authority"
  end

  test "ADR 0017 unsupported, malformed, and oversize inputs produce stable minimal invalid envelopes" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071, node_id: node_id)

    assert Payload.build(target, %{}, node_id: node_id, schema_version: 2) ==
             Payload.invalid(:unsupported_schema_version)

    assert Payload.build(:not_a_target, %{}, node_id: node_id) ==
             Payload.invalid(:malformed_required_envelope)

    Application.put_env(:orchard_controller, :node_heartbeat_payload_max_bytes, 256)

    assert Payload.build(
             target,
             %{
               endpoint_id: "endpoint",
               placements:
                 Enum.map(1..40, fn index ->
                   %{
                     model_ref: %{model_id: "model-#{index}", version: "v1"},
                     state: :loaded
                   }
                 end)
             },
             node_id: node_id
           ) == Payload.invalid(:payload_too_large)
  end

  test "ADR 0017 rejects placement overflow and duplicate model references before capping" do
    node_id = Ecto.UUID.generate()
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071, node_id: node_id)

    unique_placements =
      Enum.map(1..41, fn index ->
        %{model_ref: %{model_id: "model-#{index}", version: "v1"}, state: :loaded}
      end)

    assert Payload.build(target, %{placements: unique_placements}, node_id: node_id) ==
             Payload.invalid(:placement_entry_overflow)

    duplicate_after_limit =
      Enum.map(1..40, fn index ->
        %{model_ref: %{model_id: "model-#{index}", version: "v1"}, state: :loaded}
      end) ++
        [%{model_ref: %{model_id: "model-1", version: "v1"}, state: :loaded}]

    assert Payload.build(target, %{placements: duplicate_after_limit}, node_id: node_id) ==
             Payload.invalid(:duplicate_placement_model_ref)
  end

  test "ADR 0017 payload cap configuration rejects values too small for the invalid envelope" do
    Application.put_env(:orchard_controller, :node_heartbeat_payload_max_bytes, 127)

    assert_raise ArgumentError, ~r/must be an integer >= 128/, fn ->
      Payload.max_bytes!()
    end
  end

  test "ADR 0017 authenticated heartbeat append requires leader transaction and target identity" do
    node = insert_node!()

    target =
      Target.grpc_compat(host: node.connect_host, port: node.connect_port, node_id: node.id)

    observation = %{endpoint_id: target.id, active_request_count: 0, max_concurrency: 1}
    observed_at = ~U[2026-08-03 08:00:00.000000Z]

    assert {:error, :heartbeat_transaction_required} =
             NodeHeartbeats.append(node, target, observation, observed_at)

    mismatched_target = %{target | node_id: Ecto.UUID.generate()}

    assert {:error, :heartbeat_target_identity_mismatch} =
             append_heartbeat(node, mismatched_target, observation, observed_at)

    assert Repo.aggregate(NodeHeartbeat, :count) == 0

    Application.put_env(:orchard_controller, :control_plane, role: :standby)

    assert {:error, :controller_standby} =
             append_heartbeat(node, target, observation, observed_at)

    assert Repo.aggregate(NodeHeartbeat, :count) == 0
  end

  test "SPEC §8 dedicated host telemetry stays nil when the current observation vocabulary lacks it" do
    observed_at = ~U[2026-08-03 08:00:00.000000Z]
    node = insert_node!()

    target =
      Target.grpc_compat(host: node.connect_host, port: node.connect_port, node_id: node.id)

    observation =
      Observation.new(%{
        endpoint_id: target.id,
        target: target,
        observed_at: observed_at,
        availability: :available,
        worker_state: :idle,
        aggregate_active_request_count: 2,
        aggregate_max_concurrency: 4,
        runtime_memory_budgets: [
          %{
            model_ref: %{model_id: "model", version: "v1"},
            estimated_headroom_bytes: 4_096
          }
        ]
      })

    refute Map.has_key?(Map.from_struct(observation), :available_memory_bytes)
    refute Map.has_key?(Map.from_struct(observation), :swap_used_bytes)
    refute Map.has_key?(Map.from_struct(observation), :cpu_load_1m)
    refute Map.has_key?(Map.from_struct(observation), :thermal_pressure)

    assert {:ok, heartbeat} = append_heartbeat(node, target, observation, observed_at)

    assert %NodeHeartbeat{
             available_memory_bytes: nil,
             swap_used_bytes: nil,
             cpu_load_1m: nil,
             thermal_pressure: nil,
             active_requests: 2
           } = Repo.reload!(heartbeat)
  end

  test "SPEC §8.5 retention deletes only heartbeat rows older than seven days" do
    now = ~U[2026-08-03 08:00:00.000000Z]
    node = insert_node!()

    target =
      Target.grpc_compat(host: node.connect_host, port: node.connect_port, node_id: node.id)

    observation = %{endpoint_id: target.id, active_request_count: 0, max_concurrency: 1}

    {:ok, expired} =
      append_heartbeat(
        node,
        target,
        observation,
        DateTime.add(now, -(7 * 24 * 60 * 60 + 1), :second)
      )

    {:ok, boundary} =
      append_heartbeat(
        node,
        target,
        observation,
        DateTime.add(now, -(7 * 24 * 60 * 60), :second)
      )

    {:ok, current} = append_heartbeat(node, target, observation, now)

    assert NodeHeartbeat.__schema__(:type, :id) == :id
    assert NodeHeartbeat.__schema__(:type, :node_id) == :binary_id
    assert is_integer(current.id)

    assert {:ok, 1} = NodeHeartbeats.prune_expired(now)
    refute Repo.get(NodeHeartbeat, expired.id)
    assert Repo.get(NodeHeartbeat, boundary.id)
    assert Repo.get(NodeHeartbeat, current.id)
  end

  test "SPEC §8.5 retention prunes a deterministic bounded backlog over later calls" do
    now = ~U[2026-08-03 08:00:00.000000Z]
    cutoff = DateTime.add(now, -(7 * 24 * 60 * 60), :second)
    node = insert_node!()
    batch_size = 1_000
    oldest = DateTime.add(cutoff, -(batch_size + 10), :second)

    rows =
      Enum.map(0..batch_size, fn offset ->
        %{
          node_id: node.id,
          observed_at: DateTime.add(oldest, offset, :second),
          health: :healthy,
          active_requests: 0,
          payload: %{}
        }
      end)

    assert {batch_count, nil} = Repo.insert_all(NodeHeartbeat, rows)
    assert batch_count == batch_size + 1

    assert {:ok, ^batch_size} = NodeHeartbeats.prune_expired(now)

    assert [%NodeHeartbeat{observed_at: remaining_at}] =
             Repo.all(
               from(heartbeat in NodeHeartbeat,
                 where: heartbeat.observed_at < ^cutoff,
                 order_by: [asc: heartbeat.observed_at, asc: heartbeat.id]
               )
             )

    assert remaining_at == DateTime.add(oldest, batch_size, :second)
    assert {:ok, 1} = NodeHeartbeats.prune_expired(now)
    assert Repo.aggregate(NodeHeartbeat, :count) == 0
  end

  test "ADR 0017 persisted history does not replay Node queue sources after restart" do
    node = insert_node!()

    target =
      Target.grpc_compat(host: node.connect_host, port: node.connect_port, node_id: node.id)

    assert {:ok, _heartbeat} =
             append_heartbeat(
               node,
               target,
               %{endpoint_id: target.id, active_request_count: 0, max_concurrency: 1},
               DateTime.utc_now()
             )

    manager =
      Module.concat(__MODULE__, "QueueManager#{System.unique_integer([:positive, :monotonic])}")

    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})
    source = {:node, node.id, :cold}

    assert :ok = QueueManager.refresh_capacity("model", "v1", 0, server: manager)

    assert :ok =
             QueueManager.refresh_capacity_sources(
               [{source, 1, [{"model", "v1", 1}]}],
               server: manager
             )

    assert Map.has_key?(:sys.get_state(manager).capacity_source_limits, source)

    Process.exit(manager_pid, :kill)

    assert wait_until(fn ->
             case Process.whereis(manager) do
               pid when is_pid(pid) -> pid != manager_pid
               nil -> false
             end
           end)

    assert Repo.aggregate(NodeHeartbeat, :count) == 1
    refute Map.has_key?(:sys.get_state(manager).capacity_source_limits, source)
  end

  defp append_heartbeat(node, target, observation, observed_at) do
    case Repo.transaction(fn ->
           NodeHeartbeats.append(node, target, observation, observed_at)
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_node! do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      hostname: "heartbeat-#{unique}.local",
      display_name: "heartbeat-node-#{unique}",
      advertise_addr: "10.88.0.#{rem(unique, 200) + 1}",
      rpc_port: 50_071,
      connect_host: "10.88.0.#{rem(unique, 200) + 1}",
      connect_port: 50_071,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp wait_until(fun, attempts \\ 150)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
