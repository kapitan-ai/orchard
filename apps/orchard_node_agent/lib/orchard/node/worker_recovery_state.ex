defmodule Orchard.Node.WorkerRecoveryState do
  @moduledoc """
  ModelManager's per-placement recovery durability state (SPEC §12.2).

  `desired` and `pending` are separate: a worker loss can supersede an in-flight
  write without losing either its revision acknowledgement or the newer crash.
  Only effects attached to the current desired transition may be published.
  """

  alias Orchard.ClusterManagement.ReasonCodes
  alias Orchard.Node.WorkerCrashPolicy, as: Policy
  alias Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint, as: Record

  @type t :: map()

  @spec new(String.t()) :: t()
  def new(epoch) do
    %{
      epoch: epoch,
      owner_epoch: nil,
      revision: 0,
      policy: Policy.new(),
      hydrated?: false,
      ownership: %{"phase" => "resolved", "incarnation" => nil, "custody" => nil},
      command: nil,
      desired: nil,
      pending: nil,
      sequence: 0,
      effects: [],
      superseded_effects: [],
      retry_at: nil,
      retry_streak: 0,
      request: nil,
      prior?: false,
      last_worker_pid: nil,
      operator_waiters: [],
      operator_deadline: nil,
      stop_waiters: []
    }
  end

  @spec hydrate(t(), map() | :absent) :: t()
  def hydrate(entry, :absent), do: %{entry | hydrated?: true}

  def hydrate(entry, checkpoint) do
    record = checkpoint.record
    policy = %{Policy.new() | history: record["crashes"], delay_index: record["delay_index"]}

    state =
      cond do
        record["state"] == "open" -> :open
        Record.clean?(record) -> :armed
        true -> :recovery_required
      end

    %{
      entry
      | owner_epoch: checkpoint.epoch,
        revision: checkpoint.revision,
        hydrated?: true,
        policy: %{policy | state: state},
        ownership: record["ownership"],
        command: record["command"],
        prior?: not Record.resolved?(record)
    }
  end

  @spec transition(t(), Policy.event(), integer(), [term()]) :: t()
  def transition(entry, event, now, effects \\ []) do
    {policy, policy_effects} = Policy.transition(entry.policy, event, now)

    if policy == entry.policy and policy_effects == [] and effects == [] do
      entry
    else
      %{entry | policy: policy} |> checkpoint(policy_effects ++ effects)
    end
  end

  @spec checkpoint(t(), [term()]) :: t()
  def checkpoint(entry, effects) do
    sequence = entry.sequence + 1

    superseded_effects =
      if is_nil(entry.desired),
        do: entry.superseded_effects,
        else: entry.superseded_effects ++ entry.effects

    %{
      entry
      | sequence: sequence,
        desired: "#{entry.epoch}:#{sequence}",
        effects: effects,
        superseded_effects: superseded_effects
    }
  end

  @doc "Returns effect waiters displaced by a newer checkpoint transition exactly once."
  @spec take_superseded_effects(t()) :: {t(), [term()]}
  def take_superseded_effects(%{superseded_effects: effects} = entry) do
    {%{entry | superseded_effects: []}, effects}
  end

  def take_superseded_effects(entry), do: {entry, []}

  @spec record(t()) :: Record.t()
  def record(entry) do
    %{
      "epoch" => entry.epoch,
      "state" => Atom.to_string(entry.policy.state),
      "delay_index" => entry.policy.delay_index,
      "crashes" => entry.policy.history,
      "stable_since" => entry.policy.loaded_since,
      "ownership" => entry.ownership,
      "command" => entry.command
    }
  end

  @spec begin_write(t(), integer()) :: {:write, t(), map()} | {:wait, t()}
  def begin_write(%{pending: nil, desired: desired} = entry, now) when not is_nil(desired) do
    if is_nil(entry.retry_at) or now >= entry.retry_at do
      pending = %{
        id: desired,
        epoch: entry.owner_epoch,
        revision: entry.revision,
        record: record(entry)
      }

      {:write, %{entry | pending: pending, retry_at: nil}, pending}
    else
      {:wait, entry}
    end
  end

  def begin_write(entry, _now), do: {:wait, entry}

  @spec acknowledge(t(), String.t(), map()) :: {t(), [term()]}
  def acknowledge(%{pending: %{id: id} = pending} = entry, id, checkpoint) do
    valid? =
      checkpoint[:transition_id] == id and checkpoint[:epoch] == entry.epoch and
        checkpoint[:revision] == pending.revision + 1 and checkpoint[:record] == pending.record

    if valid? do
      acknowledged = %{
        entry
        | owner_epoch: checkpoint.epoch,
          revision: checkpoint.revision,
          pending: nil,
          retry_at: nil,
          retry_streak: 0
      }

      if entry.desired == id do
        {%{acknowledged | desired: nil, effects: []}, entry.effects}
      else
        {acknowledged, []}
      end
    else
      {entry, []}
    end
  end

  def acknowledge(entry, _id, _checkpoint), do: {entry, []}

  @doc "Returns the deterministic checkpoint retry interval for a failure streak."
  @spec checkpoint_retry_interval(non_neg_integer()) :: pos_integer()
  def checkpoint_retry_interval(streak) when is_integer(streak) and streak >= 0 do
    Enum.at([1_000, 2_000, 4_000, 8_000, 16_000, 30_000], min(streak, 5))
  end

  @spec unavailable(t(), String.t(), integer()) :: t()
  def unavailable(%{pending: %{id: id}, retry_streak: streak} = entry, id, now) do
    %{entry | retry_at: now + checkpoint_retry_interval(streak), retry_streak: streak + 1}
  end

  def unavailable(entry, _id, _now), do: entry

  @spec retry(t(), integer()) :: {:write, t(), map()} | {:wait, t()}
  def retry(%{pending: pending, retry_at: due} = entry, now)
      when not is_nil(pending) and is_integer(due) and now >= due,
      do: {:write, %{entry | retry_at: nil}, pending}

  def retry(entry, _now), do: {:wait, entry}

  @spec refusal(t() | nil) :: atom() | nil
  def refusal(nil), do: :placement_recovery_required

  def refusal(entry) do
    cond do
      recovery_required?(entry) -> :placement_recovery_required
      entry.policy.state == :backoff -> :worker_restart_backoff
      entry.policy.state == :restarting -> :worker_restart_in_progress
      entry.policy.state == :open -> :placement_crash_breaker_open
      true -> nil
    end
  end

  defp recovery_required?(entry) do
    entry.ownership["phase"] == "cleanup" or
      intentional_effect_pending?(Map.get(entry, :effects, [])) or
      entry.hydrated? == false or
      entry.policy.state == :recovery_required or entry.prior?
  end

  defp intentional_effect_pending?(effects) do
    Enum.any?(effects, fn
      :await_cleanup -> true
      {:ordinary_unload, _request} -> true
      {:operator_cleanup, _command_id} -> true
      {:operator_reset, _command_id} -> true
      _effect -> false
    end)
  end

  @spec projection(t()) :: map()
  def projection(entry) do
    state = projection_state(entry.policy.state, refusal(entry))
    state = Atom.to_string(state)
    reason = ReasonCodes.worker_recovery_reason_for_state(state)

    %{
      epoch: entry.epoch,
      owner_epoch: entry.owner_epoch,
      revision: entry.revision,
      state: state,
      hydrated: entry.hydrated?,
      reason: reason,
      eligible: is_nil(reason)
    }
  end

  defp projection_state(_state, :placement_recovery_required), do: :recovery_required
  defp projection_state(state, _reason), do: state
end
