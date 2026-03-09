defmodule Orchard.Cluster.V1.InferenceEventMapper do
  @moduledoc false

  alias Orchard.Cluster.V1
  alias Orchard.InferenceEvent

  alias Orchard.InferenceEvent.{
    Accepted,
    Completed,
    Failed,
    OutputTextDelta,
    Progress,
    ToolCallDelta,
    Usage,
    UsageUpdate
  }

  @type decode_error ::
          :missing_event
          | :missing_usage
          | {:invalid_payload, atom(), term()}
          | {:invalid_usage, term()}
          | {:unknown_event, term()}
          | {:unknown_finish_reason, term()}

  @spec to_proto(InferenceEvent.t()) :: V1.InferenceEvent.t()
  def to_proto(%InferenceEvent{event: %Accepted{accepted_at_unix_ms: accepted_at_unix_ms}}) do
    %V1.InferenceEvent{event: {:accepted, %V1.Accepted{accepted_at_unix_ms: accepted_at_unix_ms}}}
  end

  def to_proto(%InferenceEvent{event: %OutputTextDelta{delta: delta}}) do
    %V1.InferenceEvent{event: {:output_text_delta, %V1.OutputTextDelta{delta: delta}}}
  end

  def to_proto(%InferenceEvent{
        event: %ToolCallDelta{tool_call_id: tool_call_id, delta_json: delta_json}
      }) do
    %V1.InferenceEvent{
      event:
        {:tool_call_delta, %V1.ToolCallDelta{tool_call_id: tool_call_id, delta_json: delta_json}}
    }
  end

  def to_proto(%InferenceEvent{event: %UsageUpdate{usage: usage}}) do
    %V1.InferenceEvent{event: {:usage, %V1.UsageUpdate{usage: usage_to_proto(usage)}}}
  end

  def to_proto(%InferenceEvent{event: %Completed{finish_reason: finish_reason, usage: usage}}) do
    %V1.InferenceEvent{
      event:
        {:completed,
         %V1.Completed{
           finish_reason: finish_reason_to_proto(finish_reason),
           usage: usage_to_proto(usage)
         }}
    }
  end

  def to_proto(%InferenceEvent{
        event: %Failed{code: code, message: message, retryable: retryable}
      }) do
    %V1.InferenceEvent{
      event: {:failed, %V1.Failed{code: code, message: message, retryable: retryable}}
    }
  end

  def to_proto(%InferenceEvent{event: %Progress{stage: stage, message: message}}) do
    %V1.InferenceEvent{event: {:progress, %V1.Progress{stage: stage, message: message}}}
  end

  @spec from_proto(V1.InferenceEvent.t()) :: {:ok, InferenceEvent.t()} | {:error, decode_error()}
  def from_proto(%V1.InferenceEvent{event: nil}), do: {:error, :missing_event}

  def from_proto(%V1.InferenceEvent{
        event: {:accepted, %V1.Accepted{accepted_at_unix_ms: accepted_at_unix_ms}}
      }) do
    safe_build(:accepted, fn -> InferenceEvent.accepted(accepted_at_unix_ms) end)
  end

  def from_proto(%V1.InferenceEvent{
        event: {:output_text_delta, %V1.OutputTextDelta{delta: delta}}
      }) do
    safe_build(:output_text_delta, fn -> InferenceEvent.output_text_delta(delta) end)
  end

  def from_proto(%V1.InferenceEvent{
        event:
          {:tool_call_delta,
           %V1.ToolCallDelta{tool_call_id: tool_call_id, delta_json: delta_json}}
      }) do
    safe_build(:tool_call_delta, fn ->
      InferenceEvent.tool_call_delta(tool_call_id, delta_json)
    end)
  end

  def from_proto(%V1.InferenceEvent{event: {:usage, %V1.UsageUpdate{usage: nil}}}),
    do: {:error, :missing_usage}

  def from_proto(%V1.InferenceEvent{event: {:usage, %V1.UsageUpdate{usage: usage}}}) do
    case usage_from_proto(usage, allow_nil?: false) do
      {:ok, mapped_usage} ->
        safe_build(:usage, fn -> InferenceEvent.usage_update(mapped_usage) end)

      {:error, _reason} = error ->
        error
    end
  end

  def from_proto(%V1.InferenceEvent{
        event: {:completed, %V1.Completed{finish_reason: finish_reason, usage: usage}}
      }) do
    with {:ok, mapped_finish_reason} <- finish_reason_from_proto(finish_reason),
         {:ok, mapped_usage} <- usage_from_proto(usage, allow_nil?: true) do
      safe_build(:completed, fn ->
        InferenceEvent.completed(mapped_finish_reason, mapped_usage)
      end)
    end
  end

  def from_proto(%V1.InferenceEvent{
        event: {:failed, %V1.Failed{code: code, message: message, retryable: retryable}}
      }) do
    safe_build(:failed, fn -> InferenceEvent.failed(code, message, retryable) end)
  end

  def from_proto(%V1.InferenceEvent{
        event: {:progress, %V1.Progress{stage: stage, message: message}}
      }) do
    safe_build(:progress, fn -> InferenceEvent.progress(stage, message) end)
  end

  def from_proto(%V1.InferenceEvent{event: event}), do: {:error, {:unknown_event, event}}

  defp usage_to_proto(nil), do: nil

  defp usage_to_proto(%Usage{} = usage) do
    %V1.TokenUsage{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  defp usage_from_proto(nil, allow_nil?: true), do: {:ok, nil}
  defp usage_from_proto(nil, allow_nil?: false), do: {:error, :missing_usage}

  defp usage_from_proto(%V1.TokenUsage{} = usage, _opts) do
    if is_integer(usage.input_tokens) and usage.input_tokens >= 0 and
         is_integer(usage.output_tokens) and usage.output_tokens >= 0 and
         is_integer(usage.total_tokens) and usage.total_tokens >= 0 and
         usage.total_tokens == usage.input_tokens + usage.output_tokens do
      {:ok,
       %Usage{
         input_tokens: usage.input_tokens,
         output_tokens: usage.output_tokens,
         total_tokens: usage.total_tokens
       }}
    else
      {:error, {:invalid_usage, usage}}
    end
  end

  defp usage_from_proto(other, _opts), do: {:error, {:invalid_usage, other}}

  defp finish_reason_to_proto(:finish_reason_unspecified), do: :FINISH_REASON_UNSPECIFIED
  defp finish_reason_to_proto(:finish_reason_stop), do: :FINISH_REASON_STOP
  defp finish_reason_to_proto(:finish_reason_length), do: :FINISH_REASON_LENGTH

  defp finish_reason_from_proto(:FINISH_REASON_UNSPECIFIED), do: {:ok, :finish_reason_unspecified}
  defp finish_reason_from_proto(:FINISH_REASON_STOP), do: {:ok, :finish_reason_stop}
  defp finish_reason_from_proto(:FINISH_REASON_LENGTH), do: {:ok, :finish_reason_length}
  defp finish_reason_from_proto(other), do: {:error, {:unknown_finish_reason, other}}

  defp safe_build(kind, fun) do
    {:ok, fun.()}
  rescue
    ArgumentError -> {:error, {:invalid_payload, kind, :invalid_scalar_values}}
  end
end
