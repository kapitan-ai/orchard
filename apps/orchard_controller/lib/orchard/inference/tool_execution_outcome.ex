defmodule Orchard.Inference.ToolExecutionOutcome do
  @moduledoc """
  Controller-owned normalization for future tool-execution outcomes.
  """

  @statuses [:completed, :failed, :cancelled, :timed_out, :indeterminate]
  @indeterminate_reasons [
    :controller_restarted,
    :executor_unreachable,
    :timeout_after_start,
    :cancel_ack_missing,
    :result_not_observed
  ]

  @enforce_keys [:status]
  defstruct [
    :status,
    :error_code,
    :error_message,
    :indeterminate_reason,
    :remote_execution_ref,
    :side_effect_anchor
  ]

  @type status :: :completed | :failed | :cancelled | :timed_out | :indeterminate

  @type indeterminate_reason ::
          :controller_restarted
          | :executor_unreachable
          | :timeout_after_start
          | :cancel_ack_missing
          | :result_not_observed

  @type t :: %__MODULE__{
          status: status(),
          error_code: String.t() | nil,
          error_message: String.t() | nil,
          indeterminate_reason: indeterminate_reason() | nil,
          remote_execution_ref: String.t() | nil,
          side_effect_anchor: String.t() | nil
        }

  @type api_error_mapping :: %{
          status: atom(),
          type: String.t(),
          code: String.t(),
          message: String.t()
        }

  @type sse_error_mapping :: %{
          type: String.t(),
          code: String.t(),
          message: String.t()
        }

  @type terminal_attrs ::
          :not_terminal
          | %{
              state: :failed | :cancelled | :timed_out,
              http_status: integer(),
              error_code: String.t(),
              error_message: String.t()
            }

  @type retry_guidance :: %{
          auto_retry?: boolean(),
          manual_retry_candidate?: boolean()
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec indeterminate_reasons() :: [indeterminate_reason()]
  def indeterminate_reasons, do: @indeterminate_reasons

  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = outcome), do: outcome |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, status} <- fetch_status(attrs),
         {:ok, indeterminate_reason} <- fetch_indeterminate_reason(attrs, status),
         {:ok, remote_execution_ref} <- fetch_optional_string(attrs, :remote_execution_ref),
         {:ok, side_effect_anchor} <- fetch_optional_string(attrs, :side_effect_anchor),
         {:ok, error_code, error_message} <-
           normalize_error_fields(attrs, status, indeterminate_reason) do
      {:ok,
       %__MODULE__{
         status: status,
         error_code: error_code,
         error_message: error_message,
         indeterminate_reason: indeterminate_reason,
         remote_execution_ref: remote_execution_ref,
         side_effect_anchor: side_effect_anchor
       }}
    end
  end

  def new(_attrs), do: {:error, "tool execution outcome attrs must be a map"}

  @spec new!(t() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, outcome} -> outcome
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec request_step_event_type(t() | map()) :: {:ok, String.t()} | {:error, String.t()}
  def request_step_event_type(%__MODULE__{status: status}),
    do: {:ok, request_step_event_type_for(status)}

  def request_step_event_type(attrs) when is_map(attrs),
    do: attrs |> new() |> map_request_step_event_type()

  @spec request_step_event_type!(t() | map()) :: String.t()
  def request_step_event_type!(outcome_or_attrs) do
    case request_step_event_type(outcome_or_attrs) do
      {:ok, event_type} -> event_type
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec request_step_result(t() | map()) :: {:ok, map()} | {:error, String.t()}
  def request_step_result(%__MODULE__{} = outcome), do: {:ok, request_step_result_map(outcome)}

  def request_step_result(attrs) when is_map(attrs),
    do: attrs |> new() |> map_request_step_result()

  @spec request_step_result!(t() | map()) :: map()
  def request_step_result!(outcome_or_attrs) do
    case request_step_result(outcome_or_attrs) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec from_request_step_result(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def from_request_step_result(event_type, result)
      when is_binary(event_type) and is_map(result) do
    with {:ok, status} <- terminal_request_step_status(event_type),
         {:ok, normalized_result} <- normalize_result_map(result),
         :ok <- validate_result_map_keys(status, normalized_result),
         :ok <- validate_required_result_fields(status, normalized_result),
         {:ok, remote_execution_ref} <-
           fetch_result_optional_string(normalized_result, "remote_execution_ref"),
         {:ok, side_effect_anchor} <-
           fetch_result_optional_string(normalized_result, "side_effect_anchor") do
      new(%{
        status: status,
        error_code: Map.get(normalized_result, "error_code"),
        error_message: Map.get(normalized_result, "error_message"),
        indeterminate_reason: Map.get(normalized_result, "indeterminate_reason"),
        remote_execution_ref: remote_execution_ref,
        side_effect_anchor: side_effect_anchor
      })
    end
  end

  def from_request_step_result(_event_type, result) when not is_map(result) do
    {:error, "tool_execution result must be a map"}
  end

  def from_request_step_result(event_type, _result) do
    {:error, "unsupported tool_execution request_step event type #{inspect(event_type)}"}
  end

  @spec from_request_step_result!(String.t(), map()) :: t()
  def from_request_step_result!(event_type, result) do
    case from_request_step_result(event_type, result) do
      {:ok, outcome} -> outcome
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec terminal_attrs(t() | map()) :: {:ok, terminal_attrs()} | {:error, String.t()}
  def terminal_attrs(%__MODULE__{status: :completed}), do: {:ok, :not_terminal}

  def terminal_attrs(%__MODULE__{} = outcome) do
    {:ok,
     %{
       state: terminal_state(outcome.status),
       http_status: http_status(outcome.status),
       error_code: outcome.error_code,
       error_message: outcome.error_message
     }}
  end

  def terminal_attrs(attrs) when is_map(attrs), do: attrs |> new() |> map_terminal_attrs()

  @spec terminal_attrs!(t() | map()) :: terminal_attrs()
  def terminal_attrs!(outcome_or_attrs) do
    case terminal_attrs(outcome_or_attrs) do
      {:ok, terminal_attrs} -> terminal_attrs
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec api_error_mapping(t() | map()) ::
          {:ok, :not_an_error | api_error_mapping()} | {:error, String.t()}
  def api_error_mapping(%__MODULE__{status: :completed}), do: {:ok, :not_an_error}

  def api_error_mapping(%__MODULE__{} = outcome) do
    {:ok,
     %{
       status: http_status_atom(outcome.status),
       type: error_type(outcome.status),
       code: outcome.error_code,
       message: outcome.error_message
     }}
  end

  def api_error_mapping(attrs) when is_map(attrs), do: attrs |> new() |> map_api_error_mapping()

  @spec api_error_mapping!(t() | map()) :: :not_an_error | api_error_mapping()
  def api_error_mapping!(outcome_or_attrs) do
    case api_error_mapping(outcome_or_attrs) do
      {:ok, mapping} -> mapping
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec sse_error_mapping(t() | map()) ::
          {:ok, :not_an_error | sse_error_mapping()} | {:error, String.t()}
  def sse_error_mapping(%__MODULE__{status: :completed}), do: {:ok, :not_an_error}

  def sse_error_mapping(%__MODULE__{} = outcome) do
    {:ok,
     %{
       type: error_type(outcome.status),
       code: outcome.error_code,
       message: outcome.error_message
     }}
  end

  def sse_error_mapping(attrs) when is_map(attrs), do: attrs |> new() |> map_sse_error_mapping()

  @spec sse_error_mapping!(t() | map()) :: :not_an_error | sse_error_mapping()
  def sse_error_mapping!(outcome_or_attrs) do
    case sse_error_mapping(outcome_or_attrs) do
      {:ok, mapping} -> mapping
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec retry_guidance(t() | map()) :: {:ok, retry_guidance()} | {:error, String.t()}
  def retry_guidance(%__MODULE__{} = outcome) do
    {:ok,
     %{
       auto_retry?: false,
       manual_retry_candidate?: outcome.status == :failed and is_nil(outcome.side_effect_anchor)
     }}
  end

  def retry_guidance(attrs) when is_map(attrs), do: attrs |> new() |> map_retry_guidance()

  @spec retry_guidance!(t() | map()) :: retry_guidance()
  def retry_guidance!(outcome_or_attrs) do
    case retry_guidance(outcome_or_attrs) do
      {:ok, guidance} -> guidance
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp map_request_step_event_type({:ok, outcome}), do: request_step_event_type(outcome)
  defp map_request_step_event_type({:error, reason}), do: {:error, reason}

  defp map_request_step_result({:ok, outcome}), do: request_step_result(outcome)
  defp map_request_step_result({:error, reason}), do: {:error, reason}

  defp map_terminal_attrs({:ok, outcome}), do: terminal_attrs(outcome)
  defp map_terminal_attrs({:error, reason}), do: {:error, reason}

  defp map_api_error_mapping({:ok, outcome}), do: api_error_mapping(outcome)
  defp map_api_error_mapping({:error, reason}), do: {:error, reason}

  defp map_sse_error_mapping({:ok, outcome}), do: sse_error_mapping(outcome)
  defp map_sse_error_mapping({:error, reason}), do: {:error, reason}

  defp map_retry_guidance({:ok, outcome}), do: retry_guidance(outcome)
  defp map_retry_guidance({:error, reason}), do: {:error, reason}

  defp request_step_event_type_for(:completed), do: "request_step.completed"
  defp request_step_event_type_for(:failed), do: "request_step.failed"
  defp request_step_event_type_for(:cancelled), do: "request_step.cancelled"
  defp request_step_event_type_for(:timed_out), do: "request_step.timed_out"
  defp request_step_event_type_for(:indeterminate), do: "request_step.indeterminate"

  defp request_step_result_map(%__MODULE__{status: :completed} = outcome) do
    %{}
    |> maybe_put("remote_execution_ref", outcome.remote_execution_ref)
    |> maybe_put("side_effect_anchor", outcome.side_effect_anchor)
  end

  defp request_step_result_map(%__MODULE__{} = outcome) do
    %{
      "error_code" => outcome.error_code,
      "error_message" => outcome.error_message
    }
    |> maybe_put("indeterminate_reason", normalize_reason_value(outcome.indeterminate_reason))
    |> maybe_put("remote_execution_ref", outcome.remote_execution_ref)
    |> maybe_put("side_effect_anchor", outcome.side_effect_anchor)
  end

  defp terminal_state(:failed), do: :failed
  defp terminal_state(:cancelled), do: :cancelled
  defp terminal_state(:timed_out), do: :timed_out
  defp terminal_state(:indeterminate), do: :failed

  defp http_status(:failed), do: 500
  defp http_status(:cancelled), do: 500
  defp http_status(:timed_out), do: 504
  defp http_status(:indeterminate), do: 500

  defp http_status_atom(:failed), do: :internal_server_error
  defp http_status_atom(:cancelled), do: :internal_server_error
  defp http_status_atom(:timed_out), do: :gateway_timeout
  defp http_status_atom(:indeterminate), do: :internal_server_error

  defp error_type(:failed), do: "server_error"
  defp error_type(:cancelled), do: "server_error"
  defp error_type(:timed_out), do: "server_error"
  defp error_type(:indeterminate), do: "server_error"

  defp fetch_status(attrs) do
    case normalize_status_value(normalize_value(attrs, :status)) do
      {:ok, status} ->
        {:ok, status}

      :error ->
        {:error,
         "status must be one of completed, failed, cancelled, timed_out, indeterminate, got: #{inspect(normalize_value(attrs, :status))}"}
    end
  end

  defp fetch_indeterminate_reason(attrs, :indeterminate) do
    case normalize_indeterminate_reason_value(normalize_value(attrs, :indeterminate_reason)) do
      {:ok, reason} ->
        {:ok, reason}

      :missing ->
        {:error, "indeterminate outcomes require indeterminate_reason"}

      :error ->
        {:error,
         "indeterminate_reason must be one of controller_restarted, executor_unreachable, timeout_after_start, cancel_ack_missing, result_not_observed, got: #{inspect(normalize_value(attrs, :indeterminate_reason))}"}
    end
  end

  defp fetch_indeterminate_reason(attrs, _status) do
    case normalize_indeterminate_reason_value(normalize_value(attrs, :indeterminate_reason)) do
      :missing -> {:ok, nil}
      {:ok, _reason} -> {:error, "only indeterminate outcomes may include indeterminate_reason"}
      :error -> {:error, "only indeterminate outcomes may include indeterminate_reason"}
    end
  end

  defp normalize_error_fields(attrs, :completed, _indeterminate_reason) do
    with :ok <- reject_present(attrs, :error_code),
         :ok <- reject_present(attrs, :error_message) do
      {:ok, nil, nil}
    end
  end

  defp normalize_error_fields(attrs, status, indeterminate_reason) do
    {default_code, default_message} = defaults_for(status, indeterminate_reason)

    {:ok, normalize_code(normalize_value(attrs, :error_code), default_code),
     normalize_message(normalize_value(attrs, :error_message), default_message)}
  end

  defp defaults_for(:failed, _reason), do: {"tool_execution_failed", "Tool execution failed"}

  defp defaults_for(:cancelled, _reason),
    do: {"tool_execution_cancelled", "Tool execution was cancelled"}

  defp defaults_for(:timed_out, _reason),
    do: {"tool_execution_timed_out", "Tool execution timed out"}

  defp defaults_for(:indeterminate, :controller_restarted) do
    {"tool_execution_indeterminate_controller_restarted",
     "Tool execution became indeterminate after the controller restarted"}
  end

  defp defaults_for(:indeterminate, :executor_unreachable) do
    {"tool_execution_indeterminate_executor_unreachable",
     "Tool execution became indeterminate after the executor became unreachable"}
  end

  defp defaults_for(:indeterminate, :timeout_after_start) do
    {"tool_execution_indeterminate_timeout_after_start",
     "Tool execution timed out after starting and the final outcome was not observed"}
  end

  defp defaults_for(:indeterminate, :cancel_ack_missing) do
    {"tool_execution_indeterminate_cancel_ack_missing",
     "Tool execution cancellation acknowledgement was not observed"}
  end

  defp defaults_for(:indeterminate, :result_not_observed) do
    {"tool_execution_indeterminate_result_not_observed", "Tool execution result was not observed"}
  end

  defp terminal_request_step_status("request_step.completed"), do: {:ok, :completed}
  defp terminal_request_step_status("request_step.failed"), do: {:ok, :failed}
  defp terminal_request_step_status("request_step.cancelled"), do: {:ok, :cancelled}
  defp terminal_request_step_status("request_step.timed_out"), do: {:ok, :timed_out}
  defp terminal_request_step_status("request_step.indeterminate"), do: {:ok, :indeterminate}

  defp terminal_request_step_status(event_type) do
    {:error, "unsupported tool_execution request_step event type #{inspect(event_type)}"}
  end

  defp normalize_result_map(result) when is_map(result) do
    {:ok,
     Enum.reduce(result, %{}, fn {key, value}, acc ->
       {:ok, normalized_key} = normalize_result_key(key)
       Map.put(acc, normalized_key, value)
     end)}
  end

  defp normalize_result_key(key) when key in [:error_code, :error_message, :indeterminate_reason],
    do: {:ok, Atom.to_string(key)}

  defp normalize_result_key(key) when key in [:remote_execution_ref, :side_effect_anchor],
    do: {:ok, Atom.to_string(key)}

  defp normalize_result_key(key)
       when key in [
              "error_code",
              "error_message",
              "indeterminate_reason",
              "remote_execution_ref",
              "side_effect_anchor"
            ],
       do: {:ok, key}

  defp normalize_result_key(key), do: {:ok, to_string(key)}

  defp validate_result_map_keys(status, result) do
    allowed_keys = [
      "error_code",
      "error_message",
      "indeterminate_reason",
      "remote_execution_ref",
      "side_effect_anchor"
    ]

    unexpected_keys = Map.keys(result) -- allowed_keys

    if unexpected_keys == [] do
      :ok
    else
      {:error,
       "tool_execution result contains unexpected keys for #{status}: #{Enum.join(unexpected_keys, ", ")}"}
    end
  end

  defp validate_required_result_fields(:completed, _result), do: :ok

  defp validate_required_result_fields(status, result)
       when status in [:failed, :cancelled, :timed_out, :indeterminate] do
    case Enum.find(["error_code", "error_message"], &(not non_empty_binary?(Map.get(result, &1)))) do
      nil -> :ok
      missing_key -> {:error, "tool_execution result requires non-empty #{missing_key}"}
    end
  end

  defp fetch_result_optional_string(result, key) do
    case Map.get(result, key) do
      nil -> {:ok, nil}
      value -> validate_optional_result_string(key, value)
    end
  end

  defp validate_optional_result_string(key, value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" do
      {:ok, trimmed}
    else
      {:error, "tool_execution result #{key} must be a non-empty string when present"}
    end
  end

  defp validate_optional_result_string(key, _value) do
    {:error, "tool_execution result #{key} must be a non-empty string when present"}
  end

  defp reject_present(attrs, key) do
    if is_nil(normalize_value(attrs, key)) do
      :ok
    else
      {:error, "#{key} is not allowed for completed outcomes"}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case normalize_value(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" do
          {:ok, trimmed}
        else
          {:error, "#{key} must be a non-empty string when present, got: #{inspect(value)}"}
        end

      value ->
        {:error, "#{key} must be a non-empty string when present, got: #{inspect(value)}"}
    end
  end

  defp normalize_code(code, default) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed != "" and Regex.match?(~r/^[a-z0-9_]+$/, trimmed) do
      trimmed
    else
      default
    end
  end

  defp normalize_code(_, default), do: default

  defp normalize_message(message, default) when is_binary(message) do
    trimmed = String.trim(message)
    if trimmed != "", do: trimmed, else: default
  end

  defp normalize_message(_, default), do: default

  defp normalize_status_value(value) when value in @statuses, do: {:ok, value}
  defp normalize_status_value("completed"), do: {:ok, :completed}
  defp normalize_status_value("failed"), do: {:ok, :failed}
  defp normalize_status_value("cancelled"), do: {:ok, :cancelled}
  defp normalize_status_value("timed_out"), do: {:ok, :timed_out}
  defp normalize_status_value("indeterminate"), do: {:ok, :indeterminate}
  defp normalize_status_value(_value), do: :error

  defp normalize_indeterminate_reason_value(nil), do: :missing

  defp normalize_indeterminate_reason_value(value) when value in @indeterminate_reasons,
    do: {:ok, value}

  defp normalize_indeterminate_reason_value("controller_restarted"),
    do: {:ok, :controller_restarted}

  defp normalize_indeterminate_reason_value("executor_unreachable"),
    do: {:ok, :executor_unreachable}

  defp normalize_indeterminate_reason_value("timeout_after_start"),
    do: {:ok, :timeout_after_start}

  defp normalize_indeterminate_reason_value("cancel_ack_missing"), do: {:ok, :cancel_ack_missing}

  defp normalize_indeterminate_reason_value("result_not_observed"),
    do: {:ok, :result_not_observed}

  defp normalize_indeterminate_reason_value(_value), do: :error

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_reason_value(nil), do: nil
  defp normalize_reason_value(reason), do: Atom.to_string(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
