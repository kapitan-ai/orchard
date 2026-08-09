defmodule Orchard.NodeHeartbeats.CandidateSnapshotTest do
  use Orchard.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.NodeHeartbeats
  alias Orchard.NodeHeartbeats.CandidateSnapshot.{Candidate, Rejection}
  alias Orchard.NodeHeartbeats.Payload
  alias Orchard.Nodes
  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.RuntimeEndpoint.{Placement, Target}

  @now ~U[2026-08-03 12:00:00.000000Z]
  @freshness_ms 30_000

  defmodule FailingRepo do
    @moduledoc false
    def all(_query), do: {:error, :database_unavailable}
  end

  defmodule IncompleteRepo do
    @moduledoc false
    def all(_query), do: []
  end

  defmodule RaisingRepo do
    @moduledoc false
    def all(_query), do: raise("database read failed")
  end

  defmodule ExitingRepo do
    @moduledoc false
    def all(_query), do: exit(:database_read_failed)
  end

  defmodule BarrierRepo do
    @moduledoc false
    @owner_key {__MODULE__, :owner}

    def configure(owner), do: :persistent_term.put(@owner_key, owner)
    def clear, do: :persistent_term.erase(@owner_key)

    def all(query) do
      owner = :persistent_term.get(@owner_key)
      send(owner, {:candidate_snapshot_query_ready, self()})

      receive do
        :continue_candidate_snapshot_query -> Orchard.Repo.all(query)
      after
        2_000 -> raise "candidate snapshot query barrier timed out"
      end
    end
  end

  defmodule MalformedBoundaryRepo do
    @moduledoc false

    def all(query) do
      Enum.map(Orchard.Repo.all(query), fn {node, heartbeat, _observed_at} ->
        {node, heartbeat, "invalid-boundary"}
      end)
    end
  end

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(previous_inference, :node_freshness_threshold_ms, @freshness_ms)
    )

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      restore_env(:control_plane, previous_control_plane)
    end)

    :ok
  end

  test "ADR 0017 returns typed normalized evidence for the exact production intersection" do
    node = insert_node!()
    target = target_for(node)
    fingerprint = "hmac-sha256:" <> String.duplicate("a", 64)

    heartbeat =
      append_heartbeat!(node, target, @now, %{
        aggregate_active_request_count: 2,
        aggregate_max_concurrency: 4,
        worker_state: :busy,
        placements: [
          %{
            model_ref: %{model_id: "orchard/model", version: "v1"},
            state: :loaded,
            capacity: %{active_request_count: 1, max_concurrency: 3, source: :runtime}
          }
        ],
        runtime_memory_budgets: [
          %{
            model_ref: "orchard/model@v1",
            mode: "mlx",
            budget_available: true,
            headroom_available: true,
            status_code: "ok",
            estimated_headroom_bytes: 4_096
          }
        ],
        runtime_prefix_cache_statuses: [
          %{
            model_ref: "orchard/model@v1",
            implementation: "mlx",
            enabled: true,
            entry_count: 1,
            status_code: "ok",
            prefix_cache_fingerprints: [fingerprint]
          }
        ],
        supports_prompt_token_ids: true
      })

    assert {:ok, snapshot} =
             NodeHeartbeats.production_candidate_snapshot(
               [Target.normalize(target)],
               [target],
               observed_at: @now
             )

    assert snapshot.observed_at == @now
    assert snapshot.freshness_threshold_ms == @freshness_ms
    assert snapshot.rejections == []

    assert [
             %Candidate{
               target: ^target,
               node: %Node{id: node_id, state: :active, health: :healthy},
               heartbeat_id: heartbeat_id,
               observed_at: @now,
               availability: :available,
               worker_state: :busy,
               active_request_count: 2,
               max_concurrency: 4,
               aggregate_capacity_evidence: %{
                 active_request_count: 2,
                 runtime_concurrency_limit: 4,
                 validity: :valid
               },
               placements: [%Placement{state: :loaded}],
               runtime_memory_budgets: [memory],
               runtime_prefix_cache_statuses: [prefix],
               supports_prompt_token_ids: true,
               candidate_source: "monitor_snapshot"
             }
           ] = snapshot.candidates

    assert node_id == node.id
    assert heartbeat_id == heartbeat.id
    assert memory.admission_tier == :headroom_ok
    assert prefix.prefix_cache_fingerprint_count == 1
    assert prefix.prefix_cache_warmth_indicator == true
    refute Map.has_key?(prefix, :prefix_cache_fingerprints)
  end

  test "ADR 0017 latest row uses observed_at DESC then id DESC and preserves per-node times" do
    first_node = insert_node!()
    second_node = insert_node!()
    first_target = target_for(first_node)
    second_target = target_for(second_node)
    earlier = DateTime.add(@now, -10, :second)

    _older =
      append_heartbeat!(first_node, first_target, @now, %{aggregate_active_request_count: 1})

    latest =
      append_heartbeat!(first_node, first_target, @now, %{aggregate_active_request_count: 3})

    second =
      append_heartbeat!(second_node, second_target, earlier, %{aggregate_active_request_count: 2})

    assert {:ok, snapshot} =
             snapshot([first_target, second_target], [first_target, second_target])

    assert Map.new(
             snapshot.candidates,
             &{&1.node.id, {&1.heartbeat_id, &1.observed_at, &1.active_request_count}}
           ) == %{
             first_node.id => {latest.id, @now, 3},
             second_node.id => {second.id, earlier, 2}
           }
  end

  test "ADR 0017 removed targets are absent and reconfigured identities are rejected" do
    node = insert_node!()
    old_target = target_for(node)
    append_heartbeat!(node, old_target, @now)

    assert {:ok, removed} = snapshot([], [old_target])
    assert removed.candidates == []
    assert removed.rejections == []

    reconfigured =
      Target.grpc_compat(host: "10.99.0.250", port: old_target.address[:port], node_id: node.id)

    assert {:ok, changed} = snapshot([reconfigured], [old_target])
    assert changed.candidates == []

    assert [
             %Rejection{
               node_id: node_id,
               reason_codes: ["runtime_identity_mismatch"],
               diagnostics: %{fact: "effective_target_identity_mismatch"}
             }
           ] = changed.rejections

    assert node_id == node.id

    assert {:ok, historical} = snapshot([reconfigured], [reconfigured])
    assert historical.candidates == []
    assert [%Rejection{reason_codes: ["runtime_identity_mismatch"]}] = historical.rejections
  end

  test "ADR 0017 independently rejects stale Node and stale selected observation times" do
    stale_node =
      insert_node!(last_heartbeat_at: DateTime.add(@now, -@freshness_ms - 1, :millisecond))

    stale_row_node = insert_node!()
    stale_node_target = target_for(stale_node)
    stale_row_target = target_for(stale_row_node)

    append_heartbeat!(stale_node, stale_node_target, @now)

    update_node_heartbeat_at!(
      stale_node,
      DateTime.add(@now, -@freshness_ms - 1, :millisecond)
    )

    append_heartbeat!(
      stale_row_node,
      stale_row_target,
      DateTime.add(@now, -@freshness_ms - 1, :millisecond)
    )

    update_node_heartbeat_at!(stale_row_node, @now)

    assert {:ok, snapshot} =
             snapshot(
               [stale_node_target, stale_row_target],
               [stale_node_target, stale_row_target]
             )

    assert snapshot.candidates == []

    assert Map.new(snapshot.rejections, &{&1.node_id, {&1.reason_codes, &1.diagnostics.fact}}) ==
             %{
               stale_node.id => {["node_observation_stale"], "node_heartbeat_stale"},
               stale_row_node.id => {["node_observation_stale"], "heartbeat_observation_stale"}
             }
  end

  test "ADR 0017 rejects future and incoherent Node and heartbeat observation times" do
    future_node = insert_node!()
    future_heartbeat_node = insert_node!()
    incoherent_node = insert_node!()
    future_node_target = target_for(future_node)
    future_heartbeat_target = target_for(future_heartbeat_node)
    incoherent_target = target_for(incoherent_node)
    future_at = DateTime.add(@now, 1, :second)

    append_heartbeat!(future_node, future_node_target, @now)
    update_node_heartbeat_at!(future_node, future_at)

    append_heartbeat!(future_heartbeat_node, future_heartbeat_target, future_at)
    update_node_heartbeat_at!(future_heartbeat_node, @now)

    append_heartbeat!(incoherent_node, incoherent_target, @now)
    update_node_heartbeat_at!(incoherent_node, DateTime.add(@now, -1, :second))

    assert {:ok, snapshot} =
             snapshot(
               [future_node_target, future_heartbeat_target, incoherent_target],
               [future_node_target, future_heartbeat_target, incoherent_target]
             )

    assert snapshot.candidates == []

    assert Map.new(snapshot.rejections, &{&1.node_id, {&1.reason_codes, &1.diagnostics.fact}}) ==
             %{
               future_node.id => {["node_observation_stale"], "node_heartbeat_stale"},
               future_heartbeat_node.id =>
                 {["node_observation_stale"], "heartbeat_observation_stale"},
               incoherent_node.id =>
                 {["node_observation_stale"], "node_heartbeat_observation_incoherent"}
             }
  end

  test "ADR 0017 later transport failure rejects success until a later observation recovers" do
    node = insert_node!()
    target = target_for(node)
    success_at = @now
    failure_at = DateTime.add(success_at, 1, :second)
    recovery_at = DateTime.add(failure_at, 1, :second)

    append_heartbeat!(node, target, success_at)

    assert {:ok, failed_node} =
             Nodes.record_transport_failure(target, :node_timeout, failure_at)

    assert failed_node.health == :degraded
    assert failed_node.last_transport_failure_at == failure_at

    assert {:ok, failed_snapshot} =
             snapshot([target], [target], observed_at: failure_at)

    assert failed_snapshot.candidates == []

    assert [
             %Rejection{
               reason_codes: ["transport_unreachable"],
               diagnostics: %{fact: "transport_failure_newer"}
             }
           ] = failed_snapshot.rejections

    recovered_heartbeat =
      append_heartbeat!(failed_node, target, recovery_at, %{availability: :degraded})

    assert {:ok, recovered_snapshot} =
             snapshot([target], [target], observed_at: recovery_at)

    assert [
             %Candidate{
               heartbeat_id: heartbeat_id,
               availability: :degraded,
               node: %Node{last_transport_failure_at: ^failure_at}
             }
           ] = recovered_snapshot.candidates

    assert heartbeat_id == recovered_heartbeat.id
    assert recovered_snapshot.rejections == []
  end

  test "ADR 0017 missing and transport-failed observations never become candidates" do
    missing_node = insert_node!()
    failed_node = insert_node!()
    missing_target = target_for(missing_node)
    failed_target = target_for(failed_node)

    _transport_outcome = Nodes.record_transport_failure(failed_target, :node_timeout, @now)
    assert Repo.aggregate(NodeHeartbeat, :count) == 0

    assert {:ok, snapshot} =
             snapshot([missing_target, failed_target], [missing_target, failed_target])

    assert snapshot.candidates == []

    assert Map.new(snapshot.rejections, &{&1.node_id, &1.reason_codes}) == %{
             missing_node.id => ["dispatch_capacity_facts_unavailable"],
             failed_node.id => ["dispatch_capacity_facts_unavailable"]
           }
  end

  test "ADR 0017 invalid payload, unavailable runtime, and capacity gaps use stable reasons" do
    invalid_node = insert_node!()
    malformed_node = insert_node!()
    unavailable_node = insert_node!()
    capacity_node = insert_node!()
    invalid_target = target_for(invalid_node)
    malformed_target = target_for(malformed_node)
    unavailable_target = target_for(unavailable_node)
    capacity_target = target_for(capacity_node)

    invalid = append_heartbeat!(invalid_node, invalid_target, @now)

    Repo.update!(change(invalid, payload: Payload.invalid(:payload_too_large)))

    malformed = append_heartbeat!(malformed_node, malformed_target, @now)
    Repo.update!(change(malformed, payload: Map.delete(malformed.payload, "target")))

    append_heartbeat!(unavailable_node, unavailable_target, @now, %{availability: :unavailable})

    capacity = append_heartbeat!(capacity_node, capacity_target, @now)

    Repo.update!(
      change(capacity,
        payload:
          put_in(
            capacity.payload,
            ["aggregate_capacity_evidence", "validity"],
            "missing"
          )
      )
    )

    assert {:ok, snapshot} =
             snapshot(
               [invalid_target, malformed_target, unavailable_target, capacity_target],
               [invalid_target, malformed_target, unavailable_target, capacity_target]
             )

    assert snapshot.candidates == []

    reasons = Map.new(snapshot.rejections, &{&1.node_id, &1.reason_codes})

    assert reasons == %{
             invalid_node.id => ["dispatch_capacity_facts_unavailable"],
             malformed_node.id => ["dispatch_capacity_facts_unavailable"],
             unavailable_node.id => ["runtime_not_ready"],
             capacity_node.id => ["dispatch_capacity_facts_unavailable"]
           }
  end

  test "ADR 0017 snapshot rejects placement overflow and duplicate references before capping" do
    overflow_node = insert_node!()
    duplicate_node = insert_node!()
    overflow_target = target_for(overflow_node)
    duplicate_target = target_for(duplicate_node)
    overflow = append_heartbeat!(overflow_node, overflow_target, @now)
    duplicate = append_heartbeat!(duplicate_node, duplicate_target, @now)

    unique_placements =
      Enum.map(1..41, fn index ->
        %{
          "model_ref" => %{"model_id" => "model-#{index}", "version" => "v1"},
          "state" => "loaded"
        }
      end)

    duplicate_after_limit =
      Enum.take(unique_placements, 40) ++
        [
          %{
            "model_ref" => %{"model_id" => "model-1", "version" => "v1"},
            "state" => "loaded"
          }
        ]

    Repo.update!(
      change(overflow, payload: Map.put(overflow.payload, "placements", unique_placements))
    )

    Repo.update!(
      change(duplicate,
        payload: Map.put(duplicate.payload, "placements", duplicate_after_limit)
      )
    )

    assert {:ok, snapshot} =
             snapshot(
               [overflow_target, duplicate_target],
               [overflow_target, duplicate_target]
             )

    assert snapshot.candidates == []

    assert Map.new(snapshot.rejections, &{&1.node_id, &1.diagnostics.fact}) == %{
             overflow_node.id => "placement_entry_overflow",
             duplicate_node.id => "duplicate_placement_model_ref"
           }
  end

  test "ADR 0017 heartbeat Node and normalized payload target identities must agree exactly" do
    node = insert_node!()
    target = target_for(node)
    heartbeat = append_heartbeat!(node, target, @now)
    other_node_id = Ecto.UUID.generate()

    mismatched_payload =
      heartbeat.payload
      |> put_in(["target", "node_id"], other_node_id)
      |> put_in(["target", "address", "host"], "10.250.0.1")

    Repo.update!(change(heartbeat, payload: mismatched_payload))

    assert {:ok, snapshot} = snapshot([target], [target])
    assert snapshot.candidates == []

    assert [
             %Rejection{
               node_id: node_id,
               reason_codes: ["runtime_identity_mismatch"],
               diagnostics: %{fact: "heartbeat_target_identity_mismatch"}
             }
           ] = snapshot.rejections

    assert node_id == node.id
  end

  test "ADR 0017 current Node lifecycle and health remain eligibility authority" do
    inactive = insert_node!(state: :admitted)
    unhealthy = insert_node!(health: :unhealthy)
    unreachable = insert_node!(health: :unreachable)
    nodes = [inactive, unhealthy, unreachable]
    targets = Enum.map(nodes, &target_for/1)

    Enum.zip(nodes, targets)
    |> Enum.each(fn {node, target} -> append_heartbeat!(node, target, @now) end)

    assert {:ok, snapshot} = snapshot(targets, targets)
    assert snapshot.candidates == []

    assert Map.new(snapshot.rejections, &{&1.node_id, &1.reason_codes}) == %{
             inactive.id => ["node_not_active"],
             unhealthy.id => ["node_health_unhealthy"],
             unreachable.id => ["node_health_unreachable"]
           }
  end

  test "ADR 0017 default boundary shares the candidate statement visibility boundary" do
    initial_at = database_now()
    node = insert_node!(last_heartbeat_at: initial_at)
    target = target_for(node)
    _initial = append_heartbeat!(node, target, initial_at)

    BarrierRepo.configure(self())
    on_exit(&BarrierRepo.clear/0)

    task =
      Task.async(fn ->
        NodeHeartbeats.production_candidate_snapshot(
          [target],
          [target],
          repo: BarrierRepo
        )
      end)

    Sandbox.allow(Repo, self(), task.pid)
    assert_receive {:candidate_snapshot_query_ready, query_pid}, 1_000

    later_at = database_now()
    later = append_heartbeat!(node, target, later_at)
    send(query_pid, :continue_candidate_snapshot_query)

    assert {:ok, snapshot} = Task.await(task, 2_000)

    assert [
             %Candidate{
               heartbeat_id: heartbeat_id,
               observed_at: ^later_at,
               node: %Node{last_heartbeat_at: ^later_at}
             }
           ] = snapshot.candidates

    assert heartbeat_id == later.id
    assert DateTime.compare(snapshot.observed_at, later_at) in [:eq, :gt]
  end

  test "ADR 0017 empty default snapshot uses a database boundary" do
    assert {:ok, snapshot} = NodeHeartbeats.production_candidate_snapshot([], [])

    assert snapshot.candidates == []
    assert snapshot.rejections == []
    assert %DateTime{} = snapshot.observed_at
  end

  test "ADR 0017 malformed database boundaries fail closed" do
    observed_at = DateTime.utc_now()
    node = insert_node!(last_heartbeat_at: observed_at)
    target = target_for(node)
    append_heartbeat!(node, target, observed_at)

    assert {:error, :candidate_snapshot_unavailable} =
             NodeHeartbeats.production_candidate_snapshot(
               [target],
               [target],
               repo: MalformedBoundaryRepo
             )
  end

  test "ADR 0017 database and incomplete reads fail closed without partial evidence" do
    node = insert_node!()
    target = target_for(node)
    append_heartbeat!(node, target, @now)

    assert {:error, :candidate_snapshot_unavailable} =
             snapshot([target], [target], repo: FailingRepo)

    assert {:error, :candidate_snapshot_unavailable} =
             snapshot([target], [target], repo: IncompleteRepo)

    assert {:error, :candidate_snapshot_unavailable} =
             snapshot([target], [target], repo: RaisingRepo)

    assert {:error, :candidate_snapshot_unavailable} =
             snapshot([target], [target], repo: ExitingRepo)
  end

  test "ADR 0017 restart needs no hydration and later reads never reuse process cache" do
    node = insert_node!()
    target = target_for(node)
    heartbeat = append_heartbeat!(node, target, @now)

    task =
      Task.async(fn ->
        snapshot([target], [target])
      end)

    assert {:ok, %{candidates: [%Candidate{heartbeat_id: heartbeat_id}]}} = Task.await(task)
    assert heartbeat_id == heartbeat.id

    Repo.delete!(heartbeat)

    assert {:ok,
            %{
              candidates: [],
              rejections: [
                %Rejection{reason_codes: ["dispatch_capacity_facts_unavailable"]}
              ]
            }} = snapshot([target], [target])
  end

  defp database_now do
    Repo.one(
      from(_value in fragment("SELECT 1"),
        select: type(fragment("statement_timestamp()"), :utc_datetime_usec)
      )
    )
  end

  defp snapshot(effective, active, opts \\ []) do
    NodeHeartbeats.production_candidate_snapshot(
      effective,
      active,
      Keyword.put_new(opts, :observed_at, @now)
    )
  end

  defp append_heartbeat!(node, target, observed_at, overrides \\ %{}) do
    observation =
      Map.merge(
        %{
          endpoint_id: target.id,
          availability: :available,
          worker_state: :idle,
          aggregate_active_request_count: 0,
          aggregate_max_concurrency: 4
        },
        overrides
      )

    {:ok, heartbeat} =
      Repo.transaction(fn ->
        current_node = Repo.get!(Node, node.id)
        Repo.update!(change(current_node, last_heartbeat_at: observed_at))

        {:ok, heartbeat} =
          NodeHeartbeats.append(current_node, target, observation, observed_at)

        heartbeat
      end)

    heartbeat
  end

  defp update_node_heartbeat_at!(node, observed_at) do
    node
    |> then(&Repo.get!(Node, &1.id))
    |> change(last_heartbeat_at: observed_at)
    |> Repo.update!()
  end

  defp insert_node!(overrides \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    host = "10.90.0.#{rem(unique, 200) + 1}"

    attrs =
      %{
        hostname: "snapshot-#{unique}.local",
        display_name: "snapshot-node-#{unique}",
        advertise_addr: host,
        rpc_port: 50_071,
        connect_host: host,
        connect_port: 50_071,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{},
        last_heartbeat_at: @now
      }
      |> Map.merge(Map.new(overrides))

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp target_for(node) do
    Target.grpc_compat(
      host: node.connect_host,
      port: node.connect_port,
      node_id: node.id,
      metadata: %{
        source: :trusted_node_inventory,
        authorization: :inference_dispatch,
        certificate_identifier: "certificate-#{node.id}",
        certificate_fingerprint: String.duplicate("a", 64)
      }
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
