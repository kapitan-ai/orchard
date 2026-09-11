defmodule Orchard.Inference.ChatErrorTest do
  use ExUnit.Case, async: true

  alias Orchard.API.InferenceControllerSupport
  alias Orchard.Inference.{ChatError, ModelLoadFailure}
  alias Orchard.InferenceEvent

  test "prepare validation mappings preserve OpenAI envelope fields" do
    error = ChatError.from_prepare_reason({:validation, {:missing_required_field, "model"}})
    mapping = ChatError.api_mapping(error)

    assert mapping == %{
             status: :bad_request,
             type: "invalid_request_error",
             code: "missing_required_field",
             message: "Missing required field: model",
             param: "model"
           }
  end

  test "SPEC.md §7.2.7 maps model authorization denial to the exact public 403" do
    mapping =
      :model_not_authorized
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping == %{
             status: :forbidden,
             type: "invalid_request_error",
             code: "model_not_authorized",
             message: "Model not authorized for tenant",
             param: "model"
           }
  end

  test "prepare model_not_found mapping preserves current status and param" do
    mapping =
      {:model_not_found, "missing@v1"}
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping.status == :not_found
    assert mapping.type == "invalid_request_error"
    assert mapping.code == "model_not_found"
    assert mapping.param == "model"
    assert mapping.message == "Model not found: missing@v1"
  end

  test "tokenization invalid input stays a bad_request invalid_request_error" do
    mapping =
      {:tokenization, {:invalid_input, "prompt template rejected input"}}
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping.status == :bad_request
    assert mapping.type == "invalid_request_error"
    assert mapping.code == nil
    assert mapping.param == nil
    assert mapping.message == "prompt template rejected input"
  end

  test "tooling_not_supported prepare errors stay a bad_request invalid_request_error" do
    mapping =
      {:tooling_not_supported, "stub-tool-model@v1"}
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping.status == :bad_request
    assert mapping.type == "invalid_request_error"
    assert mapping.code == "tooling_not_supported"
    assert mapping.param == "model"
    assert mapping.message == "Model does not support tool calling: stub-tool-model@v1"
  end

  test "SPEC.md §7.2.7 maps unprovable render metadata to runtime_incompatible" do
    error =
      ChatError.from_prepare_reason(
        {:tokenization,
         {:runtime_incompatible,
          "tokenizer render metadata did not prove the selected negotiated reasoning contract"}}
      )

    assert ChatError.api_mapping(error) == %{
             status: :service_unavailable,
             type: "server_error",
             code: "runtime_incompatible",
             message: "Runtime is incompatible",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 503,
             error_code: "runtime_incompatible",
             error_message: "Runtime is incompatible"
           }
  end

  test "tokenization internal mapping preserves controller-owned internal_error response" do
    mapping =
      {:tokenization, {:boom, "tokenizer crashed"}}
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping.status == :internal_server_error
    assert mapping.type == "server_error"
    assert mapping.code == "internal_error"
    assert mapping.message == "Tokenization failed: tokenizer crashed"
  end

  test "manifest parse surfacing stays compatible with tokenization_internal mapping" do
    mapping =
      {:tokenization, {:internal_error, "model manifest could not be loaded for tokenization"}}
      |> ChatError.from_prepare_reason()
      |> ChatError.api_mapping()

    assert mapping.status == :internal_server_error
    assert mapping.type == "server_error"
    assert mapping.code == "internal_error"

    assert mapping.message ==
             "Tokenization failed: model manifest could not be loaded for tokenization"
  end

  test "failed timeout event maps differently for API, SSE, and terminal attrs" do
    event = InferenceEvent.failed("request_timeout", "dispatcher timed out", false)
    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: :gateway_timeout,
             type: "server_error",
             code: "request_timeout",
             message: "Request timed out",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "request_timeout",
             message: "dispatcher timed out",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :timed_out,
             http_status: 504,
             error_code: "request_timeout",
             error_message: "dispatcher timed out"
           }
  end

  test "caller disconnect event persists as cancelled while preserving API and SSE payloads" do
    event = InferenceEvent.failed("request_caller_disconnect", "caller exited", false)
    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: 499,
             type: "server_error",
             code: "request_cancelled",
             message: "Request was cancelled",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "request_cancelled",
             message: "Request was cancelled",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :cancelled,
             http_status: 499,
             error_code: "request_caller_disconnect",
             error_message: "caller exited"
           }
  end

  test "terminal conformance failures stay generic publicly and specific durably" do
    failures = [
      {"runtime_endpoint_missing_terminal", "stream ended without a terminal"},
      {"runtime_endpoint_duplicate_terminal", "stream emitted duplicate terminals"},
      {"runtime_endpoint_post_terminal_event", "stream emitted a late event"}
    ]

    for {code, message} <- failures do
      error =
        code
        |> InferenceEvent.failed(message, false)
        |> ChatError.from_failed_event()

      assert ChatError.api_mapping(error) == %{
               status: :internal_server_error,
               type: "api_error",
               code: "internal_error",
               message: "Internal error",
               param: nil
             }

      assert ChatError.sse_mapping(error) == %{
               type: "server_error",
               code: "internal_error",
               message: "Internal error",
               param: nil
             }

      assert ChatError.terminal_attrs(error) == %{
               state: :failed,
               http_status: 500,
               error_code: code,
               error_message: message
             }
    end
  end

  test "cancelled event persists cancelled state and controller message" do
    event = InferenceEvent.failed("request_cancelled", "request was cancelled upstream", false)
    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: :internal_server_error,
             type: "server_error",
             code: "request_cancelled",
             message: "Request was cancelled",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "request_cancelled",
             message: "request was cancelled upstream",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :cancelled,
             http_status: 500,
             error_code: "request_cancelled",
             error_message: "request was cancelled upstream"
           }
  end

  test "SPEC.md §7.2.7 execute-time caller disconnect aliases share the cancellation mapping" do
    reasons = [
      :request_caller_disconnect,
      {:dispatch_failed, :caller_disconnect},
      {:dispatch_failed, :request_caller_disconnect}
    ]

    for reason <- reasons do
      error = ChatError.from_execute_error(reason)

      assert ChatError.api_mapping(error) == %{
               status: 499,
               type: "server_error",
               code: "request_cancelled",
               message: "Request was cancelled",
               param: nil
             }

      assert ChatError.sse_mapping(error) == %{
               type: "server_error",
               code: "request_cancelled",
               message: "Request was cancelled",
               param: nil
             }
    end
  end

  test "cluster_busy execute errors preserve scheduler saturation mapping" do
    error = ChatError.from_execute_error(:cluster_busy)

    assert ChatError.api_mapping(error) == %{
             status: :service_unavailable,
             type: "server_error",
             code: "cluster_busy",
             message: "Cluster is busy",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "cluster_busy",
             message: "Cluster is busy",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 503,
             error_code: "cluster_busy",
             error_message: "Cluster is busy"
           }
  end

  test "tooling_not_supported failed events preserve a 400 invalid_request_error mapping" do
    event =
      InferenceEvent.failed(
        "tooling_not_supported",
        "model tokenizer does not advertise tool-calling support",
        false
      )

    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: :bad_request,
             type: "invalid_request_error",
             code: "tooling_not_supported",
             message: "model tokenizer does not advertise tool-calling support",
             param: "model"
           }

    assert ChatError.sse_mapping(error) == %{
             type: "invalid_request_error",
             code: "tooling_not_supported",
             message: "model tokenizer does not advertise tool-calling support",
             param: "model"
           }
  end

  test "SPEC.md §7.2.7 model_busy failed events map to 503 server_error" do
    event = InferenceEvent.failed("model_busy", "model already has an active request", false)
    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: :service_unavailable,
             type: "server_error",
             code: "model_busy",
             message: "Model is busy",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "model_busy",
             message: "Model is busy",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 503,
             error_code: "model_busy",
             error_message: "model already has an active request"
           }
  end

  test "SPEC.md §7.2.7 queue admission execute errors have explicit public mappings" do
    cases = [
      {:model_busy, :service_unavailable, "server_error", "model_busy", "Model is busy", :failed,
       503},
      {:queue_full, :too_many_requests, "rate_limit_error", "queue_full",
       "Inference queue is full", :failed, 429},
      {:queue_timeout, :gateway_timeout, "server_error", "queue_timeout",
       "Request timed out waiting for admission", :timed_out, 504}
    ]

    for {reason, status, type, code, message, state, http_status} <- cases do
      error = ChatError.from_execute_error(reason)

      assert ChatError.api_mapping(error) == %{
               status: status,
               type: type,
               code: code,
               message: message,
               param: nil
             }

      assert ChatError.sse_mapping(error) == %{
               type: type,
               code: code,
               message: message,
               param: nil
             }

      assert ChatError.terminal_attrs(error) == %{
               state: state,
               http_status: http_status,
               error_code: code,
               error_message: message
             }
    end
  end

  test "model load failures delegate all mappings to ModelLoadFailure" do
    failure = %ModelLoadFailure{
      category: :timeout,
      code: "deadline_exceeded",
      message: "model load exceeded its deadline"
    }

    error = ChatError.from_execute_error({:model_load_failed, failure})

    assert ChatError.api_mapping(error) == %{
             status: :gateway_timeout,
             type: "server_error",
             code: "deadline_exceeded",
             message: "model load exceeded its deadline",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "deadline_exceeded",
             message: "model load exceeded its deadline",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 504,
             error_code: "deadline_exceeded",
             error_message: "model load exceeded its deadline"
           }
  end

  test "orchestration crash execute errors stay generic across public and durable mappings" do
    error =
      ChatError.from_execute_error(
        {:orchestration_crash,
         %{phase: :scheduler, category: :exception, exception: "Elixir.FunctionClauseError"}}
      )

    assert ChatError.api_mapping(error) == %{
             status: :internal_server_error,
             type: "api_error",
             code: "internal_error",
             message: "Internal error",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "internal_error",
             message: "Internal error",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 500,
             error_code: "orchestration_error",
             error_message: "Runtime orchestration failed"
           }
  end

  test "generic execute errors preserve JSON inspect details but SSE stays sanitized" do
    error = ChatError.from_execute_error({:terminal_persist_failed, :boom})

    assert ChatError.api_mapping(error) == %{
             status: :internal_server_error,
             type: "api_error",
             code: "internal_error",
             message: "Internal error: {:terminal_persist_failed, :boom}",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "internal_error",
             message: "Internal error",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :failed,
             http_status: 500,
             error_code: "orchestration_error",
             error_message: "{:terminal_persist_failed, :boom}"
           }
  end

  test "controller support can map future tool execution outcomes without overloading ChatError" do
    reason =
      {:tool_execution_outcome,
       %{
         status: :indeterminate,
         error_code: "tool_execution_indeterminate_result_not_observed",
         error_message: "Tool execution result was not observed",
         indeterminate_reason: :result_not_observed
       }}

    assert InferenceControllerSupport.execute_error_mapping(reason) == %{
             status: :internal_server_error,
             type: "server_error",
             code: "tool_execution_indeterminate_result_not_observed",
             message: "Tool execution result was not observed",
             param: nil
           }

    assert InferenceControllerSupport.sse_error_mapping(reason) == %{
             type: "server_error",
             code: "tool_execution_indeterminate_result_not_observed",
             message: "Tool execution result was not observed",
             param: nil
           }
  end

  test "controller support keeps existing inference execute mapping behavior unchanged" do
    assert InferenceControllerSupport.execute_error_mapping({:terminal_persist_failed, :boom}) ==
             %{
               status: :internal_server_error,
               type: "api_error",
               code: "internal_error",
               message: "Internal error: {:terminal_persist_failed, :boom}",
               param: nil
             }

    assert InferenceControllerSupport.sse_error_mapping({:terminal_persist_failed, :boom}) == %{
             type: "server_error",
             code: "internal_error",
             message: "Internal error",
             param: nil
           }

    assert InferenceControllerSupport.execute_terminal_attrs({:terminal_persist_failed, :boom}) ==
             %{
               state: :failed,
               http_status: 500,
               error_code: "orchestration_error",
               error_message: "{:terminal_persist_failed, :boom}"
             }
  end

  test "controller support stages terminal attrs for future tool execution outcomes distinctly" do
    reason =
      {:tool_execution_outcome,
       %{
         status: :timed_out,
         error_code: "tool_execution_timed_out",
         error_message: "Tool execution timed out"
       }}

    assert InferenceControllerSupport.execute_terminal_attrs(reason) == %{
             state: :timed_out,
             http_status: 504,
             error_code: "tool_execution_timed_out",
             error_message: "Tool execution timed out"
           }
  end
end
