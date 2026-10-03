defmodule Orchard.Metrics.InferenceAttemptProjectionTest do
  use ExUnit.Case, async: true

  alias Orchard.Metrics.InferenceAttemptProjection
  alias Orchard.Requests.RequestStepEvent

  @node_1 "00000000-0000-4000-a000-000000000001"
  @node_2 "00000000-0000-4000-a000-000000000002"

  test "SPEC.md section 9.1 projects one completed started attempt without a retry" do
    events = [started(1, 1), terminal(1, :completed, nil, 2)]

    assert InferenceAttemptProjection.project(events) ==
             {:ok,
              %{
                attempts: [
                  %{
                    attempt: 1,
                    duration_seconds: 1.25,
                    failure_class: "none",
                    outcome: "completed"
                  }
                ],
                retry: nil
              }}
  end

  test "SPEC.md §§3.7.1 and 5.3 projects both historical and next-format terminal evidence" do
    next_format_terminal =
      terminal(1, :completed, nil, 2)
      |> Map.update!(:result, fn result ->
        Map.merge(result, %{
          "output_tokens" => 12,
          "output_usage_status" => "exact",
          "reasoning_tokens" => 3
        })
      end)

    assert {:ok, %{attempts: [%{outcome: "completed"}], retry: nil}} =
             InferenceAttemptProjection.project([started(1, 1), next_format_terminal])
  end

  test "SPEC.md section 9.1 projects a successful logical retry once" do
    events = [
      started(1, 1),
      terminal(1, :failed, "retried", 2),
      started(2, 3),
      terminal(2, :completed, nil, 4)
    ]

    assert {:ok,
            %{
              attempts: [
                %{attempt: 1, outcome: "failed", failure_class: "runtime_failure"},
                %{attempt: 2, outcome: "completed", failure_class: "none"}
              ],
              retry: %{reason: "retried", result: "succeeded"}
            }} = InferenceAttemptProjection.project(events)
  end

  test "SPEC.md section 9.1 reports an exhausted attempt 2 as one failed logical retry" do
    events = [
      started(1, 1),
      terminal(1, :failed, "retried", 2),
      started(2, 3),
      terminal(2, :failed, "retry_exhausted", 4)
    ]

    assert {:ok,
            %{
              attempts: [
                %{attempt: 1, outcome: "failed"},
                %{attempt: 2, outcome: "failed"}
              ],
              retry: %{reason: "retried", result: "failed"}
            }} = InferenceAttemptProjection.project(events)
  end

  test "SPEC.md section 9.1 reports every attempt-1 decline reason only as declined" do
    reasons =
      ~w(not_retryable output_committed cancelled budget_exhausted identity_unresolved occupancy_unresolved no_alternative_node)

    for reason <- reasons do
      outcome = if reason == "cancelled", do: :cancelled, else: :failed

      assert {:ok,
              %{
                attempts: [%{attempt: 1}],
                retry: %{reason: ^reason, result: "declined"}
              }} =
               InferenceAttemptProjection.project([
                 started(1, 1),
                 terminal(1, outcome, reason, 2)
               ])
    end
  end

  test "ambiguous or orphaned evidence cannot duplicate attempt or retry metrics" do
    duplicate_terminal = terminal(1, :failed, "not_retryable", 2)

    assert {:error, :invalid_attempt_evidence} =
             InferenceAttemptProjection.project([
               started(1, 1),
               duplicate_terminal,
               duplicate_terminal
             ])

    assert {:error, :invalid_attempt_evidence} =
             InferenceAttemptProjection.project([
               started(2, 3),
               terminal(2, :failed, "retry_exhausted", 4)
             ])
  end

  defp started(attempt, seq) do
    %RequestStepEvent{
      event_type: "request_step.started",
      step_id: RequestStepEvent.inference_turn_step_id(1, attempt),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: attempt,
      boundary: "pre_side_effect",
      result: %{},
      seq: seq
    }
  end

  defp terminal(attempt, outcome, retry_decision, seq) do
    event_type = "request_step.#{outcome}"

    %RequestStepEvent{
      event_type: event_type,
      step_id: RequestStepEvent.inference_turn_step_id(1, attempt),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: attempt,
      boundary: "post_observation",
      result: terminal_result(attempt, outcome, retry_decision),
      seq: seq
    }
  end

  defp terminal_result(attempt, :completed, nil) do
    %{
      "attempt_outcome" => "completed",
      "started_at" => ~U[2026-08-12 10:00:00.000000Z],
      "ended_at" => ~U[2026-08-12 10:00:01.250000Z],
      "accepted" => true,
      "output_committed" => false,
      "execution_resolution" => "terminated",
      "capacity_release_outcome" => "released",
      "excluded_node_ids" => if(attempt == 1, do: [], else: [@node_1])
    }
  end

  defp terminal_result(attempt, outcome, retry_decision) do
    result = %{
      "attempt_outcome" => Atom.to_string(outcome),
      "started_at" => ~U[2026-08-12 10:00:00.000000Z],
      "ended_at" => ~U[2026-08-12 10:00:01.250000Z],
      "accepted" => true,
      "output_committed" => false,
      "execution_resolution" => "terminated",
      "capacity_release_outcome" => "released",
      "excluded_node_ids" => if(attempt == 1, do: [], else: [@node_1]),
      "node_id" => if(attempt == 1, do: @node_1, else: @node_2),
      "failure_class" => "runtime_failure",
      "failure_code" => "runtime_unavailable",
      "retry_decision" => retry_decision
    }

    case {outcome, retry_decision} do
      {:cancelled, "cancelled"} ->
        %{result | "failure_class" => "cancellation", "failure_code" => "request_cancelled"}

      {_outcome, "output_committed"} ->
        result
        |> Map.put("output_committed", true)
        |> Map.put("output_commitment_kind", "text")

      _other ->
        result
    end
  end
end
