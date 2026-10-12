defmodule Orchard.Node.WorkerCrashPolicyTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.WorkerCrashPolicy, as: Policy

  # SPEC §12.2 and worker-crash-recovery deterministic acceptance matrix.
  test "sparse crashes reach the production 16/30-second tail without opening" do
    crashes = [0, 150_000, 300_000, 450_000, 601_000, 752_000, 903_000]
    delays = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]

    final =
      crashes
      |> Enum.zip(delays)
      |> Enum.reduce(admitted(Policy.new(), :initial), fn {now, delay}, record ->
        {record, effects} = Policy.transition(record, {:crash, record.incarnation}, now)
        assert record.state == :backoff
        assert record.due_ms == now + delay
        assert effects == [:checkpoint, {:schedule, record.fence, now + delay}]
        assert length(record.history) <= 4
        restarted(record)
      end)

    assert final.delay_index == 6
  end

  test "fifth crash opens before scheduling and never expires or probes" do
    record = open_record()
    assert record.state == :open
    assert length(record.history) == 5
    assert record.delay_index == 5
    assert record.due_ms == nil

    for now <- [50_000, 600_000, 60_000_000],
        event <- [:tick, {:timer, record.fence, true}, {:loaded, 4}, {:crash, 4}] do
      assert Policy.transition(record, event, now) == {record, []}
    end
  end

  test "rolling window excludes exactly ten minutes and includes one millisecond newer" do
    for {first, count, state} <- [{0, 4, :backoff}, {1, 5, :open}] do
      record =
        Enum.reduce(
          [first, 150_000, 300_000, 450_000],
          admitted(Policy.new(), :initial),
          fn now, record ->
            {record, _} = Policy.transition(record, {:crash, record.incarnation}, now)
            restarted(record)
          end
        )

      {record, _} = Policy.transition(record, {:crash, record.incarnation}, 600_000)
      assert length(record.history) == count
      assert record.state == state
    end
  end

  test "stability resets exactly at ten loaded minutes before a boundary crash" do
    record = first_crash() |> restarted()
    since = record.loaded_since

    {early, _} = Policy.transition(record, {:crash, record.incarnation}, since + 599_999)
    assert early.delay_index == 2
    assert early.due_ms == since + 599_999 + 2_000

    {boundary, effects} = Policy.transition(record, {:crash, record.incarnation}, since + 600_000)
    assert boundary.delay_index == 1
    assert boundary.history == [since + 600_000]
    assert effects == [:checkpoint, {:schedule, boundary.fence, since + 601_000}]

    {stable, [:checkpoint]} = Policy.transition(record, :tick, since + 600_000)
    assert stable.history == []
    assert stable.delay_index == 0
    assert stable.incarnation == record.incarnation
  end

  test "loading and backoff do not accrue stability and duplicate loaded does not extend it" do
    backoff = first_crash()
    assert Policy.transition(backoff, :tick, 900_000) == {backoff, []}
    {loading, _} = Policy.transition(backoff, {:timer, backoff.fence, true}, 900_000)
    loading = admitted(loading, :replacement)
    assert Policy.transition(loading, :tick, 1_800_000) == {loading, []}
    {loaded, _} = Policy.transition(loading, {:loaded, :replacement}, 1_800_000)
    assert loaded.delay_index == 1
    assert Policy.transition(loaded, {:loaded, :replacement}, 1_800_001) == {loaded, []}
  end

  test "restart requires current fence, due boundary and cleanup; fires only once" do
    record = first_crash()
    fence = record.fence
    due = record.due_ms

    for {event, now} <- [
          {{:timer, fence, true}, due - 1},
          {{:timer, fence - 1, true}, due},
          {{:timer, fence, false}, due}
        ] do
      assert Policy.transition(record, event, now) == {record, []}
    end

    {restarting, [:checkpoint, {:load, ^fence}]} =
      Policy.transition(record, {:timer, fence, true}, due)

    assert restarting.state == :restarting
    assert Policy.transition(restarting, {:timer, fence, true}, due) == {restarting, []}
  end

  test "incarnation deduplicates overlapping loss reports and fences stale completions" do
    backoff = first_crash()
    assert Policy.transition(backoff, {:crash, :first}, 1) == {backoff, []}
    assert Policy.transition(backoff, {:loaded, :first}, 1) == {backoff, []}
    {loading, _} = Policy.transition(backoff, {:timer, backoff.fence, true}, backoff.due_ms)
    loading = admitted(loading, :second)

    for event <- [{:crash, :first}, {:loaded, :first}, {:crash, nil}] do
      assert Policy.transition(loading, event, 1_001) == {loading, []}
    end

    {crashed, _} = Policy.transition(loading, {:crash, :second}, 1_001)
    assert crashed.history == [1_001, 0]
    assert crashed.delay_index == 2
  end

  test "non-crash restart failure stops automation without inventing a crash" do
    record = first_crash()
    {loading, _} = Policy.transition(record, {:timer, record.fence, true}, record.due_ms)
    {failed, effects} = Policy.transition(loading, {:restart_failed, loading.fence}, 1_001)
    assert failed.state == :recovery_required
    assert failed.history == record.history
    assert failed.delay_index == record.delay_index
    assert effects == [:checkpoint, {:cancel, loading.fence}]
    assert Policy.transition(failed, {:timer, loading.fence, true}, 2_000) == {failed, []}
    assert Policy.transition(failed, {:restart_failed, loading.fence}, 2_000) == {failed, []}
  end

  test "ordinary interruption and reset preserve history and open breakers" do
    for event <- [:interrupt, :reset], record <- [first_crash(), open_record()] do
      {stopped, effects} = Policy.transition(record, event, 50_000)
      assert stopped.history == record.history
      assert stopped.delay_index == record.delay_index
      assert stopped.state == if(record.state == :open, do: :open, else: :recovery_required)
      assert stopped.fence == record.fence + 1
      assert effects == [:checkpoint, {:cancel, record.fence}]
      assert Policy.transition(stopped, {:timer, record.fence, true}, 60_000) == {stopped, []}
    end
  end

  test "intentional clean stop is loadable; loss accepted before stop is retained" do
    clean = admitted(Policy.new(), :worker)
    {stopped, _} = Policy.transition(clean, :interrupt, 0)
    assert stopped.state == :armed
    assert Policy.transition(stopped, {:crash, :worker}, 1) == {stopped, []}
    assert admitted(stopped, :next).incarnation == :next

    {crashed, _} = Policy.transition(clean, {:crash, :worker}, 0)
    {stopped, _} = Policy.transition(crashed, :interrupt, 1)
    assert stopped.state == :recovery_required
    assert stopped.history == [0]
  end

  test "authorized clear and unload reset absent; authorized reload starts exactly one load" do
    record = open_record()

    for action <- [:clear, :unload, :reload] do
      {next, effects} = Policy.transition(record, {:authorized_recovery, action}, 50_000)
      assert next.history == []
      assert next.delay_index == 0
      assert next.incarnation == nil
      assert next.fence == record.fence + 1
      assert next.state == if(action == :reload, do: :restarting, else: :armed)
      expected = [:checkpoint, {:cancel, record.fence}]

      assert effects ==
               if(action == :reload, do: expected ++ [{:load, next.fence}], else: expected)

      assert Policy.transition(next, {:timer, record.fence, true}, 60_000) == {next, []}
    end
  end

  test "each record is isolated and monotonic timestamps may be negative" do
    clean = Policy.new()
    worker = admitted(clean, :negative)
    {failed, _} = Policy.transition(worker, {:crash, :negative}, -10_000)
    assert failed.history == [-10_000]
    assert failed.due_ms == -9_000
    assert clean == Policy.new()
  end

  # SPEC.md §12.2: delay_index and history must survive a successful automatic
  # restart so the 5-crashes-in-10-minutes breaker can still count them, but they
  # must not classify a healthy restarted placement as recovery-required when
  # capacity evicts it, which would leave it unloadable until an operator acts.
  test "an interrupt after a successful restart stays armed and keeps its crash history" do
    record = restarted(first_crash())

    assert record.state == :armed
    assert record.history != []
    assert record.delay_index > 0

    {interrupted, _effects} = Policy.transition(record, :interrupt, 60_000)

    assert interrupted.state == :armed
    assert interrupted.history == record.history
    assert interrupted.delay_index == record.delay_index
  end

  defp admitted(record, id) do
    {record, [:checkpoint]} = Policy.transition(record, {:admit, id}, 0)
    record
  end

  defp first_crash do
    record = admitted(Policy.new(), :first)
    {record, _} = Policy.transition(record, {:crash, :first}, 0)
    record
  end

  defp restarted(record) do
    due = record.due_ms
    {record, _} = Policy.transition(record, {:timer, record.fence, true}, due)
    id = {:replacement, record.fence}
    record = admitted(record, id)
    {record, _} = Policy.transition(record, {:loaded, id}, due)
    record
  end

  defp open_record do
    Enum.reduce(0..4, Policy.new(), fn index, record ->
      now = index * 10_000
      record = admitted(record, index)
      {record, effects} = Policy.transition(record, {:crash, index}, now)

      if index == 4 do
        assert effects == [:checkpoint, {:cancel, record.fence - 1}]
        record
      else
        due = record.due_ms
        {record, _} = Policy.transition(record, {:timer, record.fence, true}, due)
        record
      end
    end)
  end
end
