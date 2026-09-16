defmodule Orchard.Node.WorkerCrashPolicy do
  @moduledoc """
  Pure monotonic-time-injected placement crash policy for SPEC §12.2.

  One record belongs to one exact node/model/version in one clock epoch. `history`
  holds newest-first crash times (at most five); `delay_index` saturates at six.
  `loaded_since` measures continuous loaded time. `incarnation` is the current
  admitted worker's unique non-nil identity. `fence` invalidates prior work;
  `due_ms` is an absolute monotonic no-earlier-than restart time.

  Events are `{:admit, incarnation}`, `{:loaded, incarnation}`,
  `{:crash, incarnation}`, `{:timer, fence, cleanup_resolved?}`,
  `{:restart_failed, fence}` (non-crash failure), `:interrupt`, `:reset`,
  `:tick` (evaluate stability), and
  `{:authorized_recovery, :clear | :unload | :reload}`.

  The caller serializes events, classifies qualifying loss, and supplies never
  reused incarnation identities. Apply interruption before an intentional stop;
  interruption after accepted loss cannot erase it. Stale reports are no-ops.
  Controller disconnects and ordinary load errors are not crash events.

  Effects are declarative: checkpoint before scheduling/loading or publishing
  eligibility. Failed checkpoint acknowledgement defers effects, not a restart
  failure event. The caller owns authentication, epoch/revision fencing, recovery
  conflict checks, and cleanup proof before authorized recovery. `:admit` registers
  an already authorized worker, not an ordinary ensure request; in `:restarting`
  only the current recovery-owned load may supply it. Timer admission
  requires cleanup proof; cancellation alone does not free occupancy. Clear and
  unload arm absent; reload requests one load. Never interpret old-epoch history
  using a new epoch's clock. This module neither persists nor performs effects.
  """

  @window_ms 600_000
  @delays {1_000, 2_000, 4_000, 8_000, 16_000, 30_000}

  @type state :: :armed | :backoff | :restarting | :open | :recovery_required
  @type policy_record :: %{
          state: state(),
          history: [integer()],
          delay_index: 0..6,
          loaded_since: integer() | nil,
          incarnation: term(),
          fence: non_neg_integer(),
          due_ms: integer() | nil
        }
  @type event ::
          {:admit | :loaded | :crash, term()}
          | {:timer, non_neg_integer(), boolean()}
          | {:restart_failed, non_neg_integer()}
          | :interrupt
          | :reset
          | :tick
          | {:authorized_recovery, :clear | :unload | :reload}
  @type effect ::
          :checkpoint
          | {:schedule, non_neg_integer(), integer()}
          | {:load | :cancel, non_neg_integer()}

  @doc "Returns a clean absent placement record for the current epoch."
  @spec new() :: policy_record()
  def new do
    %{
      state: :armed,
      history: [],
      delay_index: 0,
      loaded_since: nil,
      incarnation: nil,
      fence: 0,
      due_ms: nil
    }
  end

  @doc "Applies an event at injected monotonic milliseconds without executing effects."
  @spec transition(policy_record(), event(), integer()) :: {policy_record(), [effect()]}
  def transition(record, event, now_ms) when is_integer(now_ms) do
    {next, effects} = record |> reset_stable(now_ms) |> apply_event(event, now_ms)
    if next != record, do: {next, [:checkpoint | effects]}, else: {next, effects}
  end

  defp apply_event(%{state: state, incarnation: nil} = record, {:admit, id}, _now)
       when state in [:armed, :restarting] and not is_nil(id) do
    {%{record | incarnation: id, loaded_since: nil}, []}
  end

  defp apply_event(%{incarnation: id} = record, {:loaded, id}, now)
       when not is_nil(id) do
    {%{record | state: :armed, loaded_since: record.loaded_since || now, due_ms: nil}, []}
  end

  defp apply_event(%{incarnation: id} = record, {:crash, id}, now)
       when not is_nil(id) do
    history = [now | Enum.filter(record.history, &(&1 > now - @window_ms))]
    index = min(record.delay_index + 1, 6)
    fence = record.fence + 1

    next = %{
      record
      | history: Enum.take(history, 5),
        delay_index: index,
        incarnation: nil,
        loaded_since: nil,
        fence: fence
    }

    if length(history) >= 5 do
      {%{next | state: :open, due_ms: nil}, [{:cancel, record.fence}]}
    else
      due = now + elem(@delays, index - 1)
      {%{next | state: :backoff, due_ms: due}, [{:schedule, fence, due}]}
    end
  end

  defp apply_event(
         %{state: :backoff, fence: fence, due_ms: due} = record,
         {:timer, fence, true},
         now
       )
       when now >= due do
    {%{record | state: :restarting, due_ms: nil}, [{:load, fence}]}
  end

  defp apply_event(%{state: :restarting, fence: fence} = record, {:restart_failed, fence}, _now) do
    interrupt(record, :recovery_required)
  end

  defp apply_event(record, event, _now) when event in [:interrupt, :reset] do
    state =
      cond do
        record.state == :open ->
          :open

        record.state != :armed or record.delay_index > 0 or record.history != [] ->
          :recovery_required

        true ->
          :armed
      end

    interrupt(record, state)
  end

  defp apply_event(record, {:authorized_recovery, action}, _now)
       when action in [:clear, :unload, :reload] do
    next = %{new() | fence: record.fence + 1}
    effects = [{:cancel, record.fence}]

    if action == :reload do
      {%{next | state: :restarting}, effects ++ [{:load, next.fence}]}
    else
      {next, effects}
    end
  end

  defp apply_event(record, _event, _now), do: {record, []}

  defp interrupt(record, state) do
    next = %{
      record
      | state: state,
        fence: record.fence + 1,
        incarnation: nil,
        loaded_since: nil,
        due_ms: nil
    }

    {next, [{:cancel, record.fence}]}
  end

  defp reset_stable(%{state: :armed, loaded_since: since} = record, now)
       when is_integer(since) and now - since >= @window_ms do
    %{record | history: [], delay_index: 0}
  end

  defp reset_stable(record, _now), do: record
end
