defmodule Orchard.API.InferenceControllerSupportTest do
  use ExUnit.Case, async: true

  alias Orchard.API.InferenceControllerSupport
  alias Orchard.Inference.{ChatError, ModelLoadFailure}

  test "execute_error_mapping preserves existing ChatError API mappings for inference errors" do
    reason = model_load_failed_reason()

    assert InferenceControllerSupport.execute_error_mapping(reason) ==
             reason
             |> ChatError.from_execute_error()
             |> ChatError.api_mapping()
  end

  test "execute_error_mapping maps tagged tool outcomes through ToolExecutionOutcome" do
    assert InferenceControllerSupport.execute_error_mapping({
             :tool_execution_outcome,
             %{status: :indeterminate, indeterminate_reason: :result_not_observed}
           }) == %{
             status: :internal_server_error,
             type: "server_error",
             code: "tool_execution_indeterminate_result_not_observed",
             message: "Tool execution result was not observed",
             param: nil
           }
  end

  test "execute_sse_mapping preserves existing ChatError SSE mappings for inference errors" do
    reason = {:terminal_persist_failed, :boom}

    assert InferenceControllerSupport.execute_sse_mapping(reason) ==
             reason
             |> ChatError.from_execute_error()
             |> ChatError.sse_mapping()
  end

  test "execute_sse_mapping maps tagged tool outcomes through ToolExecutionOutcome" do
    assert InferenceControllerSupport.execute_sse_mapping({
             :tool_execution_outcome,
             %{status: :cancelled}
           }) == %{
             type: "server_error",
             code: "tool_execution_cancelled",
             message: "Tool execution was cancelled",
             param: nil
           }
  end

  test "execute_terminal_attrs preserves existing ChatError terminal attrs for inference errors" do
    reason = model_load_failed_reason()

    assert InferenceControllerSupport.execute_terminal_attrs(reason) ==
             reason
             |> ChatError.from_execute_error()
             |> ChatError.terminal_attrs()
  end

  test "execute_terminal_attrs maps tagged tool outcomes distinctly from inference errors" do
    assert InferenceControllerSupport.execute_terminal_attrs({
             :tool_execution_outcome,
             %{status: :timed_out}
           }) == %{
             state: :timed_out,
             http_status: 504,
             error_code: "tool_execution_timed_out",
             error_message: "Tool execution timed out"
           }
  end

  test "completed tool outcomes fail loudly through the staged controller mapping helpers" do
    assert_raise ArgumentError, ~r/execute_error_mapping\/1/, fn ->
      InferenceControllerSupport.execute_error_mapping({
        :tool_execution_outcome,
        %{status: :completed}
      })
    end

    assert_raise ArgumentError, ~r/execute_sse_mapping\/1/, fn ->
      InferenceControllerSupport.execute_sse_mapping({
        :tool_execution_outcome,
        %{status: :completed}
      })
    end

    assert_raise ArgumentError, ~r/execute_terminal_attrs\/1/, fn ->
      InferenceControllerSupport.execute_terminal_attrs({
        :tool_execution_outcome,
        %{status: :completed}
      })
    end
  end

  defp model_load_failed_reason do
    {:model_load_failed,
     %ModelLoadFailure{
       category: :timeout,
       code: "deadline_exceeded",
       message: "model load exceeded its deadline"
     }}
  end
end
