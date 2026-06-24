defmodule Orchard.Inference.QueueManagerTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.QueueAdmissionAPI,
    only: [assert_queue_metadata: 2, assert_queue_metadata: 3]

  alias Orchard.Inference.QueueManager
  alias Orchard.Requests
  alias Orchard.Requests.{Request, RequestServer}

  setup do
    QueueManager.reset()
    :ok
  end

  test "grants one active request per model lane and releases idempotently" do
    request = admission_request("req-a")

    assert {:ok, grant} = QueueManager.acquire(request, config: queue_config())
    assert grant.queue_result == :immediate
    assert grant.queue_key == "queue-model@v1"

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"), config: queue_config())

    assert :ok = QueueManager.release(grant)
    assert {:ok, queued_grant} = QueueManager.await(ticket)
    assert queued_grant.queue_result == :queued
    assert queued_grant.queued_at != nil

    assert :ok = QueueManager.release(grant)
    assert :ok = QueueManager.release(queued_grant)
    assert :ok = QueueManager.release(queued_grant)
  end

  test "capacity two admits two active requests and queues the third" do
    with_queue_admission_config(queue_config(capacity: 2, max_wait_ms: 1_000), fn ->
      assert {:ok, first_grant} = QueueManager.acquire(admission_request("req-capacity2-a"))
      assert first_grant.queue_result == :immediate

      assert {:ok, second_grant} = QueueManager.acquire(admission_request("req-capacity2-b"))
      assert second_grant.queue_result == :immediate

      assert {:queued, third_ticket} = QueueManager.acquire(admission_request("req-capacity2-c"))

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, third_grant} = QueueManager.await(third_ticket)
      assert third_grant.queue_result == :queued
      assert third_grant.queued_at != nil

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(third_grant)
    end)
  end

  test "SPEC.md §5.4 source refresh does not reduce configured lane capacity" do
    config = queue_config(capacity: 2, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, first_grant} = QueueManager.acquire(admission_request("req-source-base-a"))
      assert {:ok, second_grant} = QueueManager.acquire(admission_request("req-source-base-b"))

      assert {:queued, ticket} =
               QueueManager.acquire(admission_request("req-source-base-c"))

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      assert :ok =
               QueueManager.refresh_capacity("queue-model", "v1", 1,
                 source: {:node, "conservative-cold"}
               )

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)

      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.4 source spare capacity adds to configured lane capacity" do
    config = queue_config(capacity: 1, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, active_grant} = QueueManager.acquire(admission_request("req-source-spare-a"))

      assert {:queued, ticket} =
               QueueManager.acquire(admission_request("req-source-spare-b"))

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
      refute Task.yield(awaiter, 50)

      assert :ok =
               QueueManager.refresh_capacity("queue-model", "v1", 1,
                 source: {:node, "spare-slot"}
               )

      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(active_grant)
      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 node source refresh reserves assigned unobserved base grants" do
    node_id = Ecto.UUID.generate()
    config = queue_config(capacity: 2, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, first_grant} =
               QueueManager.acquire(admission_request("req-node-assigned-base-a"))

      assert {:ok, second_grant} =
               QueueManager.acquire(admission_request("req-node-assigned-base-b"))

      assert :ok = QueueManager.mark_grant_node(first_grant, node_id)
      assert :ok = QueueManager.mark_grant_node(second_grant, node_id)

      assert {:queued, ticket} =
               QueueManager.acquire(admission_request("req-node-assigned-base-c"))

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 2,
                 placements: []
               })

      refute Task.yield(awaiter, 50)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 assigned base grants do not overlap unrelated node activity" do
    node_id = Ecto.UUID.generate()
    config = queue_config(capacity: 1, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, active_grant} =
               QueueManager.acquire(
                 admission_request("req-node-assigned-unrelated-a",
                   model_id: "assigned-unrelated"
                 )
               )

      assert :ok = QueueManager.mark_grant_node(active_grant, node_id)

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-node-assigned-unrelated-b",
                   model_id: "assigned-unrelated"
                 )
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 1,
                 node_max: 2,
                 placements: []
               })

      refute Task.yield(awaiter, 50)

      assert :ok = QueueManager.release(active_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 reserved base grant still allows observed spare node capacity" do
    node_id = Ecto.UUID.generate()
    config = queue_config(capacity: 1, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, active_grant} =
               QueueManager.acquire(
                 admission_request("req-node-reserved-spare-a",
                   model_id: "reserved-spare"
                 )
               )

      assert :ok = QueueManager.mark_grant_node(active_grant, node_id)

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-node-reserved-spare-b",
                   model_id: "reserved-spare"
                 )
               )

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 2,
                 placements: []
               })

      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued
      assert queued_grant.queue_key == "reserved-spare@v1"

      assert :ok = QueueManager.release(active_grant)
      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 retained node source accounts for newly assigned base grants" do
    node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-node-retained-new-base-a",
                   model_id: "retained-new-base-a"
                 )
               )

      assert :ok = refresh_node_source_capacity(node_id)

      assert {:ok, base_grant} =
               QueueManager.acquire(
                 admission_request("req-node-retained-new-base-b",
                   model_id: "retained-new-base-b"
                 ),
                 config: queue_config(capacity: 1)
               )

      assert :ok = QueueManager.mark_grant_node(base_grant, node_id)

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      refute Task.yield(awaiter, 100)

      assert :ok = QueueManager.release(base_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_key == "retained-new-base-a@v1"

      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 scheduler probe refresh reserves unassigned base grants" do
    node_id = Ecto.UUID.generate()
    config = queue_config(capacity: 1, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:ok, active_grant} =
               QueueManager.acquire(admission_request("req-node-unassigned-base-a"))

      assert {:queued, ticket} =
               QueueManager.acquire(admission_request("req-node-unassigned-base-b"))

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: [],
                 reserve_unassigned_node_grants?: true
               })

      refute Task.yield(awaiter, 50)

      assert :ok = QueueManager.release(active_grant)
      assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
      assert queued_grant.queue_result == :queued

      assert :ok = QueueManager.release(queued_grant)
    end)
  end

  test "SPEC.md §5.5 scheduler probe refresh reserves unassigned source grants" do
    source_node_id = Ecto.UUID.generate()
    probed_node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-unassigned-source-a",
                   model_id: "unassigned-source-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_unassigned_source_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, source_node_id},
                   {:node, source_node_id, :placement},
                   {:node, source_node_id, :cold}
                 ],
                 placement_source: {:node, source_node_id, :placement},
                 cold_source: {:node, source_node_id, :cold},
                 node_id: source_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_unassigned_source_result, {:ok, first_grant}}, 2_000

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-unassigned-source-b",
                   model_id: "unassigned-source-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, probed_node_id},
                   {:node, probed_node_id, :placement},
                   {:node, probed_node_id, :cold}
                 ],
                 placement_source: {:node, probed_node_id, :placement},
                 cold_source: {:node, probed_node_id, :cold},
                 node_id: probed_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: [],
                 reserve_unassigned_source_grants?: true
               })

      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.abandon(second_ticket)
      Task.shutdown(second_awaiter)
      assert :ok = QueueManager.release(first_grant)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.5 node source refresh reserves unassigned source grants by default" do
    source_node_id = Ecto.UUID.generate()
    probed_node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-default-unassigned-source-a",
                   model_id: "default-unassigned-source-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_default_unassigned_source_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, source_node_id},
                   {:node, source_node_id, :placement},
                   {:node, source_node_id, :cold}
                 ],
                 placement_source: {:node, source_node_id, :placement},
                 cold_source: {:node, source_node_id, :cold},
                 node_id: source_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_default_unassigned_source_result, {:ok, first_grant}}, 2_000

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-default-unassigned-source-b",
                   model_id: "default-unassigned-source-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, probed_node_id},
                   {:node, probed_node_id, :placement},
                   {:node, probed_node_id, :cold}
                 ],
                 placement_source: {:node, probed_node_id, :placement},
                 cold_source: {:node, probed_node_id, :cold},
                 node_id: probed_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.abandon(second_ticket)
      Task.shutdown(second_awaiter)
      assert :ok = QueueManager.release(first_grant)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.5 suppressed node source capacity rebalances after grant node resolves" do
    source_node_id = Ecto.UUID.generate()
    probed_node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-suppressed-replay-a",
                   model_id: "suppressed-replay-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_suppressed_replay_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, source_node_id},
                   {:node, source_node_id, :placement},
                   {:node, source_node_id, :cold}
                 ],
                 placement_source: {:node, source_node_id, :placement},
                 cold_source: {:node, source_node_id, :cold},
                 node_id: source_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_suppressed_replay_result, {:ok, first_grant}}, 2_000

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-suppressed-replay-b",
                   model_id: "suppressed-replay-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, probed_node_id},
                   {:node, probed_node_id, :placement},
                   {:node, probed_node_id, :cold}
                 ],
                 placement_source: {:node, probed_node_id, :placement},
                 cold_source: {:node, probed_node_id, :cold},
                 node_id: probed_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.mark_grant_node(first_grant, source_node_id)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_key == "suppressed-replay-b@v1"

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(first_grant)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.4 node source refresh retains capacity before await attaches" do
    node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-node-pre-await-source",
                   model_id: "pre-await-source-model"
                 )
               )

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert {:ok, grant} = Task.await(awaiter, 2_000)
      assert grant.queue_result == :queued
      assert grant.queue_key == "pre-await-source-model@v1"

      assert :ok = QueueManager.release(grant)
    end)
  end

  test "SPEC.md §5.5 resolved node mismatch clears stale source reservation" do
    source_node_id = Ecto.UUID.generate()
    resolved_node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-source-mismatch-a",
                   model_id: "source-mismatch-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_source_mismatch_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, source_node_id},
                   {:node, source_node_id, :placement},
                   {:node, source_node_id, :cold}
                 ],
                 placement_source: {:node, source_node_id, :placement},
                 cold_source: {:node, source_node_id, :cold},
                 node_id: source_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_source_mismatch_result, {:ok, first_grant}}, 2_000
      assert :ok = QueueManager.mark_grant_node(first_grant, resolved_node_id)

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-source-mismatch-b",
                   model_id: "source-mismatch-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.abandon(second_ticket)
      Task.shutdown(second_awaiter)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.5 resolved node mismatch expires pending source capacity" do
    source_node_id = Ecto.UUID.generate()
    resolved_node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-source-mismatch-pending-a",
                   model_id: "source-mismatch-pending-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_source_mismatch_pending_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, source_node_id},
                   {:node, source_node_id, :placement},
                   {:node, source_node_id, :cold}
                 ],
                 placement_source: {:node, source_node_id, :placement},
                 cold_source: {:node, source_node_id, :cold},
                 node_id: source_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_source_mismatch_pending_result, {:ok, first_grant}}, 2_000

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-source-mismatch-pending-b",
                   model_id: "source-mismatch-pending-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

      assert :ok = QueueManager.mark_grant_node(first_grant, resolved_node_id)
      assert :ok = QueueManager.release(first_grant)
      refute Task.yield(second_awaiter, 100)

      assert :ok = QueueManager.abandon(second_ticket)
      Task.shutdown(second_awaiter)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.5 unobserved source grant remains reserved when heartbeat sees it active" do
    node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-unobserved-active-a",
                   model_id: "unobserved-active-a"
                 )
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-unobserved-active-b",
                   model_id: "unobserved-active-b"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_unobserved_active_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_unobserved_active_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 1,
                 node_max: 1,
                 placements: []
               })

      refute Task.yield(second_awaiter, 50)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_key == "unobserved-active-b@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.5 node source limit is dropped after source queue drains" do
    node_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(capacity: 0, max_wait_ms: 1_000), fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-drained-source-a",
                   model_id: "drained-source-a"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_drained_source_result)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert_receive {:first_drained_source_result, {:ok, first_grant}}, 2_000
      assert :ok = QueueManager.release(first_grant)

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-node-drained-source-b",
                   model_id: "drained-source-b"
                 )
               )

      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)
      refute Task.yield(second_awaiter, 50)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               })

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_key == "drained-source-b@v1"

      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.3 tenant active cap queues same-tenant work despite placement capacity" do
    tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 2, max_active_per_tenant: 1)

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-tenant-active-a", tenant_id: tenant_id),
               config: config
             )

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-tenant-active-b", tenant_id: tenant_id),
               config: config
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    refute Task.yield(awaiter, 50)

    assert :ok = QueueManager.release(grant)
    assert {:ok, queued_grant} = Task.await(awaiter, 2_000)
    assert queued_grant.queue_result == :queued

    assert :ok = QueueManager.release(queued_grant)
  end

  test "SPEC.md §5.3 tenant active cap does not block another tenant with placement capacity" do
    first_tenant_id = Ecto.UUID.generate()
    second_tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 2, max_active_per_tenant: 1)

    assert {:ok, first_grant} =
             QueueManager.acquire(
               admission_request("req-tenant-isolated-a", tenant_id: first_tenant_id),
               config: config
             )

    assert {:ok, second_grant} =
             QueueManager.acquire(
               admission_request("req-tenant-isolated-b", tenant_id: second_tenant_id),
               config: config
             )

    assert first_grant.queue_result == :immediate
    assert second_grant.queue_result == :immediate

    assert :ok = QueueManager.release(first_grant)
    assert :ok = QueueManager.release(second_grant)
  end

  test "SPEC.md §5.4 active-cap-blocked tenant does not block another tenant" do
    first_tenant_id = Ecto.UUID.generate()
    second_tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 2, max_active_per_tenant: 1)

    with_queue_admission_config(config, fn ->
      assert {:ok, first_grant} =
               QueueManager.acquire(
                 admission_request("req-tenant-lane-head-a", tenant_id: first_tenant_id)
               )

      assert {:queued, blocked_ticket} =
               QueueManager.acquire(
                 admission_request("req-tenant-lane-head-b", tenant_id: first_tenant_id)
               )

      blocked_awaiter = Task.async(fn -> QueueManager.await(blocked_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(blocked_ticket) end)

      assert {:queued, other_ticket} =
               QueueManager.acquire(
                 admission_request("req-tenant-lane-head-c", tenant_id: second_tenant_id)
               )

      other_awaiter = Task.async(fn -> QueueManager.await(other_ticket) end)

      assert {:ok, other_grant} = Task.await(other_awaiter, 2_000)
      assert other_grant.queue_result == :queued
      refute Task.yield(blocked_awaiter, 50)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, blocked_grant} = Task.await(blocked_awaiter, 2_000)
      assert blocked_grant.queue_result == :queued

      assert :ok = QueueManager.release(other_grant)
      assert :ok = QueueManager.release(blocked_grant)
    end)
  end

  test "SPEC.md §5.4 placement capacity refresh wakes queued requests without new admission" do
    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-refresh-wake"),
               config: queue_config(capacity: 0)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    refute Task.yield(awaiter, 50)

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 1)
    assert {:ok, grant} = Task.await(awaiter, 2_000)
    assert grant.queue_result == :queued
    assert grant.queue_key == "queue-model@v1"

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §5.4 periodic queue tick wakes queued requests while non-empty" do
    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-periodic-wake"),
               config: queue_config(capacity: 0)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    refute Task.yield(awaiter, 50)

    :sys.replace_state(QueueManager, fn state ->
      lane = Map.fetch!(state.lanes, "queue-model@v1")
      %{state | lanes: Map.put(state.lanes, "queue-model@v1", %{lane | capacity: 1})}
    end)

    assert {:ok, grant} = Task.await(awaiter, 2_000)
    assert grant.queue_result == :queued
    assert grant.queue_key == "queue-model@v1"

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §5.4 source-aware capacity refresh aggregates loaded placements" do
    assert {:queued, first_ticket} =
             QueueManager.acquire(admission_request("req-source-refresh-a"),
               config: queue_config(capacity: 0)
             )

    assert {:queued, second_ticket} =
             QueueManager.acquire(admission_request("req-source-refresh-b"),
               config: queue_config(capacity: 0)
             )

    first_awaiter = start_holding_awaiter(first_ticket, :first_source_refresh_result)
    second_awaiter = start_holding_awaiter(second_ticket, :second_source_refresh_result)

    assert wait_until(fn -> queue_entry_awaiting?(first_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 1, source: {:node, "a"})
    assert_receive {:first_source_refresh_result, {:ok, first_grant}}, 2_000
    refute_receive {:second_source_refresh_result, _result}, 50

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 1, source: {:node, "b"})
    assert_receive {:second_source_refresh_result, {:ok, second_grant}}, 2_000

    assert first_grant.queue_result == :queued
    assert second_grant.queue_result == :queued

    assert :ok = QueueManager.release(first_grant)
    assert :ok = QueueManager.release(second_grant)
    send(first_awaiter, :stop)
    send(second_awaiter, :stop)
  end

  test "SPEC.md §5.5 placement source limit stays capped by placement max" do
    node_id = Ecto.UUID.generate()
    tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 0, max_wait_ms: 1_000)

    with_queue_admission_config(config, fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-placement-limit-a",
                   tenant_id: tenant_id,
                   model_id: "placement-limit"
                 )
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-placement-limit-b",
                   tenant_id: tenant_id,
                   model_id: "placement-limit"
                 )
               )

      assert {:queued, third_ticket} =
               QueueManager.acquire(
                 admission_request("req-placement-limit-c",
                   tenant_id: tenant_id,
                   model_id: "placement-limit"
                 )
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_placement_limit_result)
      second_awaiter = start_holding_awaiter(second_ticket, :second_placement_limit_result)
      third_awaiter = Task.async(fn -> QueueManager.await(third_ticket) end)

      assert wait_until(fn -> queue_entry_awaiting?(third_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 4,
                 placements: [
                   {"placement-limit", "v1", %{active_request_count: 0, max_concurrency: 2}}
                 ]
               })

      assert_receive {:first_placement_limit_result, {:ok, first_grant}}, 2_000
      assert_receive {:second_placement_limit_result, {:ok, second_grant}}, 2_000
      refute Task.yield(third_awaiter, 50)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 4,
                 placements: [
                   {"placement-limit", "v1", %{active_request_count: 0, max_concurrency: 2}}
                 ]
               })

      refute Task.yield(third_awaiter, 100)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, third_grant} = Task.await(third_awaiter, 2_000)
      assert third_grant.queue_key == "placement-limit@v1"

      assert :ok = QueueManager.release(second_grant)
      assert :ok = QueueManager.release(third_grant)
      send(first_awaiter, :stop)
      send(second_awaiter, :stop)
    end)
  end

  test "SPEC.md §5.4 source-aware zero-capacity refresh removes stale placement capacity" do
    config = queue_config(capacity: 0, max_wait_ms: 2_000)

    assert {:queued, first_ticket} =
             QueueManager.acquire(admission_request("req-source-clear-a"),
               config: config
             )

    assert {:queued, second_ticket} =
             QueueManager.acquire(admission_request("req-source-clear-b"),
               config: config
             )

    first_awaiter = start_holding_awaiter(first_ticket, :first_source_clear_result)
    second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

    assert wait_until(fn -> queue_entry_awaiting?(first_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 1, source: {:node, "a"})
    assert_receive {:first_source_clear_result, {:ok, first_grant}}, 2_000
    refute Task.yield(second_awaiter, 50)

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 0, source: {:node, "a"})
    assert :ok = QueueManager.release(first_grant)
    refute Task.yield(second_awaiter, 100)

    assert :ok = QueueManager.refresh_capacity("queue-model", "v1", 1, source: {:node, "b"})
    assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
    assert second_grant.queue_result == :queued

    assert :ok = QueueManager.release(second_grant)
    send(first_awaiter, :stop)
  end

  test "SPEC.md §5.4 cross-tenant weighted round-robin grants one tenant turn at a time" do
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(max_wait_ms: 1_000), fn ->
      assert {:ok, held_grant} =
               QueueManager.acquire(admission_request("req-held", tenant_id: tenant_a))

      assert {:queued, ticket_a1} =
               QueueManager.acquire(admission_request("req-a1", tenant_id: tenant_a))

      assert {:queued, ticket_a2} =
               QueueManager.acquire(admission_request("req-a2", tenant_id: tenant_a))

      assert {:queued, ticket_b1} =
               QueueManager.acquire(admission_request("req-b1", tenant_id: tenant_b))

      awaiter_a1 = await_and_hold(ticket_a1, :a1)
      awaiter_a2 = await_and_hold(ticket_a2, :a2)
      awaiter_b1 = await_and_hold(ticket_b1, :b1)

      assert wait_until(fn -> queue_entry_awaiting?(ticket_a1) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_a2) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_b1) end)

      assert :ok = QueueManager.release(held_grant)
      assert_receive {:await_result, :a1, {:ok, grant_a1}}, 1_000
      refute_receive {:await_result, :a2, _}, 20
      refute_receive {:await_result, :b1, _}, 20

      assert :ok = QueueManager.release(grant_a1)
      assert_receive {:await_result, :b1, {:ok, grant_b1}}, 1_000
      refute_receive {:await_result, :a2, _}, 20

      assert :ok = QueueManager.release(grant_b1)
      assert_receive {:await_result, :a2, {:ok, grant_a2}}, 1_000

      assert :ok = QueueManager.release(grant_a2)
      stop_awaiter(awaiter_a1)
      stop_awaiter(awaiter_a2)
      stop_awaiter(awaiter_b1)
    end)
  end

  test "SPEC.md §5.4 tenant FIFO blocks later same-tenant lane while older request waits" do
    tenant_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(max_wait_ms: 1_000), fn ->
      assert {:ok, model_a_grant} =
               QueueManager.acquire(
                 admission_request("req-model-a-held",
                   tenant_id: tenant_id,
                   model_id: "queue-model-a"
                 )
               )

      assert {:ok, model_b_grant} =
               QueueManager.acquire(
                 admission_request("req-model-b-held",
                   tenant_id: tenant_id,
                   model_id: "queue-model-b"
                 )
               )

      assert {:queued, ticket_a} =
               QueueManager.acquire(
                 admission_request("req-model-a-queued",
                   tenant_id: tenant_id,
                   model_id: "queue-model-a"
                 )
               )

      assert {:queued, ticket_b} =
               QueueManager.acquire(
                 admission_request("req-model-b-queued",
                   tenant_id: tenant_id,
                   model_id: "queue-model-b"
                 )
               )

      awaiter_a = await_and_hold(ticket_a, :same_tenant_a)
      awaiter_b = await_and_hold(ticket_b, :same_tenant_b)

      assert wait_until(fn -> queue_entry_awaiting?(ticket_a) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_b) end)

      assert :ok = QueueManager.release(model_b_grant)
      refute_receive {:await_result, :same_tenant_b, _}, 50

      assert :ok = QueueManager.release(model_a_grant)
      assert_receive {:await_result, :same_tenant_a, {:ok, grant_a}}, 1_000
      assert_receive {:await_result, :same_tenant_b, {:ok, grant_b}}, 1_000

      assert :ok = QueueManager.release(grant_a)
      assert :ok = QueueManager.release(grant_b)
      stop_awaiter(awaiter_a)
      stop_awaiter(awaiter_b)
    end)
  end

  test "SPEC.md §5.4 weighted round-robin honors configured tenant weights" do
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    config =
      queue_config(
        max_wait_ms: 1_000,
        tenant_weights: %{tenant_a => 1, tenant_b => 2}
      )

    with_queue_admission_config(config, fn ->
      assert {:ok, held_grant} =
               QueueManager.acquire(admission_request("req-weight-held", tenant_id: tenant_a))

      assert {:queued, ticket_a1} =
               QueueManager.acquire(admission_request("req-weight-a1", tenant_id: tenant_a))

      assert {:queued, ticket_a2} =
               QueueManager.acquire(admission_request("req-weight-a2", tenant_id: tenant_a))

      assert {:queued, ticket_b1} =
               QueueManager.acquire(admission_request("req-weight-b1", tenant_id: tenant_b))

      assert {:queued, ticket_b2} =
               QueueManager.acquire(admission_request("req-weight-b2", tenant_id: tenant_b))

      awaiter_a1 = await_and_hold(ticket_a1, :weight_a1)
      awaiter_a2 = await_and_hold(ticket_a2, :weight_a2)
      awaiter_b1 = await_and_hold(ticket_b1, :weight_b1)
      awaiter_b2 = await_and_hold(ticket_b2, :weight_b2)

      assert wait_until(fn -> queue_entry_awaiting?(ticket_a1) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_a2) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_b1) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_b2) end)

      assert :ok = QueueManager.release(held_grant)
      assert_receive {:await_result, :weight_a1, {:ok, grant_a1}}, 1_000

      assert :ok = QueueManager.release(grant_a1)
      assert_receive {:await_result, :weight_b1, {:ok, grant_b1}}, 1_000

      assert :ok = QueueManager.release(grant_b1)
      assert_receive {:await_result, :weight_b2, {:ok, grant_b2}}, 1_000
      refute_receive {:await_result, :weight_a2, _}, 20

      assert :ok = QueueManager.release(grant_b2)
      assert_receive {:await_result, :weight_a2, {:ok, grant_a2}}, 1_000

      assert :ok = QueueManager.release(grant_a2)
      stop_awaiter(awaiter_a1)
      stop_awaiter(awaiter_a2)
      stop_awaiter(awaiter_b1)
      stop_awaiter(awaiter_b2)
    end)
  end

  test "SPEC.md §5.4 pre-await queued work prevents same-lane immediate bypass" do
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(max_wait_ms: 1_000), fn ->
      assert {:ok, held_grant} =
               QueueManager.acquire(admission_request("req-pre-await-held", tenant_id: tenant_a))

      assert {:queued, ticket_a} =
               QueueManager.acquire(admission_request("req-pre-await-a", tenant_id: tenant_a))

      assert :ok = QueueManager.release(held_grant)

      assert {:queued, ticket_b} =
               QueueManager.acquire(admission_request("req-pre-await-b", tenant_id: tenant_b))

      awaiter_a = await_and_hold(ticket_a, :pre_await_a)
      awaiter_b = await_and_hold(ticket_b, :pre_await_b)

      assert wait_until(fn -> queue_entry_awaiting?(ticket_b) end)

      assert_receive {:await_result, :pre_await_a, {:ok, grant_a}}, 1_000
      refute_receive {:await_result, :pre_await_b, _}, 20

      assert :ok = QueueManager.release(grant_a)
      assert_receive {:await_result, :pre_await_b, {:ok, grant_b}}, 1_000

      assert :ok = QueueManager.release(grant_b)
      stop_awaiter(awaiter_a)
      stop_awaiter(awaiter_b)
    end)
  end

  test "requeue defers an active grant behind the lane retry interval" do
    config = queue_config(max_wait_ms: 500, poll_interval_ms: 200)

    with_queue_admission_config(config, fn ->
      request = admission_request("req-requeue")

      assert {:ok, grant} = QueueManager.acquire(request)
      assert {:queued, ticket} = QueueManager.requeue(grant, request)

      awaiter = Task.async(fn -> QueueManager.await(ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
      refute Task.yield(awaiter, 50)

      assert {:ok, requeued_grant} = Task.await(awaiter, 1_000)
      assert requeued_grant.queue_result == :queued
      assert requeued_grant.queue_wait_ms >= config[:poll_interval_ms]

      assert :ok = QueueManager.release(grant)
      assert :ok = QueueManager.release(requeued_grant)
    end)
  end

  test "SPEC.md §5.5 cluster_busy requeue retires source before other lane promotion" do
    assert_busy_requeue_retires_source(:cluster_busy)
  end

  test "SPEC.md §5.5 model_busy requeue retires source before other lane promotion" do
    assert_busy_requeue_retires_source(:model_busy)
  end

  test "SPEC.md §5.4 queued model lanes include requeued entries" do
    config = queue_config(max_wait_ms: 500, poll_interval_ms: 200)

    with_queue_admission_config(config, fn ->
      request = admission_request("req-requeue-lane", model_id: "requeue-lane-model")

      assert {:ok, grant} = QueueManager.acquire(request)
      assert {:queued, ticket} = QueueManager.requeue(grant, request)

      entry =
        QueueManager
        |> :sys.get_state()
        |> Map.fetch!(:entries)
        |> Map.fetch!(ticket.ticket_ref)

      assert entry.model_id == "requeue-lane-model"
      assert entry.version == "v1"

      parent = self()

      :sys.replace_state(QueueManager, fn state ->
        entry =
          state.entries
          |> Map.fetch!(ticket.ticket_ref)
          |> Map.delete(:model_id)
          |> Map.delete(:version)
          |> Map.put(:await_from, {parent, make_ref()})

        lane =
          state.lanes
          |> Map.fetch!(ticket.queue_key)
          |> Map.put(:blocked_until_monotonic_ms, nil)
          |> Map.put(:block_ref, nil)

        %{
          state
          | entries: Map.put(state.entries, ticket.ticket_ref, entry),
            lanes: Map.put(state.lanes, ticket.queue_key, lane)
        }
      end)

      assert {"requeue-lane-model", "v1"} in QueueManager.queued_model_lanes()
      assert :ok = QueueManager.abandon(ticket)
    end)
  end

  test "SPEC.md §5.4 queued model lanes follow same-tenant FIFO order" do
    tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 0)

    with_queue_admission_config(config, fn ->
      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 admission_request("req-queued-lanes-fifo-a",
                   tenant_id: tenant_id,
                   model_id: "queued-lane-a"
                 )
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 admission_request("req-queued-lanes-fifo-b",
                   tenant_id: tenant_id,
                   model_id: "queued-lane-b"
                 )
               )

      parent = self()

      :sys.replace_state(QueueManager, fn state ->
        first_entry =
          state.entries
          |> Map.fetch!(first_ticket.ticket_ref)
          |> Map.put(:ticket_ref, 2)
          |> Map.put(:await_from, {parent, make_ref()})

        second_entry =
          state.entries
          |> Map.fetch!(second_ticket.ticket_ref)
          |> Map.put(:ticket_ref, 1)
          |> Map.put(:await_from, {parent, make_ref()})

        %{
          state
          | entries: %{1 => second_entry, 2 => first_entry},
            tenant_queues: %{tenant_id => %{queue: [2, 1]}},
            tenant_order: [tenant_id]
        }
      end)

      assert QueueManager.queued_model_lanes() == [
               {"queued-lane-a", "v1"},
               {"queued-lane-b", "v1"}
             ]
    end)
  end

  test "SPEC.md §5.5 source allocation respects source-blocked FIFO heads" do
    node_id = Ecto.UUID.generate()
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    config =
      queue_config(
        capacity: 0,
        max_wait_ms: 1_000,
        tenant_weights: %{tenant_a => 2, tenant_b => 1}
      )

    with_queue_admission_config(config, fn ->
      assert {:queued, blocked_ticket} =
               QueueManager.acquire(
                 admission_request("req-source-blocked-fifo-head",
                   tenant_id: tenant_a,
                   model_id: "source-blocked-head"
                 )
               )

      assert {:queued, later_ticket} =
               QueueManager.acquire(
                 admission_request("req-source-later-same-tenant",
                   tenant_id: tenant_a,
                   model_id: "source-later-same-tenant"
                 )
               )

      assert {:queued, ready_ticket} =
               QueueManager.acquire(
                 admission_request("req-source-ready-other-tenant",
                   tenant_id: tenant_b,
                   model_id: "source-ready-other-tenant"
                 )
               )

      blocked_awaiter = await_and_hold(blocked_ticket, :source_blocked_head)
      later_awaiter = await_and_hold(later_ticket, :source_later_same_tenant)
      ready_awaiter = await_and_hold(ready_ticket, :source_ready_other_tenant)

      assert wait_until(fn -> queue_entry_awaiting?(blocked_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(later_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ready_ticket) end)

      assert :ok =
               QueueManager.refresh_node_capacity_sources(%{
                 clear_sources: [
                   {:node, node_id},
                   {:node, node_id, :placement},
                   {:node, node_id, :cold}
                 ],
                 placement_source: {:node, node_id, :placement},
                 cold_source: {:node, node_id, :cold},
                 node_id: node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: [{"source-blocked-head", "v1", :unavailable}]
               })

      assert_receive {:await_result, :source_ready_other_tenant, {:ok, ready_grant}}, 1_000
      refute_receive {:await_result, :source_later_same_tenant, _}, 50

      assert :ok = QueueManager.release(ready_grant)
      assert :ok = QueueManager.abandon(blocked_ticket)
      assert :ok = QueueManager.abandon(later_ticket)
      stop_awaiter(blocked_awaiter)
      stop_awaiter(later_awaiter)
      stop_awaiter(ready_awaiter)
    end)
  end

  test "SPEC.md §5.4 queued model lanes skip active-cap-blocked tenant heads" do
    blocked_tenant_id = Ecto.UUID.generate()
    ready_tenant_id = Ecto.UUID.generate()

    with_queue_admission_config(queue_config(max_active_per_tenant: 1), fn ->
      assert {:ok, active_grant} =
               QueueManager.acquire(
                 admission_request("req-lanes-active-cap-held",
                   tenant_id: blocked_tenant_id,
                   model_id: "blocked-active-model"
                 )
               )

      assert {:queued, blocked_ticket} =
               QueueManager.acquire(
                 admission_request("req-lanes-active-cap-blocked",
                   tenant_id: blocked_tenant_id,
                   model_id: "blocked-active-model"
                 ),
                 config: queue_config(capacity: 0, max_active_per_tenant: 1)
               )

      assert {:queued, ready_ticket} =
               QueueManager.acquire(
                 admission_request("req-lanes-active-cap-ready",
                   tenant_id: ready_tenant_id,
                   model_id: "ready-active-model"
                 ),
                 config: queue_config(capacity: 0, max_active_per_tenant: 1)
               )

      blocked_awaiter = await_and_hold(blocked_ticket, :blocked_active_cap)
      ready_awaiter = await_and_hold(ready_ticket, :ready_active_cap)

      assert wait_until(fn -> queue_entry_awaiting?(blocked_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ready_ticket) end)

      assert QueueManager.queued_model_lanes() == [{"ready-active-model", "v1"}]

      assert :ok = QueueManager.abandon(blocked_ticket)
      assert :ok = QueueManager.abandon(ready_ticket)
      assert :ok = QueueManager.release(active_grant)
      stop_awaiter(blocked_awaiter)
      stop_awaiter(ready_awaiter)
    end)
  end

  test "SPEC.md §5.4 queued model lanes skip missing awaiters and blocked lanes" do
    waiting_tenant_id = Ecto.UUID.generate()
    blocked_tenant_id = Ecto.UUID.generate()
    ready_tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 0)

    with_queue_admission_config(config, fn ->
      assert {:queued, waiting_ticket} =
               QueueManager.acquire(
                 admission_request("req-lanes-no-awaiter",
                   tenant_id: waiting_tenant_id,
                   model_id: "no-awaiter-model"
                 )
               )

      assert {:queued, blocked_ticket} =
               QueueManager.acquire(
                 admission_request("req-lanes-blocked-lane",
                   tenant_id: blocked_tenant_id,
                   model_id: "blocked-lane-model"
                 )
               )

      assert {:queued, ready_ticket} =
               QueueManager.acquire(
                 admission_request("req-lanes-ready-lane",
                   tenant_id: ready_tenant_id,
                   model_id: "ready-lane-model"
                 )
               )

      blocked_awaiter = await_and_hold(blocked_ticket, :blocked_lane)
      ready_awaiter = await_and_hold(ready_ticket, :ready_lane)

      assert wait_until(fn -> queue_entry_awaiting?(blocked_ticket) end)
      assert wait_until(fn -> queue_entry_awaiting?(ready_ticket) end)

      :sys.replace_state(QueueManager, fn state ->
        lane = Map.fetch!(state.lanes, blocked_ticket.queue_key)
        lanes = Map.put(state.lanes, blocked_ticket.queue_key, %{lane | block_ref: make_ref()})
        %{state | lanes: lanes}
      end)

      assert QueueManager.queued_model_lanes() == [{"ready-lane-model", "v1"}]

      assert :ok = QueueManager.abandon(waiting_ticket)
      assert :ok = QueueManager.abandon(blocked_ticket)
      assert :ok = QueueManager.abandon(ready_ticket)
      stop_awaiter(blocked_awaiter)
      stop_awaiter(ready_awaiter)
    end)
  end

  test "SPEC.md §5.4 requeued active grants preserve original same-tenant FIFO order" do
    tenant_id = Ecto.UUID.generate()
    config = queue_config(capacity: 2, max_wait_ms: 5_000, poll_interval_ms: 50)

    with_queue_admission_config(config, fn ->
      request_a = admission_request("req-requeue-fifo-a", tenant_id: tenant_id)
      request_b = admission_request("req-requeue-fifo-b", tenant_id: tenant_id)

      assert {:ok, grant_a} = QueueManager.acquire(request_a)
      assert {:ok, grant_b} = QueueManager.acquire(request_b)

      assert {:queued, ticket_a} = QueueManager.requeue(grant_a, request_a)
      assert {:queued, ticket_b} = QueueManager.requeue(grant_b, request_b)

      assert {:ok, requeued_grant_a} = QueueManager.await(ticket_a)
      assert {:ok, requeued_grant_b} = QueueManager.await(ticket_b)

      assert requeued_grant_a.queued_at == ticket_a.queued_at
      assert requeued_grant_b.queued_at == ticket_b.queued_at
      assert :ok = QueueManager.release(requeued_grant_a)
      assert :ok = QueueManager.release(requeued_grant_b)
    end)
  end

  test "SPEC.md §5.4 weighted promotion skips tenants blocked by active cap" do
    tenant_a = Ecto.UUID.generate()
    tenant_b = Ecto.UUID.generate()

    config =
      queue_config(max_active_per_tenant: 1, tenant_weights: %{tenant_a => 2, tenant_b => 1})

    with_queue_admission_config(config, fn ->
      assert {:ok, active_a} =
               QueueManager.acquire(
                 admission_request("req-weighted-active-cap-held-a",
                   tenant_id: tenant_a,
                   model_id: "queue-model-a"
                 )
               )

      assert {:ok, active_b} =
               QueueManager.acquire(
                 admission_request("req-weighted-active-cap-held-b",
                   tenant_id: tenant_b,
                   model_id: "queue-model-b"
                 )
               )

      assert {:queued, ticket_a} =
               QueueManager.acquire(
                 admission_request("req-weighted-active-cap-a",
                   tenant_id: tenant_a,
                   model_id: "queue-model-a"
                 )
               )

      assert {:queued, ticket_b} =
               QueueManager.acquire(
                 admission_request("req-weighted-active-cap-b",
                   tenant_id: tenant_b,
                   model_id: "queue-model-b"
                 )
               )

      awaiter_a = await_and_hold(ticket_a, :tenant_a)
      awaiter_b = await_and_hold(ticket_b, :tenant_b)

      assert wait_until(fn -> queue_entry_awaiting?(ticket_a) end)
      assert wait_until(fn -> queue_entry_awaiting?(ticket_b) end)

      assert :ok = QueueManager.release(active_b)
      assert_receive {:await_result, :tenant_b, {:ok, grant_b}}, 1_000
      assert grant_b.queue_key == "queue-model-b@v1"
      refute_receive {:await_result, :tenant_a, {:ok, _grant_a}}, 50

      assert :ok = QueueManager.release(active_a)
      assert_receive {:await_result, :tenant_a, {:ok, grant_a}}, 1_000
      assert grant_a.queue_key == "queue-model-a@v1"

      assert :ok = QueueManager.release(grant_a)
      assert :ok = QueueManager.release(grant_b)
      stop_awaiter(awaiter_a)
      stop_awaiter(awaiter_b)
    end)
  end

  test "SPEC.md §3.6 immediate grant holder death releases lane before explicit release" do
    db_request = create_request!("req_queue_immediate_holder_death", state: :admitted)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :admitted
      )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, grant} =
             QueueManager.acquire(
               admission_request("req-a",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    assert grant.queue_result == :immediate

    Process.exit(caller, :kill)
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch")

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert next_grant.queue_result == :immediate
    assert :ok = QueueManager.release(next_grant)
    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 scheduled grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:scheduled)
  end

  test "SPEC.md §3.6 dispatching grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:dispatching)
  end

  test "SPEC.md §3.6 running grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:running)
  end

  test "SPEC.md §3.6 streaming grant-owner death parks lane until terminal" do
    assert_in_flight_owner_death_parks_until_terminal(:streaming)
  end

  test "grant and ticket calls resolve a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-stable-grant"),
               server: manager,
               config: queue_config()
             )

    assert grant.server == manager

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-stable-ticket"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert ticket.server == manager

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert :ok = QueueManager.release(grant)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
  end

  test "blocked await resolves through a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-await-held"),
               server: manager,
               config: queue_config()
             )

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-await-restarted"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket, manager) end)

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert {:error, :queue_timeout, metadata} = Task.await(awaiter, 2_000)
    assert metadata.queue_result == :queue_timeout
    assert :ok = QueueManager.release(grant)
  end

  test "acquire resolves through a restarted named manager" do
    manager = unique_manager_name()
    manager_pid = start_supervised!({QueueManager, name: manager, owner_runtime: false})

    :ok = :sys.suspend(manager)

    acquire_task =
      Task.async(fn ->
        QueueManager.acquire(admission_request("req-acquire-restarted"),
          server: manager,
          config: queue_config()
        )
      end)

    Process.sleep(20)
    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    assert {:ok, grant} = Task.await(acquire_task, 2_000)
    assert grant.queue_result == :immediate
    assert grant.server == manager
    assert :ok = QueueManager.release(grant)
  end

  test "returns queue_full when tenant queued cap is exhausted" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:error, :queue_full, metadata} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_queued_per_tenant, 0)
             )

    assert metadata.queueing_enabled == true
    assert metadata.queue_key == "queue-model@v1"
    assert metadata.queue_result == :queue_full
    assert :ok = QueueManager.release(grant)
  end

  test "bounded queued waits return queue_timeout metadata" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
    assert metadata.queued_at != nil
    assert metadata.queue_wait_ms >= 0
    refute ticket_result?(ticket)

    assert :ok = QueueManager.release(grant)
  end

  test "pre-await queue timeout result is retained until consumed" do
    db_request = create_request!("req_queue_timeout_pre_await")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id
               ),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert ticket_result?(ticket)

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout
    refute ticket_result?(ticket)

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 queue timeout persistence retry does not stall other tenants" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_timeout_persistence_retry"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-timeout-retry-held"),
               config: queue_config()
             )

    assert {:queued, timeout_ticket} =
             QueueManager.acquire(
               admission_request("req-timeout-retry",
                 request_id: request_id,
                 public_id: public_id
               ),
               config: queue_config(max_wait_ms: 20, poll_interval_ms: 50)
             )

    assert {:queued, next_ticket} =
             QueueManager.acquire(admission_request("req-timeout-retry-next"),
               config: queue_config(max_wait_ms: 2_000)
             )

    next_awaiter = Task.async(fn -> QueueManager.await(next_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(next_ticket) end)
    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)
    assert :ok = QueueManager.abandon(timeout_ticket)
    assert queue_entry_terminal_pending?(timeout_ticket)

    assert :ok = QueueManager.release(held_grant)
    assert {:ok, next_grant} = Task.await(next_awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert queue_entry_terminal_pending?(timeout_ticket)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(timeout_ticket)
    assert metadata.queue_result == :queue_timeout

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert :ok = QueueManager.release(next_grant)
  end

  test "SPEC.md §3.6 timeout persistence retry keeps timeout after caller death" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_timeout_retry_then_disconnect"
    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-timeout-retry-death-held"),
               config: queue_config()
             )

    assert {:queued, timeout_ticket} =
             QueueManager.acquire(
               admission_request("req-timeout-retry-death",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 20, poll_interval_ms: 50)
             )

    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)
    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(timeout_ticket) end)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)
    assert {:error, :queue_timeout, metadata} = QueueManager.await(timeout_ticket)
    assert metadata.queue_result == :queue_timeout

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert :ok = QueueManager.release(held_grant)
  end

  test "SPEC.md §3.6 queue timeout terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_timeout_#{mode}", state: :queued)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :timed_out
          )
      end

      assert {:ok, grant} =
               QueueManager.acquire(admission_request("req-timeout-held-#{mode}"),
                 config: queue_config()
               )

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-timeout-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id
                 ),
                 config: Keyword.put(queue_config(), :max_wait_ms, 10)
               )

      assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
      assert metadata.queue_result == :queue_timeout

      request = Requests.get_request!(db_request.id)
      assert request.state == :timed_out
      assert request.error_code == "queue_timeout"
      assert_queue_metadata(request, "queue_timeout", queued?: true)

      assert :ok = QueueManager.release(grant)
    end)
  end

  test "queued caller disconnect is removed and terminalized before dispatch" do
    db_request = create_request!("req_queue_disconnect")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :interrupted_before_dispatch
    assert metadata.queued_at != nil
    refute ticket_result?(ticket)

    request = Requests.get_request!(db_request.id)
    assert request.state == :cancelled
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §3.6 queued disconnect persistence retry does not stall other tenants" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_disconnect_persistence_retry"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-disconnect-retry-held"),
               config: queue_config()
             )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, disconnect_ticket} =
             QueueManager.acquire(
               admission_request("req-disconnect-retry",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(poll_interval_ms: 50)
             )

    assert {:queued, next_ticket} =
             QueueManager.acquire(admission_request("req-disconnect-retry-next"),
               config: queue_config(max_wait_ms: 2_000)
             )

    next_awaiter = Task.async(fn -> QueueManager.await(next_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(next_ticket) end)

    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(disconnect_ticket) end)

    assert :ok = QueueManager.release(held_grant)
    assert {:ok, next_grant} = Task.await(next_awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert queue_entry_terminal_pending?(disconnect_ticket)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} =
             QueueManager.await(disconnect_ticket)

    assert metadata.queue_result == :interrupted_before_dispatch

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(next_grant)
  end

  test "SPEC.md §3.6 disconnect persistence retry keeps disconnect after timeout" do
    request_id = Ecto.UUID.generate()
    public_id = "req_queue_disconnect_retry_then_timeout"

    assert {:ok, held_grant} =
             QueueManager.acquire(admission_request("req-disconnect-retry-timeout-held"),
               config: queue_config()
             )

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, disconnect_ticket} =
             QueueManager.acquire(
               admission_request("req-disconnect-retry-timeout",
                 request_id: request_id,
                 public_id: public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 50, poll_interval_ms: 50)
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> queue_entry_terminal_pending?(disconnect_ticket) end)
    Process.sleep(80)
    assert queue_entry_terminal_pending?(disconnect_ticket)

    db_request = insert_request_with_id!(request_id, public_id, state: :queued)

    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    assert {:error, :request_caller_disconnect, metadata} =
             QueueManager.await(disconnect_ticket)

    assert metadata.queue_result == :interrupted_before_dispatch

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(held_grant)
  end

  test "SPEC.md §3.6 queued caller disconnect terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_disconnect_#{mode}", state: :queued)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :cancelled
          )
      end

      assert {:ok, grant} =
               QueueManager.acquire(admission_request("req-disconnect-held-#{mode}"),
                 config: queue_config()
               )

      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:queued, ticket} =
               QueueManager.acquire(
                 admission_request("req-disconnect-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id,
                   caller_pid: caller
                 ),
                 config: queue_config()
               )

      Process.exit(caller, :kill)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      assert {:error, :request_caller_disconnect, metadata} = QueueManager.await(ticket)
      assert metadata.queue_result == :interrupted_before_dispatch

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert :ok = QueueManager.release(grant)
    end)
  end

  test "startup reconciliation interrupts stale pre-dispatch requests" do
    admitted =
      create_request!("req_queue_restarted_admitted",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    queued =
      create_request!("req_queue_restarted_queued",
        state: :queued,
        scheduler_decision: %{
          queueing_enabled: true,
          queue_key: "queue-model@v1",
          queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )

    start_supervised!({QueueManager, name: unique_manager_name(), owner_runtime: true})

    admitted = Requests.get_request!(admitted.id)
    queued = Requests.get_request!(queued.id)

    assert admitted.state == :interrupted
    assert admitted.error_code == "request_controller_restarted"
    assert_queue_metadata(admitted, "interrupted_controller_restarted")

    assert queued.state == :interrupted
    assert queued.error_code == "request_controller_restarted"
    assert_queue_metadata(queued, "interrupted_controller_restarted", queued?: true)
  end

  test "startup reconciliation is gated behind owner runtime flag" do
    admitted =
      create_request!("req_queue_non_owner_admitted",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    start_supervised!({QueueManager, name: unique_manager_name(), owner_runtime: false})

    admitted = Requests.get_request!(admitted.id)
    assert admitted.state == :admitted
    assert admitted.error_code == nil
  end

  test "startup reconciliation reclaims pre-dispatch rows after boot-token child restart" do
    boot_token = {__MODULE__, System.unique_integer([:positive])}

    stale =
      create_request!("req_queue_boot_token_stale",
        state: :admitted,
        scheduler_decision: %{queueing_enabled: true, queue_key: "queue-model@v1"}
      )

    create_request!("req_queue_boot_token_running",
      state: :running,
      scheduler_decision: %{
        queueing_enabled: true,
        queue_key: "queue-model@v1",
        queue_result: "immediate",
        queue_grant_id: "grant-boot-token-running",
        queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    )

    manager = unique_manager_name()

    manager_pid =
      start_supervised!(
        {QueueManager,
         name: manager, owner_runtime: true, startup_reconciliation: {:once, boot_token}}
      )

    stale = Requests.get_request!(stale.id)
    assert stale.state == :interrupted
    assert stale.error_code == "request_controller_restarted"

    live =
      create_request!("req_queue_boot_token_child_restart",
        state: :queued,
        scheduler_decision: pre_dispatch_scheduler_decision(:queued)
      )

    {:ok, _pid} =
      RequestServer.start(
        request_id: live.id,
        public_id: live.public_id,
        initial_state: :queued
      )

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    live = Requests.get_request!(live.id)
    assert live.state == :interrupted
    assert live.error_code == "request_controller_restarted"
    assert_queue_metadata(live, "interrupted_controller_restarted", queued?: true)

    assert :ok = QueueManager.release("grant-boot-token-running", server: manager)

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-after-child-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert grant.queue_result == :immediate
    assert :ok = QueueManager.release(grant)
  end

  test "startup reconciliation interrupts pre-dispatch rows after child restart" do
    assert_pre_dispatch_interrupted_after_child_restart(:admitted)
    assert_pre_dispatch_interrupted_after_child_restart(:queued)
  end

  test "startup reconciliation reconstructs active grant ownership" do
    create_request!("req_queue_recovered_active",
      state: :scheduled,
      scheduler_decision: %{
        queueing_enabled: true,
        queue_key: "queue-model@v1",
        queue_result: "immediate",
        queue_grant_id: "grant-recovered",
        queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-after-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 200)
             )

    assert :ok = QueueManager.release("grant-recovered", server: manager)
    assert {:ok, grant} = QueueManager.await(ticket)
    assert grant.queue_result == :queued

    assert :ok = QueueManager.release(grant)
  end

  test "SPEC.md §5.5 recovered grant with persisted node does not reserve other nodes" do
    recovered_node_id = Ecto.UUID.generate()
    observed_node_id = Ecto.UUID.generate()

    create_request!("req_queue_recovered_known_node",
      state: :running,
      node_id: recovered_node_id,
      scheduler_decision: %{
        queueing_enabled: true,
        queue_key: "queue-model@v1",
        queue_result: "immediate",
        queue_grant_id: "grant-recovered-known-node",
        queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-after-known-node-recovery",
                 model_id: "known-node-recovery-other"
               ),
               server: manager,
               config: queue_config(capacity: 0, max_wait_ms: 1_000)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket, manager) end)

    assert :ok =
             QueueManager.refresh_node_capacity_sources(
               %{
                 clear_sources: [
                   {:node, observed_node_id},
                   {:node, observed_node_id, :placement},
                   {:node, observed_node_id, :cold}
                 ],
                 placement_source: {:node, observed_node_id, :placement},
                 cold_source: {:node, observed_node_id, :cold},
                 node_id: observed_node_id,
                 node_active: 0,
                 node_max: 1,
                 placements: []
               },
               server: manager
             )

    assert {:ok, grant} = Task.await(awaiter, 2_000)
    assert grant.queue_result == :queued
    assert grant.queue_key == "known-node-recovery-other@v1"

    assert :ok = QueueManager.release(grant, server: manager)
    assert :ok = QueueManager.release("grant-recovered-known-node", server: manager)
  end

  test "SPEC.md §5.3 recovered active grants count against tenant concurrency" do
    tenant_id = Ecto.UUID.generate()

    recovered_request =
      create_request!("req_queue_recovered_tenant_active",
        tenant_id: tenant_id,
        requested_model: "queue-model-a@v1",
        state: :running,
        scheduler_decision: %{
          queueing_enabled: true,
          queue_key: "queue-model-a@v1",
          queue_result: "immediate",
          queue_grant_id: "grant-recovered-tenant-active",
          queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-after-tenant-active-recovery",
                 tenant_id: tenant_id,
                 model_id: "queue-model-b"
               ),
               server: manager,
               config: queue_config(capacity: 2, max_active_per_tenant: 1)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket, manager) end)
    refute Task.yield(awaiter, 100)

    assert {:ok, _request} =
             Requests.mark_terminal(recovered_request, %{state: :completed, output_tokens: 1})

    assert {:ok, grant} = Task.await(awaiter, 2_000)
    assert grant.queue_result == :queued
    assert grant.queue_key == "queue-model-b@v1"

    assert :ok = QueueManager.release(grant, server: manager)
  end

  test "reconstructed legacy in-flight lane remains occupied until terminal" do
    request =
      create_request!("req_queue_recovered_legacy",
        state: :running,
        scheduler_decision: %{strategy: "single_node"}
      )

    manager = unique_manager_name()
    start_supervised!({QueueManager, name: manager, owner_runtime: true})

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-after-legacy-recovery"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert {:ok, _request} =
             Requests.mark_terminal(request, %{state: :completed, output_tokens: 1})

    assert {:ok, grant} = QueueManager.await(ticket)
    assert grant.queue_result == :queued

    assert :ok = QueueManager.release(grant)
  end

  test "await timeout removes queued entry before later lane release" do
    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    assert {:queued, ticket} =
             QueueManager.acquire(admission_request("req-b"),
               config: Keyword.put(queue_config(), :max_wait_ms, 10)
             )

    assert {:error, :queue_timeout, metadata} = QueueManager.await(ticket)
    assert metadata.queue_result == :queue_timeout

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert next_grant.queue_result == :immediate
    assert :ok = QueueManager.release(next_grant)
  end

  test "abandoned awaiter removes queued entry and terminalizes before dispatch" do
    db_request = create_request!("req_queue_abandoned_waiter")
    {:ok, _pid} = RequestServer.start(request_id: db_request.id, public_id: db_request.public_id)

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert Process.alive?(awaiter)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    Process.exit(awaiter, :kill)

    assert wait_until(fn ->
             request = Requests.get_request!(db_request.id)
             request.state == :cancelled and request.error_code == "request_caller_disconnect"
           end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 release before dead awaiter DOWN cancels without active grant" do
    db_request = create_request!("req_queue_dead_waiter_grant", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 1_000)
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    :ok = :sys.suspend(QueueManager)

    try do
      release_task =
        Task.async(fn ->
          QueueManager.release(grant)
        end)

      Process.sleep(20)
      Process.exit(awaiter, :kill)
      resume_manager(QueueManager)

      assert :ok = Task.await(release_task, 2_000)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-c"), config: queue_config())

      assert :ok = QueueManager.release(next_grant)

      Process.exit(caller, :kill)
    after
      resume_manager(QueueManager)
    end
  end

  test "SPEC.md §3.6 pre-dispatch grant-owner disconnect terminalizes when RequestServer is missing or terminal" do
    Enum.each([:missing_request_server, :already_terminal_request_server], fn mode ->
      db_request = create_request!("req_queue_grant_owner_disconnect_#{mode}", state: :admitted)

      if mode == :already_terminal_request_server do
        {:ok, _pid} =
          RequestServer.start(
            request_id: db_request.id,
            public_id: db_request.public_id,
            initial_state: :cancelled
          )
      end

      caller = spawn(fn -> Process.sleep(:infinity) end)

      assert {:ok, grant} =
               QueueManager.acquire(
                 admission_request("req-grant-owner-disconnect-#{mode}",
                   request_id: db_request.id,
                   public_id: db_request.public_id,
                   caller_pid: caller
                 ),
                 config: queue_config()
               )

      Process.exit(caller, :kill)
      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch")

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-after-grant-owner-#{mode}"),
                 config: queue_config()
               )

      assert :ok = QueueManager.release(next_grant)
      assert :ok = QueueManager.release(grant)
    end)
  end

  test "SPEC.md §3.6 awaiter death after queued grant drops grant and cancels" do
    db_request = create_request!("req_queue_post_grant_waiter_death", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 1_000)
             )

    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {:post_grant_await_result, result})
    end)

    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)
    assert :ok = QueueManager.release(grant)
    assert_receive {:post_grant_await_result, {:ok, %QueueManager.Grant{}}}, 1_000
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 awaiter death after timeout reply terminalizes pre-dispatch request" do
    db_request = create_request!("req_queue_post_timeout_waiter_death", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 20)
             )

    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {:post_timeout_await_result, result})
    end)

    assert_receive {:post_timeout_await_result, {:error, :queue_timeout, metadata}}, 1_000
    assert metadata.queue_result == :queue_timeout
    assert wait_until(fn -> Requests.get_request!(db_request.id).state == :timed_out end)

    request = Requests.get_request!(db_request.id)
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)

    assert :ok = QueueManager.release(grant)

    assert {:ok, next_grant} =
             QueueManager.acquire(admission_request("req-c"), config: queue_config())

    assert :ok = QueueManager.release(next_grant)

    Process.exit(caller, :kill)
  end

  test "SPEC.md §3.6 timeout before dead awaiter DOWN terminalizes pre-dispatch request" do
    db_request = create_request!("req_queue_dead_waiter_timeout", state: :queued)

    {:ok, _pid} =
      RequestServer.start(
        request_id: db_request.id,
        public_id: db_request.public_id,
        initial_state: :queued
      )

    assert {:ok, grant} = QueueManager.acquire(admission_request("req-a"), config: queue_config())

    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("req-b",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config(max_wait_ms: 200)
             )

    awaiter = spawn(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    :ok = :sys.suspend(QueueManager)

    try do
      Process.sleep(250)
      Process.exit(awaiter, :kill)
      resume_manager(QueueManager)

      assert wait_until(fn -> Requests.get_request!(db_request.id).state == :cancelled end)

      request = Requests.get_request!(db_request.id)
      assert request.error_code == "request_caller_disconnect"
      assert_queue_metadata(request, "interrupted_before_dispatch", queued?: true)

      assert :ok = QueueManager.release(grant)

      assert {:ok, next_grant} =
               QueueManager.acquire(admission_request("req-c"), config: queue_config())

      assert :ok = QueueManager.release(next_grant)

      Process.exit(caller, :kill)
    after
      resume_manager(QueueManager)
    end
  end

  defp assert_in_flight_owner_death_parks_until_terminal(request_state) do
    public_id = "req_queue_#{request_state}_owner_death"
    db_request = create_request!(public_id, state: request_state)

    assert_dead_owner_parks_grant_until_terminal(db_request,
      state_before_terminal: request_state,
      terminal_attrs: %{state: :completed, output_tokens: 1}
    )
  end

  defp assert_pre_dispatch_interrupted_after_child_restart(request_state) do
    boot_token = {__MODULE__, request_state, System.unique_integer([:positive])}
    manager = unique_manager_name()

    manager_pid =
      start_supervised!(
        {QueueManager,
         name: manager, owner_runtime: true, startup_reconciliation: {:once, boot_token}},
        id: {QueueManager, manager}
      )

    live =
      create_request!("req_queue_child_restart_#{request_state}",
        state: request_state,
        scheduler_decision: pre_dispatch_scheduler_decision(request_state)
      )

    {:ok, _pid} =
      RequestServer.start(
        request_id: live.id,
        public_id: live.public_id,
        initial_state: request_state
      )

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(manager, manager_pid) end)

    live = Requests.get_request!(live.id)
    assert live.state == :interrupted
    assert live.error_code == "request_controller_restarted"

    assert_queue_metadata(live, "interrupted_controller_restarted",
      queued?: request_state == :queued
    )

    assert {:ok, grant} =
             QueueManager.acquire(admission_request("req-after-#{request_state}-restart"),
               server: manager,
               config: queue_config(max_wait_ms: 500)
             )

    assert grant.queue_result == :immediate
    assert :ok = QueueManager.release(grant)
  end

  defp pre_dispatch_scheduler_decision(:admitted) do
    %{
      queueing_enabled: true,
      queue_key: "queue-model@v1",
      queue_result: "immediate",
      queue_grant_id: "grant-child-restart-admitted",
      queue_granted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp pre_dispatch_scheduler_decision(:queued) do
    %{
      queueing_enabled: true,
      queue_key: "queue-model@v1",
      queue_result: "queued",
      queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp assert_dead_owner_parks_grant_until_terminal(db_request, opts) do
    caller = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, grant} =
             QueueManager.acquire(
               admission_request("#{db_request.public_id}-held",
                 request_id: db_request.id,
                 public_id: db_request.public_id,
                 caller_pid: caller
               ),
               config: queue_config()
             )

    Process.exit(caller, :kill)
    assert wait_until(fn -> grant_parked?(grant) end)

    request = Requests.get_request!(db_request.id)
    assert request.state == Keyword.fetch!(opts, :state_before_terminal)

    assert {:queued, ticket} =
             QueueManager.acquire(
               admission_request("#{db_request.public_id}-next"),
               config: queue_config(max_wait_ms: 1_000)
             )

    awaiter = Task.async(fn -> QueueManager.await(ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(ticket) end)

    assert {:ok, _request} =
             Requests.mark_terminal(db_request, Keyword.fetch!(opts, :terminal_attrs))

    assert {:ok, next_grant} = Task.await(awaiter, 2_000)
    assert next_grant.queue_result == :queued
    assert :ok = QueueManager.release(next_grant)
    assert :ok = QueueManager.release(grant)
  end

  defp admission_request(public_id, overrides \\ []) do
    %{
      request_id: Keyword.get(overrides, :request_id, Ecto.UUID.generate()),
      public_id: Keyword.get(overrides, :public_id, public_id),
      tenant_id: Keyword.get(overrides, :tenant_id, Ecto.UUID.generate()),
      model_id: Keyword.get(overrides, :model_id, "queue-model"),
      version: Keyword.get(overrides, :version, "v1"),
      caller_pid: Keyword.get(overrides, :caller_pid, self())
    }
  end

  defp queue_config(overrides \\ []) do
    Keyword.merge(
      [
        enabled: true,
        max_wait_ms: 500,
        max_active_per_tenant: nil,
        max_queued_per_tenant: 32,
        poll_interval_ms: 1,
        capacity: 1,
        owner_runtime: true
      ],
      overrides
    )
  end

  defp assert_busy_requeue_retires_source(reason) do
    node_id = Ecto.UUID.generate()
    config = queue_config(capacity: 0, max_wait_ms: 1_000, poll_interval_ms: 50)
    first_model_id = "source-requeue-#{reason}-a"

    with_queue_admission_config(config, fn ->
      first_tag = :"source_requeue_#{reason}_first"

      first_request =
        admission_request("req-node-source-requeue-#{reason}-a", model_id: first_model_id)

      assert {:queued, first_ticket} = QueueManager.acquire(first_request)
      first_awaiter = start_holding_awaiter(first_ticket, first_tag)

      assert :ok = refresh_node_source_capacity(node_id)
      assert_receive {^first_tag, {:ok, first_grant}}, 2_000

      assert_requeued_source_does_not_grant_other_lane(reason, first_request, first_grant, config)

      send(first_awaiter, :stop)
    end)
  end

  defp assert_requeued_source_does_not_grant_other_lane(
         reason,
         first_request,
         first_grant,
         config
       ) do
    assert {:queued, second_ticket} =
             QueueManager.acquire(
               admission_request("req-node-source-requeue-#{reason}-b",
                 model_id: "source-requeue-#{reason}-b"
               )
             )

    second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)
    assert wait_until(fn -> queue_entry_awaiting?(second_ticket) end)

    assert {:queued, retry_ticket} =
             QueueManager.requeue(first_grant, first_request, config: config)

    refute Task.yield(second_awaiter, 100)

    assert :ok = QueueManager.abandon(second_ticket)
    assert :ok = QueueManager.abandon(retry_ticket)
    Task.shutdown(second_awaiter)
  end

  defp refresh_node_source_capacity(node_id) do
    QueueManager.refresh_node_capacity_sources(%{
      clear_sources: [
        {:node, node_id},
        {:node, node_id, :placement},
        {:node, node_id, :cold}
      ],
      placement_source: {:node, node_id, :placement},
      cold_source: {:node, node_id, :cold},
      node_id: node_id,
      node_active: 0,
      node_max: 1,
      placements: []
    })
  end

  defp with_queue_admission_config(queue_admission_config, fun) do
    previous = Application.fetch_env!(:orchard_controller, :inference)

    previous
    |> Keyword.put(:queue_admission, queue_admission_config)
    |> then(&Application.put_env(:orchard_controller, :inference, &1))

    try do
      fun.()
    after
      QueueManager.reset()
      Application.put_env(:orchard_controller, :inference, previous)
    end
  end

  defp start_holding_awaiter(ticket, tag) do
    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {tag, result})

      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp await_and_hold(ticket, label) do
    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {:await_result, label, result})

      receive do
        :stop -> :ok
      after
        2_000 -> :ok
      end
    end)
  end

  defp stop_awaiter(pid) do
    send(pid, :stop)
  end

  defp queue_entry_awaiting?(ticket, manager \\ QueueManager) do
    manager
    |> :sys.get_state()
    |> Map.get(:entries)
    |> Map.get(ticket.ticket_ref)
    |> case do
      %{await_from: await_from} when await_from != nil -> true
      _other -> false
    end
  end

  defp ticket_result?(ticket) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:ticket_results)
    |> Map.has_key?(ticket.ticket_ref)
  end

  defp queue_entry_terminal_pending?(ticket) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:entries)
    |> Map.get(ticket.ticket_ref)
    |> case do
      %{terminal_operation: operation, terminal_retry_ref: retry_ref}
      when operation != nil and is_reference(retry_ref) ->
        true

      _other ->
        false
    end
  end

  defp grant_parked?(grant) do
    QueueManager
    |> :sys.get_state()
    |> Map.get(:grants)
    |> Map.get(grant.grant_id)
    |> case do
      %{recovered?: true} -> true
      _other -> false
    end
  end

  defp manager_restarted?(manager, previous_pid) do
    case GenServer.whereis(manager) do
      pid when is_pid(pid) and pid != previous_pid -> true
      _other -> false
    end
  end

  defp resume_manager(manager) do
    :sys.resume(manager)
  catch
    :exit, _reason -> :ok
  end

  defp unique_manager_name do
    Module.concat(__MODULE__, "Manager#{System.unique_integer([:positive])}")
  end

  defp create_request!(public_id, overrides \\ []) do
    attrs = request_attrs(public_id, overrides)

    {:ok, request} = Requests.create_request(attrs)

    request
  end

  defp insert_request_with_id!(request_id, public_id, overrides) do
    %Request{id: request_id}
    |> Request.create_changeset(request_attrs(public_id, overrides))
    |> Repo.insert!()
  end

  defp request_attrs(public_id, overrides) do
    Keyword.merge(
      [
        public_id: public_id,
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        requested_model: "queue-model@v1",
        state: :received,
        stream: false,
        payload_capture_mode: :metadata
      ],
      overrides
    )
    |> Map.new()
  end
end
