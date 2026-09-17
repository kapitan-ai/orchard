defmodule Orchard.Node.WorkerRecoveryStateTest do
  use ExUnit.Case, async: true
  alias Orchard.Node.WorkerRecoveryState, as: State

  test "SPEC §12.2 absence differs from unavailable hydration" do
    entry = State.new("epoch")
    refute State.projection(entry).eligible
    assert entry |> State.hydrate(:absent) |> State.projection() |> Map.fetch!(:eligible)
  end

  test "SPEC §12.2 late stability acknowledgement cannot erase a newer crash" do
    entry = State.new("epoch") |> State.hydrate(:absent)
    entry = State.transition(entry, {:admit, "worker"}, 0)
    {entry, _} = acknowledge(entry, 0)
    entry = State.transition(entry, {:loaded, "worker"}, 0)
    {entry, _} = acknowledge(entry, 0)
    entry = State.transition(entry, :tick, 600_000, [:publish_reset])
    {:write, entry, pending} = State.begin_write(entry, 600_000)
    entry = State.transition(entry, {:crash, "worker"}, 600_000)
    {entry, []} = State.acknowledge(entry, pending.id, response(pending))
    assert entry.policy.history == [600_000]
    assert entry.policy.state == :backoff
    {entry, effects} = acknowledge(entry, 600_000)
    assert {:schedule, entry.policy.fence, 601_000} in effects
    refute :publish_reset in effects
  end

  test "SPEC §12.2 retries preserve the exact mutation and reject invented acknowledgement" do
    entry =
      State.new("epoch") |> State.hydrate(:absent) |> State.transition({:admit, "worker"}, 0)

    {:write, entry, pending} = State.begin_write(entry, 0)

    assert {^entry, []} =
             State.acknowledge(entry, pending.id, %{response(pending) | revision: 99})

    entry = State.unavailable(entry, pending.id, 0)
    assert {:wait, ^entry} = State.retry(entry, 999)
    assert {:write, _, ^pending} = State.retry(entry, 1_000)
  end

  test "SPEC §12.2 superseded checkpoint effects remain available exactly once" do
    entry =
      State.new("epoch")
      |> State.checkpoint([{:spawn_worker, self(), {self(), make_ref()}}])
      |> State.checkpoint([{:hydration_complete, [{self(), make_ref()}]}])

    {entry, superseded} = State.take_superseded_effects(entry)

    assert [{:spawn_worker, _task_pid, {_caller_pid, _tag}}] = superseded
    assert {^entry, []} = State.take_superseded_effects(entry)
  end

  test "SPEC §12.2 bare await cleanup blocks admission with a deterministic recovery reason" do
    entry = State.new("epoch") |> State.hydrate(:absent) |> State.checkpoint([:await_cleanup])

    assert State.refusal(entry) == :placement_recovery_required

    assert %{eligible: false, reason: "placement_recovery_required", state: "recovery_required"} =
             State.projection(entry)
  end

  test "SPEC §12.2 fresh epochs retain nonclean checkpoints without rebasing clocks" do
    entry =
      State.new("old") |> State.hydrate(:absent) |> State.transition({:admit, "worker"}, -9_000)

    entry = State.transition(entry, {:crash, "worker"}, -8_000)
    record = State.record(entry)
    restored = State.hydrate(State.new("new"), %{epoch: "old", revision: 8, record: record})
    assert restored.policy.state == :recovery_required
    assert restored.policy.history == [-8_000]
    assert restored.policy.delay_index == 1
    assert restored.owner_epoch == "old"
    refute State.projection(restored).eligible
    assert restored.policy.due_ms == nil
  end

  defp acknowledge(entry, now) do
    {:write, entry, pending} = State.begin_write(entry, now)
    State.acknowledge(entry, pending.id, response(pending))
  end

  defp response(pending),
    do: %{
      epoch: pending.record["epoch"],
      revision: pending.revision + 1,
      record: pending.record,
      transition_id: pending.id
    }
end
