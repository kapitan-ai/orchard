defmodule Orchard.InferenceEvent do
  @moduledoc """
  Shared domain representation of streamed inference events.
  """

  defmodule Usage do
    @moduledoc false

    defstruct input_tokens: 0, output_tokens: 0, total_tokens: 0

    @type t :: %__MODULE__{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            total_tokens: non_neg_integer()
          }
  end

  defmodule Accepted do
    @moduledoc false

    @enforce_keys [:accepted_at_unix_ms]
    defstruct accepted_at_unix_ms: 0

    @type t :: %__MODULE__{accepted_at_unix_ms: non_neg_integer()}
  end

  defmodule OutputTextDelta do
    @moduledoc false

    @enforce_keys [:delta]
    defstruct delta: ""

    @type t :: %__MODULE__{delta: String.t()}
  end

  defmodule ToolCallDelta do
    @moduledoc false

    @enforce_keys [:tool_call_id, :delta_json]
    defstruct tool_call_id: "", delta_json: ""

    @type t :: %__MODULE__{tool_call_id: String.t(), delta_json: String.t()}
  end

  defmodule UsageUpdate do
    @moduledoc false

    @enforce_keys [:usage]
    defstruct usage: nil

    @type t :: %__MODULE__{usage: Usage.t()}
  end

  defmodule Completed do
    @moduledoc false

    defstruct finish_reason: :finish_reason_unspecified, usage: nil

    @type finish_reason ::
            :finish_reason_unspecified
            | :finish_reason_stop
            | :finish_reason_length
            | :finish_reason_tool_calls
    @type t :: %__MODULE__{finish_reason: finish_reason(), usage: Usage.t() | nil}
  end

  defmodule Failed do
    @moduledoc false

    @enforce_keys [:code, :message, :retryable]
    defstruct code: "", message: "", retryable: false

    @type t :: %__MODULE__{code: String.t(), message: String.t(), retryable: boolean()}
  end

  defmodule Progress do
    @moduledoc false

    @enforce_keys [:stage, :message]
    defstruct stage: "", message: ""

    @type t :: %__MODULE__{stage: String.t(), message: String.t()}
  end

  alias __MODULE__.{
    Accepted,
    Completed,
    Failed,
    OutputTextDelta,
    Progress,
    ToolCallDelta,
    Usage,
    UsageUpdate
  }

  @enforce_keys [:event]
  defstruct event: nil

  @type payload ::
          Accepted.t()
          | OutputTextDelta.t()
          | ToolCallDelta.t()
          | UsageUpdate.t()
          | Completed.t()
          | Failed.t()
          | Progress.t()

  @type t :: %__MODULE__{event: payload()}

  @spec accepted(non_neg_integer()) :: t()
  def accepted(accepted_at_unix_ms)
      when is_integer(accepted_at_unix_ms) and accepted_at_unix_ms >= 0 do
    %__MODULE__{event: %Accepted{accepted_at_unix_ms: accepted_at_unix_ms}}
  end

  def accepted(accepted_at_unix_ms) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} accepted_at_unix_ms must be a non-negative integer, got: #{inspect(accepted_at_unix_ms)}"
  end

  @spec output_text_delta(String.t()) :: t()
  def output_text_delta(delta) when is_binary(delta) do
    %__MODULE__{event: %OutputTextDelta{delta: delta}}
  end

  def output_text_delta(delta) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} delta must be a binary, got: #{inspect(delta)}"
  end

  @spec tool_call_delta(String.t(), String.t()) :: t()
  def tool_call_delta(tool_call_id, delta_json)
      when is_binary(tool_call_id) and tool_call_id != "" and is_binary(delta_json) do
    %__MODULE__{event: %ToolCallDelta{tool_call_id: tool_call_id, delta_json: delta_json}}
  end

  def tool_call_delta(tool_call_id, delta_json) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} tool_call_delta expects a non-empty binary tool_call_id and binary delta_json, got: #{inspect({tool_call_id, delta_json})}"
  end

  @spec usage_update(Usage.t()) :: t()
  def usage_update(%Usage{} = usage),
    do: %__MODULE__{event: %UsageUpdate{usage: validate_usage!(usage)}}

  def usage_update(usage) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} usage_update expects a #{inspect(Usage)}, got: #{inspect(usage)}"
  end

  @spec completed(Completed.finish_reason(), Usage.t() | nil) :: t()
  def completed(finish_reason, %Usage{} = usage),
    do: %__MODULE__{
      event: %Completed{
        finish_reason: validate_finish_reason!(finish_reason),
        usage: validate_usage!(usage)
      }
    }

  def completed(finish_reason, nil),
    do: %__MODULE__{
      event: %Completed{finish_reason: validate_finish_reason!(finish_reason), usage: nil}
    }

  def completed(finish_reason, usage) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} completed expects nil or a #{inspect(Usage)} usage payload, got: #{inspect({finish_reason, usage})}"
  end

  @spec failed(String.t(), String.t(), boolean()) :: t()
  def failed(code, message, retryable)
      when is_binary(code) and code != "" and is_binary(message) and message != "" and
             is_boolean(retryable) do
    %__MODULE__{event: %Failed{code: code, message: message, retryable: retryable}}
  end

  def failed(code, message, retryable) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} failed expects non-empty binary code/message and boolean retryable, got: #{inspect({code, message, retryable})}"
  end

  @spec progress(String.t(), String.t()) :: t()
  def progress(stage, message)
      when is_binary(stage) and stage != "" and is_binary(message) and message != "" do
    %__MODULE__{event: %Progress{stage: stage, message: message}}
  end

  def progress(stage, message) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} progress expects non-empty binary stage/message, got: #{inspect({stage, message})}"
  end

  @spec kind(t()) :: atom()
  def kind(%__MODULE__{event: %Accepted{}}), do: :accepted
  def kind(%__MODULE__{event: %OutputTextDelta{}}), do: :output_text_delta
  def kind(%__MODULE__{event: %ToolCallDelta{}}), do: :tool_call_delta
  def kind(%__MODULE__{event: %UsageUpdate{}}), do: :usage
  def kind(%__MODULE__{event: %Completed{}}), do: :completed
  def kind(%__MODULE__{event: %Failed{}}), do: :failed
  def kind(%__MODULE__{event: %Progress{}}), do: :progress

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{event: %Completed{}}), do: true
  def terminal?(%__MODULE__{event: %Failed{}}), do: true
  def terminal?(%__MODULE__{}), do: false

  defp validate_finish_reason!(finish_reason)
       when finish_reason in [
              :finish_reason_unspecified,
              :finish_reason_stop,
              :finish_reason_length,
              :finish_reason_tool_calls
            ],
       do: finish_reason

  defp validate_finish_reason!(finish_reason) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} finish_reason must be :finish_reason_unspecified, :finish_reason_stop, :finish_reason_length, or :finish_reason_tool_calls, got: #{inspect(finish_reason)}"
  end

  defp validate_usage!(
         %Usage{
           input_tokens: input_tokens,
           output_tokens: output_tokens,
           total_tokens: total_tokens
         } = usage
       )
       when is_integer(input_tokens) and input_tokens >= 0 and is_integer(output_tokens) and
              output_tokens >= 0 and is_integer(total_tokens) and total_tokens >= 0 and
              total_tokens == input_tokens + output_tokens,
       do: usage

  defp validate_usage!(usage) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} usage counters must be non-negative integers with total_tokens == input_tokens + output_tokens, got: #{inspect(usage)}"
  end
end
