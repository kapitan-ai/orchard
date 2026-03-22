defmodule Orchard.Inference.ChatError do
  @moduledoc """
  Shared normalization for chat prepare/execute failures.

  Centralizes client-safe HTTP/SSE mappings and durable terminal request attrs so
  the public API and console paths stay behavior-aligned.
  """

  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.InferenceEvent

  @type kind ::
          :missing_required_field
          | :unsupported_parameter
          | :invalid_value
          | :model_not_found
          | :context_overflow
          | :tokenization_invalid_request
          | :tokenization_internal
          | :model_load_failed
          | :request_timed_out
          | :request_cancelled
          | :request_interrupted
          | :request_failed
          | :internal

  @type mapping :: %{
          status: atom(),
          type: String.t(),
          code: String.t() | nil,
          message: String.t(),
          param: String.t() | nil
        }

  @type sse_mapping :: %{
          type: String.t(),
          code: String.t() | nil,
          message: String.t(),
          param: String.t() | nil
        }

  @type terminal_attrs :: %{
          state: :failed | :cancelled | :timed_out | :interrupted,
          http_status: integer(),
          error_code: String.t(),
          error_message: String.t()
        }

  defstruct kind: :internal,
            param: nil,
            detail: nil,
            source_code: nil,
            source_message: nil,
            model_load_failure: nil

  @type t :: %__MODULE__{
          kind: kind(),
          param: String.t() | nil,
          detail: term(),
          source_code: String.t() | nil,
          source_message: String.t() | nil,
          model_load_failure: ModelLoadFailure.t() | nil
        }

  @spec from_prepare_reason(term()) :: t()
  def from_prepare_reason({:validation, {:missing_required_field, field}}),
    do: build(:missing_required_field, param: to_string(field))

  def from_prepare_reason({:validation, {:unsupported_parameter, field}}),
    do: build(:unsupported_parameter, param: to_string(field))

  def from_prepare_reason({:validation, {:invalid_value, field, reason}}),
    do: build(:invalid_value, param: to_string(field), detail: reason)

  def from_prepare_reason({:model_not_found, model_ref}),
    do: build(:model_not_found, detail: model_ref)

  def from_prepare_reason({:context_overflow, detail}),
    do: build(:context_overflow, detail: detail)

  def from_prepare_reason({:tokenization, {category, message}})
      when is_binary(message) and category in [:invalid_input, :unsupported_tokenizer],
      do: build(:tokenization_invalid_request, detail: message)

  def from_prepare_reason({:tokenization, {_category, message}}) when is_binary(message),
    do: build(:tokenization_internal, detail: message)

  def from_prepare_reason({:tokenization, reason}),
    do: build(:tokenization_internal, detail: reason)

  def from_prepare_reason(reason), do: build(:internal, detail: reason)

  @spec from_execute_error(term()) :: t()
  def from_execute_error({:model_load_failed, %ModelLoadFailure{} = failure}),
    do: build(:model_load_failed, model_load_failure: failure)

  def from_execute_error(reason), do: build(:internal, detail: reason)

  @spec from_failed_event(InferenceEvent.t()) :: t()
  def from_failed_event(%InferenceEvent{event: %InferenceEvent.Failed{} = failed}) do
    kind = failed_event_kind(failed.code)

    build(kind,
      source_code: failed.code,
      source_message: failed.message
    )
  end

  def from_failed_event(event), do: build(:internal, detail: {:unexpected_failed_event, event})

  @spec api_mapping(t()) :: mapping()
  def api_mapping(%__MODULE__{kind: :missing_required_field, param: field}) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: "missing_required_field",
      message: "Missing required field: #{field}",
      param: field
    }
  end

  def api_mapping(%__MODULE__{kind: :unsupported_parameter, param: field}) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: "unsupported_parameter",
      message: "Unsupported parameter: #{field}",
      param: field
    }
  end

  def api_mapping(%__MODULE__{kind: :invalid_value, param: field, detail: reason}) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: "invalid_value",
      message: "Invalid value for #{field}: #{reason}",
      param: field
    }
  end

  def api_mapping(%__MODULE__{kind: :model_not_found, detail: model_ref}) do
    %{
      status: :not_found,
      type: "invalid_request_error",
      code: "model_not_found",
      message: "Model not found: #{model_ref}",
      param: "model"
    }
  end

  def api_mapping(%__MODULE__{kind: :context_overflow, detail: detail}) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: "context_length_exceeded",
      message: detail,
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: :tokenization_invalid_request, detail: message}) do
    %{
      status: :bad_request,
      type: "invalid_request_error",
      code: nil,
      message: message,
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: :tokenization_internal, detail: detail}) do
    %{
      status: :internal_server_error,
      type: "server_error",
      code: "internal_error",
      message: tokenization_internal_message(detail),
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: :model_load_failed, model_load_failure: failure}) do
    failure
    |> ModelLoadFailure.api_mapping()
    |> Map.put(:param, nil)
  end

  def api_mapping(%__MODULE__{kind: :request_timed_out}) do
    %{
      status: :gateway_timeout,
      type: "server_error",
      code: "request_timeout",
      message: "Request timed out",
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: :request_cancelled}) do
    %{
      status: :internal_server_error,
      type: "server_error",
      code: "request_cancelled",
      message: "Request was cancelled",
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: kind, source_message: message})
      when kind in [:request_interrupted, :request_failed] do
    %{
      status: :internal_server_error,
      type: "server_error",
      code: "internal_error",
      message: "Inference failed: #{message}",
      param: nil
    }
  end

  def api_mapping(%__MODULE__{kind: :internal, detail: detail}) do
    %{
      status: :internal_server_error,
      type: "api_error",
      code: "internal_error",
      message: "Internal error: #{inspect(detail)}",
      param: nil
    }
  end

  @spec sse_mapping(t()) :: sse_mapping()
  @sse_passthrough_kinds [
    :request_timed_out,
    :request_cancelled,
    :request_interrupted,
    :request_failed
  ]

  def sse_mapping(%__MODULE__{kind: :model_load_failed, model_load_failure: failure}) do
    failure
    |> ModelLoadFailure.api_mapping()
    |> Map.delete(:status)
    |> Map.put(:param, nil)
  end

  def sse_mapping(%__MODULE__{kind: kind} = error) when kind in @sse_passthrough_kinds do
    %{
      type: "server_error",
      code: error.source_code,
      message: error.source_message,
      param: nil
    }
  end

  def sse_mapping(%__MODULE__{kind: :internal}) do
    %{
      type: "server_error",
      code: "internal_error",
      message: "Internal error",
      param: nil
    }
  end

  def sse_mapping(error) do
    error
    |> api_mapping()
    |> Map.delete(:status)
  end

  @spec terminal_attrs(t()) :: terminal_attrs()
  def terminal_attrs(%__MODULE__{kind: :model_load_failed, model_load_failure: failure}),
    do: ModelLoadFailure.terminal_attrs(failure)

  def terminal_attrs(%__MODULE__{kind: :request_timed_out} = error) do
    %{
      state: :timed_out,
      http_status: 504,
      error_code: error.source_code || "request_timeout",
      error_message: error.source_message || "Request timed out"
    }
  end

  def terminal_attrs(%__MODULE__{kind: :request_cancelled} = error) do
    %{
      state: :cancelled,
      http_status: 500,
      error_code: error.source_code || "request_cancelled",
      error_message: error.source_message || "Request was cancelled"
    }
  end

  def terminal_attrs(%__MODULE__{kind: :request_interrupted} = error) do
    %{
      state: :interrupted,
      http_status: 500,
      error_code: error.source_code || "request_interrupted",
      error_message: error.source_message || "Request interrupted"
    }
  end

  def terminal_attrs(%__MODULE__{kind: :request_failed} = error) do
    %{
      state: :failed,
      http_status: 500,
      error_code: error.source_code || "internal_error",
      error_message: error.source_message || "Inference failed"
    }
  end

  def terminal_attrs(%__MODULE__{kind: :internal, detail: detail}) do
    %{
      state: :failed,
      http_status: 500,
      error_code: "orchestration_error",
      error_message: inspect(detail)
    }
  end

  defp build(kind, attrs) do
    struct!(__MODULE__, Keyword.merge([kind: kind], attrs))
  end

  defp failed_event_kind(code) when code in ["timed_out", "request_timeout", "deadline_exceeded"],
    do: :request_timed_out

  defp failed_event_kind(code) when code in ["cancelled", "request_cancelled"],
    do: :request_cancelled

  defp failed_event_kind(code)
       when code in ["request_client_disconnect", "request_caller_disconnect"],
       do: :request_interrupted

  defp failed_event_kind(_code), do: :request_failed

  defp tokenization_internal_message(detail) when is_binary(detail),
    do: "Tokenization failed: #{detail}"

  defp tokenization_internal_message(detail), do: "Tokenization failed: #{inspect(detail)}"
end
