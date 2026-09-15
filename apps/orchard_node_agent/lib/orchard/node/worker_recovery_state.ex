defmodule Orchard.Node.WorkerRecoveryState do
  @moduledoc """
  ModelManager's per-placement recovery durability state (SPEC §12.2).

  `desired` and `pending` are separate: a worker loss can supersede an in-flight
  write without losing either its revision acknowledgement or the newer crash.
  Only effects attached to the current desired transition may be published.
  """

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
      retry_at: nil,
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
    %{entry | sequence: sequence, desired: "#{entry.epoch}:#{sequence}", effects: effects}
  end

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
          retry_at: nil
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

  @spec unavailable(t(), String.t(), integer()) :: t()
  def unavailable(%{pending: %{id: id}} = entry, id, now),
    do: %{entry | retry_at: now + 1_000}

  def unavailable(entry, _id, _now), do: entry

  @spec retry(t(), integer()) :: {:write, t(), map()} | {:wait, t()}
  def retry(%{pending: pending, retry_at: due} = entry, now)
      when not is_nil(pending) and is_integer(due) and now >= due,
      do: {:write, %{entry | retry_at: nil}, pending}

  def retry(entry, _now), do: {:wait, entry}

  @spec refusal(t() | nil) :: atom() | nil
  def refusal(nil), do: :placement_recovery_required
  def refusal(%{hydrated?: false}), do: :placement_recovery_required
  def refusal(%{policy: %{state: :backoff}}), do: :worker_restart_backoff
  def refusal(%{policy: %{state: :restarting}}), do: :worker_restart_in_progress
  def refusal(%{policy: %{state: :open}}), do: :placement_crash_breaker_open
  def refusal(%{policy: %{state: :recovery_required}}), do: :placement_recovery_required
  def refusal(%{desired: desired}) when not is_nil(desired), do: :worker_restart_in_progress
  def refusal(%{prior?: true}), do: :placement_recovery_required
  def refusal(_entry), do: nil

  @spec projection(t()) :: map()
  def projection(entry) do
    %{
      epoch: entry.epoch,
      owner_epoch: entry.owner_epoch,
      revision: entry.revision,
      state: Atom.to_string(entry.policy.state),
      hydrated: entry.hydrated?,
      reason: refusal(entry),
      eligible: is_nil(refusal(entry))
    }
  end
end
