defmodule Orchard.Requests.InferenceAttemptResultTest do
  use ExUnit.Case, async: true

  alias Orchard.Requests.InferenceAttemptResult

  @node_1 "00000000-0000-4000-a000-000000000001"
  @node_2 "00000000-0000-4000-a000-000000000002"

  test "SPEC.md §9.1 exposes the durable attempt and attempt-1 retry vocabularies" do
    assert InferenceAttemptResult.attempt_outcomes() ==
             ~w(completed failed cancelled timed_out interrupted)

    assert InferenceAttemptResult.attempt_one_retry_decisions() ==
             ~w(
               retried not_retryable output_committed cancelled budget_exhausted
               identity_unresolved occupancy_unresolved no_alternative_node
             )

    refute "retry_exhausted" in InferenceAttemptResult.attempt_one_retry_decisions()
  end

  test "valid attempt 1 and attempt 2 terminal evidence normalize to JSON-safe maps" do
    assert {:ok, attempt_1} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{"retry_decision" => "not_retryable"})
             )

    assert attempt_1["started_at"] == "2026-08-12T10:00:00.000000Z"

    assert {:ok, attempt_2} =
             InferenceAttemptResult.new(
               "request_step.failed",
               2,
               failed_result(%{
                 "node_id" => @node_2,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "retry_exhausted"
               })
             )

    assert attempt_2["excluded_node_ids"] == [@node_1]
  end

  test "closed retry decisions reject impossible attempt states" do
    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{"retry_decision" => "retry_exhausted"})
             )

    for decision <-
          ~w(not_retryable output_committed budget_exhausted identity_unresolved occupancy_unresolved no_alternative_node retried) do
      assert {:error, _reason} =
               InferenceAttemptResult.new(
                 "request_step.failed",
                 2,
                 failed_result(%{
                   "node_id" => @node_2,
                   "excluded_node_ids" => [@node_1],
                   "retry_decision" => decision
                 })
               )
    end
  end

  test "SPEC.md §7.2.7 permits typed attempt 2 acceptance-proof failure evidence" do
    assert {:ok, attempt_2} =
             InferenceAttemptResult.new(
               "request_step.failed",
               2,
               failed_result(%{
                 "failure_class" => "pre_acceptance_unavailable",
                 "failure_code" => "runtime_incompatible",
                 "node_id" => @node_2,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "not_retryable"
               })
             )

    assert attempt_2["retry_decision"] == "not_retryable"

    for {failure_class, failure_code} <- [
          {"pre_acceptance_unavailable", "runtime_unavailable"},
          {"runtime_failure", "runtime_incompatible"}
        ] do
      assert {:error, _reason} =
               InferenceAttemptResult.new(
                 "request_step.failed",
                 2,
                 failed_result(%{
                   "failure_class" => failure_class,
                   "failure_code" => failure_code,
                   "node_id" => @node_2,
                   "excluded_node_ids" => [@node_1],
                   "retry_decision" => "not_retryable"
                 })
               )
    end
  end

  test "orphaned enriched fields and contradictory decisions fail closed" do
    assert InferenceAttemptResult.enriched?(%{"failure_class" => "runtime_failure"})

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               %{"failure_class" => "runtime_failure"}
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{"retry_decision" => "output_committed"})
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{
                 "attempt_outcome" => "failed",
                 "failure_class" => "runtime_failure",
                 "retry_decision" => "cancelled"
               })
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.cancelled",
               2,
               failed_result(%{
                 "attempt_outcome" => "cancelled",
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect",
                 "node_id" => @node_2,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "retry_exhausted"
               })
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{
                 "accepted" => true,
                 "output_committed" => true,
                 "output_commitment_kind" => "text",
                 "execution_resolution" => "terminated",
                 "capacity_release_outcome" => "released",
                 "node_id" => @node_1,
                 "retry_decision" => "retried"
               })
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{
                 "accepted" => true,
                 "output_committed" => true,
                 "output_commitment_kind" => "text",
                 "execution_resolution" => "terminated",
                 "capacity_release_outcome" => "released",
                 "node_id" => @node_1,
                 "retry_decision" => "budget_exhausted"
               })
             )
  end

  test "success omits retry and failure evidence" do
    completed =
      base_result(%{
        "attempt_outcome" => "completed",
        "accepted" => true,
        "execution_resolution" => "terminated"
      })

    assert {:ok, _result} =
             InferenceAttemptResult.new("request_step.completed", 1, completed)

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.completed",
               1,
               Map.put(completed, "retry_decision", "not_retryable")
             )
  end

  test "commitment evidence is internally consistent" do
    failed = failed_result(%{"retry_decision" => "output_committed"})

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               Map.put(failed, "output_commitment_kind", "text")
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               Map.put(failed, "output_committed", true)
             )

    assert {:ok, _result} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed
               |> Map.put("accepted", true)
               |> Map.put("execution_resolution", "terminated")
               |> Map.put("output_committed", true)
               |> Map.put("output_commitment_kind", "text")
             )
  end

  test "SPEC 5.8 gives attempt 1 commitment precedence while preserving closed attempt 2 rules" do
    committed_failure =
      failed_result(%{
        "accepted" => true,
        "output_committed" => true,
        "output_commitment_kind" => "tool_call",
        "execution_resolution" => "terminated",
        "capacity_release_outcome" => "released",
        "node_id" => @node_1,
        "retry_decision" => "output_committed"
      })

    assert {:ok, _result} =
             InferenceAttemptResult.new("request_step.failed", 1, committed_failure)

    assert {:ok, _result} =
             InferenceAttemptResult.new(
               "request_step.cancelled",
               1,
               Map.merge(committed_failure, %{
                 "attempt_outcome" => "cancelled",
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect"
               })
             )

    assert {:error, "cancelled attempts require cancellation failure evidence"} =
             InferenceAttemptResult.new(
               "request_step.cancelled",
               1,
               Map.merge(committed_failure, %{
                 "attempt_outcome" => "cancelled",
                 "failure_class" => "runtime_failure",
                 "failure_code" => "runtime_unavailable"
               })
             )

    assert {:ok, _result} =
             InferenceAttemptResult.new(
               "request_step.cancelled",
               1,
               failed_result(%{
                 "attempt_outcome" => "cancelled",
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect",
                 "retry_decision" => "cancelled"
               })
             )

    assert {:ok, _result} =
             InferenceAttemptResult.new(
               "request_step.failed",
               2,
               failed_result(%{
                 "node_id" => @node_2,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "retry_exhausted"
               })
             )

    assert {:ok, _result} =
             InferenceAttemptResult.new(
               "request_step.failed",
               2,
               failed_result(%{
                 "accepted" => true,
                 "output_committed" => true,
                 "output_commitment_kind" => "text",
                 "execution_resolution" => "terminated",
                 "capacity_release_outcome" => "released",
                 "node_id" => @node_2,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "retry_exhausted"
               })
             )
  end

  test "retry resolution preserves the attempt's producing failure evidence" do
    assert {:ok, identity_unresolved} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{
                 "failure_class" => "worker_or_node_loss",
                 "failure_code" => "worker_down",
                 "retry_decision" => "identity_unresolved"
               })
             )

    assert identity_unresolved["failure_class"] == "worker_or_node_loss"

    assert {:ok, occupancy_unresolved} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               failed_result(%{
                 "failure_class" => "pre_acceptance_unavailable",
                 "failure_code" => "runtime_unavailable",
                 "execution_resolution" => "unresolved",
                 "capacity_release_outcome" => "unresolved",
                 "retry_decision" => "occupancy_unresolved"
               })
             )

    assert occupancy_unresolved["failure_class"] == "pre_acceptance_unavailable"
  end

  test "event outcome and attempt 2 exclusions fail closed" do
    failed = failed_result(%{"retry_decision" => "not_retryable"})

    assert {:error, _reason} =
             InferenceAttemptResult.new("request_step.cancelled", 1, failed)

    for exclusions <- [[], ["bad"], [@node_1, @node_1]] do
      assert {:error, _reason} =
               InferenceAttemptResult.new(
                 "request_step.failed",
                 2,
                 failed_result(%{
                   "node_id" => @node_2,
                   "excluded_node_ids" => exclusions,
                   "retry_decision" => "retry_exhausted"
                 })
               )
    end

    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               2,
               failed_result(%{
                 "node_id" => @node_1,
                 "excluded_node_ids" => [@node_1],
                 "retry_decision" => "retry_exhausted"
               })
             )
  end

  test "timestamps, booleans, bounded integers, and stable codes fail closed" do
    result = failed_result(%{"retry_decision" => "not_retryable"})

    invalid_results = [
      Map.put(result, "ended_at", ~U[2026-08-12 09:59:59.000000Z]),
      Map.put(result, "accepted", "false"),
      Map.put(result, "output_tokens", 2_147_483_648),
      Map.put(result, "failure_code", "private_runtime_code")
    ]

    for invalid <- invalid_results do
      assert {:error, _reason} =
               InferenceAttemptResult.new("request_step.failed", 1, invalid)
    end
  end

  test "unexpected and partial enriched shapes fail closed" do
    assert {:error, _reason} =
             InferenceAttemptResult.new(
               "request_step.failed",
               1,
               Map.put(failed_result(%{"retry_decision" => "not_retryable"}), "content", "secret")
             )

    assert {:error, _reason} =
             InferenceAttemptResult.new("request_step.failed", 1, %{"accepted" => false})
  end

  defp failed_result(overrides) do
    base_result(
      Map.merge(
        %{
          "attempt_outcome" => "failed",
          "failure_class" => "runtime_failure",
          "failure_code" => "runtime_unavailable"
        },
        overrides
      )
    )
  end

  defp base_result(overrides) do
    Map.merge(
      %{
        "attempt_outcome" => "failed",
        "started_at" => ~U[2026-08-12 10:00:00.000000Z],
        "ended_at" => ~U[2026-08-12 10:00:01.000000Z],
        "accepted" => false,
        "output_committed" => false,
        "execution_resolution" => "not_started",
        "capacity_release_outcome" => "not_applicable",
        "excluded_node_ids" => []
      },
      overrides
    )
  end
end
