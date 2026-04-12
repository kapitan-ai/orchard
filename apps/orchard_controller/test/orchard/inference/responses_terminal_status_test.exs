defmodule Orchard.Inference.ResponsesTerminalStatusTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.{ChatError, ResponsesTerminalStatus}
  alias Orchard.InferenceEvent

  describe "inference_failed_status/2" do
    test "preserves failed status for ordinary inference failures" do
      event = InferenceEvent.failed("internal_error", "runtime crashed", false)

      assert ResponsesTerminalStatus.inference_failed_status(event) == "failed"

      assert ResponsesTerminalStatus.inference_failed_status(event,
               partial_output_surfaced?: true
             ) ==
               "failed"
    end

    test "preserves incomplete projection only for cancelled or interrupted inference failures with partial output" do
      cancelled =
        InferenceEvent.failed("request_cancelled", "request was cancelled upstream", false)

      interrupted = InferenceEvent.failed("request_caller_disconnect", "caller exited", false)

      assert ResponsesTerminalStatus.inference_failed_status(cancelled) == "failed"

      assert ResponsesTerminalStatus.inference_failed_status(
               cancelled,
               partial_output_surfaced?: true
             ) == "incomplete"

      assert ResponsesTerminalStatus.inference_failed_status(
               interrupted,
               partial_output_surfaced?: true
             ) == "incomplete"
    end

    test "accepts a prebuilt ChatError for the same inference projection rules" do
      error =
        InferenceEvent.failed("request_cancelled", "request was cancelled upstream", false)
        |> ChatError.from_failed_event()

      assert ResponsesTerminalStatus.inference_failed_status(error) == "failed"

      assert ResponsesTerminalStatus.inference_failed_status(error,
               partial_output_surfaced?: true
             ) ==
               "incomplete"
    end
  end

  describe "execute_error_status/2" do
    test "keeps generic execute reasons failed even when partial output was surfaced" do
      reason = {:terminal_persist_failed, :boom}

      assert ResponsesTerminalStatus.execute_error_status(reason) == "failed"

      assert ResponsesTerminalStatus.execute_error_status(
               reason,
               partial_output_surfaced?: true
             ) == "failed"
    end

    test "projects tagged tool outcomes through the future-facing tool status rules" do
      cancelled = {:tool_execution_outcome, %{status: :cancelled}}

      indeterminate =
        {:tool_execution_outcome,
         %{status: :indeterminate, indeterminate_reason: :result_not_observed}}

      assert ResponsesTerminalStatus.execute_error_status(cancelled) == "failed"

      assert ResponsesTerminalStatus.execute_error_status(
               cancelled,
               partial_output_surfaced?: true
             ) == "incomplete"

      assert ResponsesTerminalStatus.execute_error_status(indeterminate) == "failed"

      assert ResponsesTerminalStatus.execute_error_status(
               indeterminate,
               partial_output_surfaced?: true
             ) == "incomplete"
    end

    test "rejects completed tagged tool outcomes through the execute-error seam" do
      assert_raise ArgumentError, ~r/completed tool outcomes do not project/, fn ->
        ResponsesTerminalStatus.execute_error_status(
          {:tool_execution_outcome, %{status: :completed}}
        )
      end
    end
  end

  describe "tool_outcome_status/2" do
    test "rejects completed tool outcomes because this seam is only for failed/incomplete projection" do
      assert {:error, reason} = ResponsesTerminalStatus.tool_outcome_status(%{status: :completed})
      assert reason =~ "completed tool outcomes do not project"
    end

    test "projects failed and timed_out future tool outcomes as failed" do
      assert ResponsesTerminalStatus.tool_outcome_status!(%{
               status: :failed,
               error_code: "tool_execution_failed",
               error_message: "Tool execution failed"
             }) == "failed"

      assert ResponsesTerminalStatus.tool_outcome_status!(%{
               status: :timed_out,
               error_code: "tool_execution_timed_out",
               error_message: "Tool execution timed out"
             }) == "failed"
    end

    test "projects cancelled and indeterminate future tool outcomes based on whether partial output was surfaced" do
      cancelled = %{
        status: :cancelled,
        error_code: "tool_execution_cancelled",
        error_message: "Tool execution was cancelled"
      }

      indeterminate = %{
        status: :indeterminate,
        error_code: "tool_execution_indeterminate_result_not_observed",
        error_message: "Tool execution result was not observed",
        indeterminate_reason: :result_not_observed
      }

      assert ResponsesTerminalStatus.tool_outcome_status!(cancelled) == "failed"

      assert ResponsesTerminalStatus.tool_outcome_status!(
               cancelled,
               partial_output_surfaced?: true
             ) == "incomplete"

      assert ResponsesTerminalStatus.tool_outcome_status!(indeterminate) == "failed"

      assert ResponsesTerminalStatus.tool_outcome_status!(
               indeterminate,
               partial_output_surfaced?: true
             ) == "incomplete"
    end
  end
end
