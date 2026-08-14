defmodule Orchard.Dispatch.AttemptOutcomeTest do
  use ExUnit.Case, async: true

  alias Orchard.Dispatch.AttemptOutcome
  alias Orchard.Requests.InferenceAttemptFailure

  test "SPEC 5.8 validates commitment, delivery accounting, and failure transformations" do
    started_at = ~U[2026-08-14 10:00:00.000000Z]
    ended_at = DateTime.add(started_at, 1, :second)

    events = [
      Orchard.InferenceEvent.accepted(1),
      Orchard.InferenceEvent.tool_call_delta("call-1", "")
    ]

    attrs = %{
      attempt_outcome: :completed,
      node_id: Ecto.UUID.generate(),
      accepted: true,
      events: events,
      failure: nil,
      execution_resolution: :terminated,
      capacity_release_outcome: :released,
      started_at: started_at,
      ended_at: ended_at,
      first_token_at: nil,
      output_committed: true,
      output_commitment_kind: :tool_call,
      delivery_state: :selected,
      delivered_event_count: 2
    }

    assert {:ok, committed} = AttemptOutcome.new(attrs)
    assert committed.output_committed
    assert committed.output_commitment_kind == :tool_call
    assert committed.first_token_at == nil

    assert {:error, :invalid_attempt_outcome} =
             attrs |> Map.delete(:output_commitment_kind) |> AttemptOutcome.new()

    assert {:error, :invalid_attempt_outcome} =
             attrs
             |> Map.put(:output_commitment_kind, :text)
             |> Map.put(:first_token_at, nil)
             |> AttemptOutcome.new()

    assert {:error, :invalid_attempt_outcome} =
             attrs |> Map.put(:accepted, false) |> AttemptOutcome.new()

    assert {:error, :invalid_attempt_outcome} =
             attrs |> Map.put(:delivered_event_count, 1) |> AttemptOutcome.new()

    failed = AttemptOutcome.fail_delivery(committed, 1)
    assert failed.attempt_outcome == :failed
    assert failed.delivery_state == :failed
    assert failed.delivered_event_count == 1
    assert failed.output_committed
    assert failed.output_commitment_kind == :tool_call
    assert failed.failure["failure_class"] == "controller_failure"

    cancelled = AttemptOutcome.cancel_delivery(committed, 1)
    assert cancelled.attempt_outcome == :cancelled
    assert cancelled.delivery_state == :failed
    assert cancelled.delivered_event_count == 1
    assert cancelled.output_committed
    assert cancelled.failure["failure_class"] == "cancellation"
  end

  test "SPEC 5.8 discards only pending uncommitted outcomes without delivery" do
    started_at = ~U[2026-08-14 10:00:00.000000Z]
    ended_at = DateTime.add(started_at, 1, :second)

    attrs = %{
      attempt_outcome: :completed,
      node_id: Ecto.UUID.generate(),
      accepted: true,
      events: [Orchard.InferenceEvent.accepted(1), Orchard.InferenceEvent.output_text_delta("")],
      failure: nil,
      execution_resolution: :terminated,
      capacity_release_outcome: :released,
      started_at: started_at,
      ended_at: ended_at,
      first_token_at: nil,
      output_committed: false,
      output_commitment_kind: nil,
      delivery_state: :pending,
      delivered_event_count: 0
    }

    assert {:ok, pending} = AttemptOutcome.new(attrs)
    assert {:ok, discarded} = AttemptOutcome.discard(pending)
    assert discarded.delivery_state == :discarded
    assert discarded.events == pending.events
    assert discarded.delivered_event_count == 0

    selected = AttemptOutcome.select(pending, "request-selected", nil)
    assert {:error, :already_selected} = AttemptOutcome.discard(selected)

    {:ok, committed} =
      attrs
      |> Map.put(:events, [Orchard.InferenceEvent.output_text_delta("committed")])
      |> Map.put(:output_committed, true)
      |> Map.put(:output_commitment_kind, :text)
      |> Map.put(:first_token_at, started_at)
      |> Map.put(:delivery_state, :selected)
      |> Map.put(:delivered_event_count, 1)
      |> AttemptOutcome.new()

    assert {:error, :output_committed} = AttemptOutcome.discard(committed)
  end

  test "SPEC 3.7.1 validates narrow typed single-attempt evidence" do
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    ended_at = DateTime.add(started_at, 5, :millisecond)
    first_token_at = DateTime.add(started_at, 2, :millisecond)
    node_id = Ecto.UUID.generate()

    failure =
      InferenceAttemptFailure.normalize(%{
        category: :runtime_failure,
        code: :worker_down
      })

    attrs = %{
      attempt_outcome: :failed,
      node_id: node_id,
      accepted: true,
      events: [],
      failure: failure,
      execution_resolution: :terminated,
      capacity_release_outcome: :released,
      started_at: started_at,
      ended_at: ended_at,
      first_token_at: first_token_at,
      output_committed: true,
      output_commitment_kind: :text,
      delivery_state: :selected,
      delivered_event_count: 0
    }

    assert {:ok, outcome} = AttemptOutcome.new(attrs)

    assert {:error, :invalid_attempt_outcome} =
             attrs
             |> Map.put(:output_committed, false)
             |> Map.put(:output_commitment_kind, nil)
             |> AttemptOutcome.new()

    assert %AttemptOutcome{} = outcome
    assert outcome.node_id == node_id
    assert outcome.failure == failure
    assert outcome.first_token_at == first_token_at

    assert {:error, :invalid_attempt_outcome} =
             AttemptOutcome.new(%{
               attempt_outcome: :unknown,
               node_id: nil,
               accepted: false,
               events: [],
               failure: nil,
               execution_resolution: :not_started,
               capacity_release_outcome: :not_applicable,
               started_at: started_at,
               ended_at: ended_at,
               first_token_at: nil,
               output_committed: false,
               output_commitment_kind: nil,
               delivery_state: :selected,
               delivered_event_count: 0
             })
  end
end
