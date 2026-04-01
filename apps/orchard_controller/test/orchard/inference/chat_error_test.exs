defmodule Orchard.Inference.ChatErrorTest do
  use ExUnit.Case, async: true

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
    assert mapping.message == "Tokenization failed: model manifest could not be loaded for tokenization"
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

  test "caller disconnect event persists as interrupted while preserving SSE payload" do
    event = InferenceEvent.failed("request_caller_disconnect", "caller exited", false)
    error = ChatError.from_failed_event(event)

    assert ChatError.api_mapping(error) == %{
             status: :internal_server_error,
             type: "server_error",
             code: "internal_error",
             message: "Inference failed: caller exited",
             param: nil
           }

    assert ChatError.sse_mapping(error) == %{
             type: "server_error",
             code: "request_caller_disconnect",
             message: "caller exited",
             param: nil
           }

    assert ChatError.terminal_attrs(error) == %{
             state: :interrupted,
             http_status: 500,
             error_code: "request_caller_disconnect",
             error_message: "caller exited"
           }
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

    assert ChatError.terminal_attrs(error) == %{
             state: :cancelled,
             http_status: 500,
             error_code: "request_cancelled",
             error_message: "request was cancelled upstream"
           }
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
end
