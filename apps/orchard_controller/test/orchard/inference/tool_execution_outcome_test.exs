defmodule Orchard.Inference.ToolExecutionOutcomeTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ToolExecutionOutcome

  describe "new/1" do
    test "rejects unknown statuses" do
      assert {:error, reason} = ToolExecutionOutcome.new(%{status: :unknown})
      assert reason =~ "status must be one of"
    end

    test "rejects indeterminate outcomes without a valid reason" do
      assert {:error, "indeterminate outcomes require indeterminate_reason"} =
               ToolExecutionOutcome.new(%{status: :indeterminate})

      assert {:error, reason} =
               ToolExecutionOutcome.new(%{
                 status: :indeterminate,
                 indeterminate_reason: :unexpected_reason
               })

      assert reason =~ "indeterminate_reason must be one of"
    end

    test "accepts exact string-valued status and indeterminate_reason enums" do
      assert {:ok, %ToolExecutionOutcome{status: :failed, error_code: "tool_failed"}} =
               ToolExecutionOutcome.new(%{
                 "status" => "failed",
                 "error_code" => "tool_failed",
                 "error_message" => "Tool execution failed"
               })

      assert {:ok,
              %ToolExecutionOutcome{
                status: :indeterminate,
                indeterminate_reason: :result_not_observed
              }} =
               ToolExecutionOutcome.new(%{
                 "status" => "indeterminate",
                 "indeterminate_reason" => "result_not_observed"
               })
    end

    test "rejects completed outcomes that include error fields" do
      assert {:error, "error_code is not allowed for completed outcomes"} =
               ToolExecutionOutcome.new(%{status: :completed, error_code: "bad"})
    end

    test "rejects non-indeterminate outcomes that include indeterminate_reason" do
      assert {:error, "only indeterminate outcomes may include indeterminate_reason"} =
               ToolExecutionOutcome.new(%{
                 status: :failed,
                 indeterminate_reason: :controller_restarted
               })
    end

    test "rejects whitespace-only optional remote and side-effect refs" do
      assert {:error, reason} =
               ToolExecutionOutcome.new(%{status: :completed, remote_execution_ref: "   "})

      assert reason =~ "remote_execution_ref must be a non-empty string when present"

      assert {:error, reason} =
               ToolExecutionOutcome.new(%{status: :failed, side_effect_anchor: "   "})

      assert reason =~ "side_effect_anchor must be a non-empty string when present"
    end
  end

  describe "request-step helpers" do
    test "maps statuses to request_step event types" do
      assert ToolExecutionOutcome.request_step_event_type!(%{status: :completed}) ==
               "request_step.completed"

      assert ToolExecutionOutcome.request_step_event_type!(%{status: :failed}) ==
               "request_step.failed"

      assert ToolExecutionOutcome.request_step_event_type!(%{status: :cancelled}) ==
               "request_step.cancelled"

      assert ToolExecutionOutcome.request_step_event_type!(%{status: :timed_out}) ==
               "request_step.timed_out"

      assert ToolExecutionOutcome.request_step_event_type!(%{
               status: :indeterminate,
               indeterminate_reason: :result_not_observed
             }) == "request_step.indeterminate"
    end

    test "builds completed request-step result payloads without error fields" do
      assert ToolExecutionOutcome.request_step_result!(%{
               status: :completed,
               remote_execution_ref: "exec_123",
               side_effect_anchor: "anchor_123"
             }) == %{
               "remote_execution_ref" => "exec_123",
               "side_effect_anchor" => "anchor_123"
             }
    end

    test "builds failed request-step result payloads with durable contract fields" do
      assert ToolExecutionOutcome.request_step_result!(%{
               status: :failed,
               error_code: "tool_backend_error",
               error_message: "Tool backend rejected the request",
               remote_execution_ref: "exec_456",
               side_effect_anchor: "anchor_456"
             }) == %{
               "error_code" => "tool_backend_error",
               "error_message" => "Tool backend rejected the request",
               "remote_execution_ref" => "exec_456",
               "side_effect_anchor" => "anchor_456"
             }
    end

    test "builds indeterminate request-step result payloads with reason metadata" do
      assert ToolExecutionOutcome.request_step_result!(%{
               status: :indeterminate,
               indeterminate_reason: :executor_unreachable,
               remote_execution_ref: "exec_789"
             }) == %{
               "error_code" => "tool_execution_indeterminate_executor_unreachable",
               "error_message" =>
                 "Tool execution became indeterminate after the executor became unreachable",
               "indeterminate_reason" => "executor_unreachable",
               "remote_execution_ref" => "exec_789"
             }
    end

    test "parses terminal request-step result payloads through the centralized validator" do
      assert {:ok, %ToolExecutionOutcome{status: :failed} = outcome} =
               ToolExecutionOutcome.from_request_step_result("request_step.failed", %{
                 "error_code" => "tool_execution_failed",
                 "error_message" => "Tool execution failed",
                 "remote_execution_ref" => "exec_456"
               })

      assert outcome.remote_execution_ref == "exec_456"

      assert {:ok,
              %ToolExecutionOutcome{
                status: :indeterminate,
                indeterminate_reason: :result_not_observed
              }} =
               ToolExecutionOutcome.from_request_step_result("request_step.indeterminate", %{
                 "error_code" => "tool_execution_indeterminate_result_not_observed",
                 "error_message" => "Tool execution result was not observed",
                 "indeterminate_reason" => "result_not_observed"
               })
    end

    test "rejects malformed terminal request-step result payloads" do
      assert {:error, reason} =
               ToolExecutionOutcome.from_request_step_result("request_step.failed", %{
                 "error_code" => "tool_execution_failed"
               })

      assert reason =~ "tool_execution result requires non-empty error_message"

      assert {:error, reason} =
               ToolExecutionOutcome.from_request_step_result("request_step.completed", %{
                 "unexpected_key" => "oops"
               })

      assert reason =~ "contains unexpected keys"

      assert {:error, reason} =
               ToolExecutionOutcome.from_request_step_result("request_step.indeterminate", %{
                 "error_code" => "tool_execution_indeterminate_result_not_observed",
                 "error_message" => "Tool execution result was not observed"
               })

      assert reason =~ "indeterminate outcomes require indeterminate_reason"
    end

    test "round-trips request-step event type and result payloads" do
      outcome =
        ToolExecutionOutcome.new!(%{
          "status" => "indeterminate",
          "indeterminate_reason" => "timeout_after_start",
          "remote_execution_ref" => "exec_789"
        })

      assert {:ok, reparsed} =
               ToolExecutionOutcome.from_request_step_result(
                 ToolExecutionOutcome.request_step_event_type!(outcome),
                 ToolExecutionOutcome.request_step_result!(outcome)
               )

      assert reparsed == outcome
    end
  end

  describe "request terminal mapping" do
    test "completed outcomes do not produce coarse terminal attrs" do
      assert ToolExecutionOutcome.terminal_attrs!(%{status: :completed}) == :not_terminal
    end

    test "failed, cancelled, timed_out, and indeterminate outcomes produce coarse row attrs" do
      assert ToolExecutionOutcome.terminal_attrs!(%{
               status: :failed,
               error_code: "tool_failed",
               error_message: "Tool execution failed hard"
             }) == %{
               state: :failed,
               http_status: 500,
               error_code: "tool_failed",
               error_message: "Tool execution failed hard"
             }

      assert ToolExecutionOutcome.terminal_attrs!(%{status: :cancelled}) == %{
               state: :cancelled,
               http_status: 500,
               error_code: "tool_execution_cancelled",
               error_message: "Tool execution was cancelled"
             }

      assert ToolExecutionOutcome.terminal_attrs!(%{status: :timed_out}) == %{
               state: :timed_out,
               http_status: 504,
               error_code: "tool_execution_timed_out",
               error_message: "Tool execution timed out"
             }

      assert ToolExecutionOutcome.terminal_attrs!(%{
               status: :indeterminate,
               indeterminate_reason: :controller_restarted
             }) == %{
               state: :failed,
               http_status: 500,
               error_code: "tool_execution_indeterminate_controller_restarted",
               error_message: "Tool execution became indeterminate after the controller restarted"
             }
    end
  end

  describe "client surfacing and retry helpers" do
    test "returns safe-by-default HTTP and SSE mappings for terminal tool failures" do
      assert ToolExecutionOutcome.api_error_mapping!(%{
               status: :timed_out,
               error_code: "tool_timeout",
               error_message: "Tool timed out"
             }) == %{
               status: :gateway_timeout,
               type: "server_error",
               code: "tool_timeout",
               message: "Tool timed out"
             }

      assert ToolExecutionOutcome.sse_error_mapping!(%{
               status: :indeterminate,
               indeterminate_reason: :cancel_ack_missing
             }) == %{
               type: "server_error",
               code: "tool_execution_indeterminate_cancel_ack_missing",
               message: "Tool execution cancellation acknowledgement was not observed"
             }

      assert ToolExecutionOutcome.api_error_mapping!(%{status: :completed}) == :not_an_error
      assert ToolExecutionOutcome.sse_error_mapping!(%{status: :completed}) == :not_an_error
    end

    test "never auto-retries and only marks anchorless failed outcomes as manual candidates" do
      assert ToolExecutionOutcome.retry_guidance!(%{status: :completed}) == %{
               auto_retry?: false,
               manual_retry_candidate?: false
             }

      assert ToolExecutionOutcome.retry_guidance!(%{status: :failed}) == %{
               auto_retry?: false,
               manual_retry_candidate?: true
             }

      assert ToolExecutionOutcome.retry_guidance!(%{
               status: :failed,
               side_effect_anchor: "anchor_123"
             }) == %{
               auto_retry?: false,
               manual_retry_candidate?: false
             }

      assert ToolExecutionOutcome.retry_guidance!(%{
               status: :failed,
               side_effect_anchor: " anchor_123 "
             }) == %{
               auto_retry?: false,
               manual_retry_candidate?: false
             }

      assert ToolExecutionOutcome.retry_guidance!(%{
               status: :indeterminate,
               indeterminate_reason: :timeout_after_start
             }) == %{
               auto_retry?: false,
               manual_retry_candidate?: false
             }
    end
  end
end
