defmodule Orchard.Requests.RequestStepEvent do
  @moduledoc """
  Typed contract for `request_step.*` events persisted in `request_events`.
  """

  alias Orchard.Inference.ToolExecutionOutcome
  alias Orchard.Requests.{InferenceAttemptResult, Request, RequestEvent}

  @step_event_types [
    "request_step.started",
    "request_step.proposed",
    "request_step.completed",
    "request_step.failed",
    "request_step.cancelled",
    "request_step.timed_out",
    "request_step.interrupted",
    "request_step.indeterminate"
  ]
  @step_types ["inference_turn", "tool_call", "tool_execution"]
  @boundaries ["pre_side_effect", "post_observation"]
  @terminal_step_event_types [
    completed: "request_step.completed",
    failed: "request_step.failed",
    cancelled: "request_step.cancelled",
    timed_out: "request_step.timed_out",
    interrupted: "request_step.interrupted"
  ]

  unmapped_terminal_states =
    Request.terminal_states() -- Keyword.keys(@terminal_step_event_types)

  if unmapped_terminal_states != [] do
    raise "terminal request states without a request_step.* event type: " <>
            inspect(unmapped_terminal_states)
  end

  @top_level_fields [
    :request_id,
    :seq,
    :event_type,
    :state,
    :occurred_at,
    :step_id,
    :step_type,
    :turn_index,
    :attempt,
    :parent_step_id,
    :boundary,
    :result,
    :call_id,
    :tool_name,
    :arguments_json,
    :model_id,
    :model_version
  ]
  @string_field_keys Map.new(@top_level_fields, &{Atom.to_string(&1), &1})

  @enforce_keys [:event_type, :step_id, :step_type, :turn_index, :attempt, :boundary, :result]
  defstruct [
    :request_id,
    :seq,
    :occurred_at,
    :event_type,
    :step_id,
    :step_type,
    :turn_index,
    :attempt,
    :parent_step_id,
    :boundary,
    :result,
    :call_id,
    :tool_name,
    :arguments_json,
    :model_id,
    :model_version
  ]

  @type event_type :: String.t()
  @type step_type :: String.t()
  @type boundary :: String.t()
  @type t :: %__MODULE__{
          request_id: Ecto.UUID.t() | nil,
          seq: pos_integer() | nil,
          occurred_at: DateTime.t() | nil,
          event_type: event_type(),
          step_id: String.t(),
          step_type: step_type(),
          turn_index: pos_integer(),
          attempt: pos_integer(),
          parent_step_id: String.t() | nil,
          boundary: boundary(),
          result: map(),
          call_id: String.t() | nil,
          tool_name: String.t() | nil,
          arguments_json: String.t() | nil,
          model_id: String.t() | nil,
          model_version: String.t() | nil
        }

  @spec step_event_types() :: [event_type()]
  def step_event_types, do: @step_event_types

  @spec step_types() :: [step_type()]
  def step_types, do: @step_types

  @spec boundaries() :: [boundary()]
  def boundaries, do: @boundaries

  @doc """
  Returns the `request_step.*` event types that close an inference turn.
  """
  @spec terminal_step_event_types() :: [event_type()]
  def terminal_step_event_types, do: Keyword.values(@terminal_step_event_types)

  @doc """
  Returns the `request_step.*` event type a terminal `Request` state must persist.
  """
  @spec fetch_terminal_step_event_type(atom()) :: {:ok, event_type()} | :error
  def fetch_terminal_step_event_type(request_state) when is_atom(request_state),
    do: Keyword.fetch(@terminal_step_event_types, request_state)

  def fetch_terminal_step_event_type(_request_state), do: :error

  @doc """
  Same as `fetch_terminal_step_event_type/1` but raises on an unmapped state.
  """
  @spec terminal_step_event_type!(atom()) :: event_type()
  def terminal_step_event_type!(request_state) do
    case fetch_terminal_step_event_type(request_state) do
      {:ok, event_type} ->
        event_type

      :error ->
        raise ArgumentError,
              "no request_step.* event type for terminal state #{inspect(request_state)}"
    end
  end

  @spec request_step_event_type?(String.t()) :: boolean()
  def request_step_event_type?(event_type) when is_binary(event_type),
    do: event_type in @step_event_types

  def request_step_event_type?(_event_type), do: false

  @spec inference_turn_step_id(pos_integer(), pos_integer()) :: String.t()
  def inference_turn_step_id(turn_index, attempt) do
    "inference_turn:t#{turn_index}:a#{attempt}"
  end

  @spec tool_call_step_id(pos_integer(), String.t()) :: String.t()
  def tool_call_step_id(turn_index, call_id) do
    "tool_call:t#{turn_index}:c#{call_id}"
  end

  @spec tool_execution_step_id(pos_integer(), String.t(), pos_integer()) :: String.t()
  def tool_execution_step_id(turn_index, call_id, attempt) do
    "tool_execution:t#{turn_index}:c#{call_id}:a#{attempt}"
  end

  @spec new(t() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(%__MODULE__{} = step_event), do: step_event |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs), do: build(attrs, :new_write)

  def new(_attrs), do: {:error, "request step event attrs must be a map"}

  defp build(attrs, identity_mode) when is_map(attrs) do
    with {:ok, normalized} <- normalize_top_level_attrs(attrs),
         {:ok, event_type} <- fetch_required_string(normalized, :event_type),
         :ok <- validate_event_type(event_type),
         :ok <- validate_nil_state(Map.get(normalized, :state)),
         {:ok, step_id} <- fetch_required_string(normalized, :step_id),
         {:ok, step_type} <- fetch_required_string(normalized, :step_type),
         :ok <- validate_step_type(step_type),
         {:ok, turn_index} <- fetch_required_pos_integer(normalized, :turn_index),
         {:ok, attempt} <- fetch_required_pos_integer(normalized, :attempt),
         {:ok, boundary} <- fetch_required_string(normalized, :boundary),
         :ok <- validate_boundary(event_type, boundary),
         {:ok, result} <- fetch_required_map(normalized, :result),
         {:ok, request_id} <- fetch_optional_string(normalized, :request_id),
         {:ok, seq} <- fetch_optional_pos_integer(normalized, :seq),
         {:ok, occurred_at} <- fetch_optional_datetime(normalized, :occurred_at),
         {:ok, parent_step_id} <- fetch_optional_string(normalized, :parent_step_id),
         {:ok, call_id} <- fetch_optional_string(normalized, :call_id),
         {:ok, tool_name} <- fetch_optional_string(normalized, :tool_name),
         {:ok, arguments_json} <- fetch_optional_string(normalized, :arguments_json),
         {:ok, model_id} <- fetch_optional_string(normalized, :model_id),
         {:ok, model_version} <- fetch_optional_string(normalized, :model_version),
         :ok <-
           validate_step_identity(
             %{
               step_id: step_id,
               step_type: step_type,
               turn_index: turn_index,
               attempt: attempt,
               call_id: call_id
             },
             identity_mode
           ),
         :ok <- validate_parent_step_id(step_type, parent_step_id),
         {:ok, result} <-
           normalize_step_payload(step_type, event_type, attempt, result, identity_mode) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         seq: seq,
         occurred_at: occurred_at,
         event_type: event_type,
         step_id: step_id,
         step_type: step_type,
         turn_index: turn_index,
         attempt: attempt,
         parent_step_id: parent_step_id,
         boundary: boundary,
         result: result,
         call_id: call_id,
         tool_name: tool_name,
         arguments_json: arguments_json,
         model_id: model_id,
         model_version: model_version
       }}
    end
  end

  @spec new!(t() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, step_event} -> step_event
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec to_request_event_attrs(t() | map()) :: {:ok, map()} | {:error, String.t()}
  def to_request_event_attrs(%__MODULE__{} = step_event) do
    {:ok,
     %{
       "event_type" => step_event.event_type,
       "state" => nil,
       "occurred_at" => step_event.occurred_at,
       "payload" => payload_map(step_event)
     }}
  end

  def to_request_event_attrs(attrs) when is_map(attrs) do
    attrs
    |> new()
    |> case do
      {:ok, step_event} -> to_request_event_attrs(step_event)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_request_event_attrs!(t() | map()) :: map()
  def to_request_event_attrs!(step_event_or_attrs) do
    case to_request_event_attrs(step_event_or_attrs) do
      {:ok, attrs} -> attrs
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec from_request_event(struct()) :: {:ok, t()} | {:error, String.t()}
  def from_request_event(%RequestEvent{} = request_event) do
    if request_step_event_type?(request_event.event_type) do
      case request_event.payload do
        payload when is_map(payload) ->
          attrs =
            payload
            |> normalize_payload_source()
            |> Map.merge(%{
              request_id: request_event.request_id,
              seq: request_event.seq,
              occurred_at: request_event.occurred_at,
              event_type: request_event.event_type,
              state: request_event.state
            })

          build(attrs, :historical_read)

        payload ->
          {:error, "request step payload must be a map, got: #{inspect(payload)}"}
      end
    else
      {:error, "request event #{inspect(request_event.event_type)} is not a request_step.* event"}
    end
  end

  @spec from_request_event!(struct()) :: t()
  def from_request_event!(%RequestEvent{} = request_event) do
    case from_request_event(request_event) do
      {:ok, step_event} -> step_event
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp validate_event_type(event_type) do
    if event_type in @step_event_types do
      :ok
    else
      {:error, "event_type must be one of #{Enum.join(@step_event_types, ", ")}"}
    end
  end

  defp validate_nil_state(nil), do: :ok

  defp validate_nil_state(_state),
    do: {:error, "request_step.* events must persist with state: nil"}

  defp validate_step_type(step_type) do
    if step_type in @step_types do
      :ok
    else
      {:error, "step_type must be one of #{Enum.join(@step_types, ", ")}"}
    end
  end

  defp validate_boundary("request_step.started", "pre_side_effect"), do: :ok

  defp validate_boundary(event_type, "post_observation")
       when event_type in @step_event_types and event_type != "request_step.started",
       do: :ok

  defp validate_boundary(_event_type, boundary) do
    {:error,
     "boundary #{inspect(boundary)} is invalid for the given event_type; started uses pre_side_effect and all other request_step.* events use post_observation"}
  end

  defp validate_step_identity(
         %{
           step_id: step_id,
           step_type: "inference_turn",
           turn_index: turn_index,
           attempt: attempt,
           call_id: nil
         },
         identity_mode
       ) do
    with :ok <- validate_inference_identity_mode(identity_mode, turn_index, attempt),
         expected = inference_turn_step_id(turn_index, attempt),
         true <- step_id == expected do
      :ok
    else
      {:error, reason} ->
        {:error, reason}

      false ->
        {:error,
         "step_id must equal #{inspect(inference_turn_step_id(turn_index, attempt))} for inference_turn steps"}
    end
  end

  defp validate_step_identity(%{step_type: "inference_turn", call_id: call_id}, _identity_mode)
       when is_binary(call_id) and call_id != "" do
    {:error, "inference_turn steps must not include call_id"}
  end

  defp validate_step_identity(
         %{
           step_id: step_id,
           step_type: "tool_call",
           turn_index: turn_index,
           call_id: call_id
         },
         _identity_mode
       )
       when is_binary(call_id) and call_id != "" do
    expected = tool_call_step_id(turn_index, call_id)

    if step_id == expected do
      :ok
    else
      {:error, "step_id must equal #{inspect(expected)} for tool_call steps"}
    end
  end

  defp validate_step_identity(
         %{
           step_id: step_id,
           step_type: "tool_execution",
           turn_index: turn_index,
           attempt: attempt,
           call_id: call_id
         },
         _identity_mode
       )
       when is_binary(call_id) and call_id != "" do
    expected = tool_execution_step_id(turn_index, call_id, attempt)

    if step_id == expected do
      :ok
    else
      {:error, "step_id must equal #{inspect(expected)} for tool_execution steps"}
    end
  end

  defp validate_step_identity(%{step_type: step_type}, _identity_mode)
       when step_type in ["tool_call", "tool_execution"] do
    {:error, "#{step_type} steps require a non-empty call_id"}
  end

  defp validate_inference_identity_mode(:new_write, 1, attempt) when attempt in [1, 2], do: :ok

  defp validate_inference_identity_mode(:new_write, _turn_index, _attempt),
    do: {:error, "only turn 1 attempts 1 and 2 are supported"}

  defp validate_inference_identity_mode(:historical_read, _turn_index, _attempt), do: :ok

  defp validate_parent_step_id("inference_turn", nil), do: :ok

  defp validate_parent_step_id("inference_turn", parent_step_id) when is_binary(parent_step_id),
    do: :ok

  defp validate_parent_step_id(_step_type, parent_step_id) when is_binary(parent_step_id), do: :ok

  defp validate_parent_step_id(step_type, nil)
       when step_type in ["tool_call", "tool_execution"] do
    {:error, "#{step_type} steps require a parent_step_id"}
  end

  defp normalize_step_payload(
         "inference_turn",
         event_type,
         attempt,
         result,
         identity_mode
       )
       when event_type in [
              "request_step.completed",
              "request_step.failed",
              "request_step.cancelled",
              "request_step.timed_out",
              "request_step.interrupted"
            ] do
    if InferenceAttemptResult.enriched?(result) do
      inference_attempt_result(identity_mode, event_type, attempt, result)
    else
      {:ok, result}
    end
  end

  defp normalize_step_payload(
         "tool_execution",
         "request_step.started",
         _attempt,
         result,
         _identity_mode
       ) do
    if result == %{} do
      {:ok, result}
    else
      {:error, "tool_execution request_step.started result must be an empty map"}
    end
  end

  defp normalize_step_payload("tool_execution", event_type, _attempt, result, _identity_mode)
       when event_type in [
              "request_step.completed",
              "request_step.failed",
              "request_step.cancelled",
              "request_step.timed_out",
              "request_step.indeterminate"
            ] do
    case ToolExecutionOutcome.from_request_step_result(event_type, result) do
      {:ok, _outcome} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_step_payload("tool_execution", event_type, _attempt, _result, _identity_mode) do
    {:error,
     "tool_execution steps only support request_step.started, request_step.completed, request_step.failed, request_step.cancelled, request_step.timed_out, or request_step.indeterminate; got: #{inspect(event_type)}"}
  end

  defp normalize_step_payload(_step_type, _event_type, _attempt, result, _identity_mode),
    do: {:ok, result}

  defp inference_attempt_result(:new_write, event_type, attempt, result),
    do: InferenceAttemptResult.new(event_type, attempt, result)

  defp inference_attempt_result(:historical_read, event_type, attempt, result),
    do: InferenceAttemptResult.from_persisted(event_type, attempt, result)

  defp normalize_top_level_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_top_level_key(key) do
        {:ok, normalized_key} ->
          {:cont,
           {:ok, Map.put(acc, normalized_key, normalize_field_value(normalized_key, value))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_top_level_key(key) when is_atom(key) and key in @top_level_fields, do: {:ok, key}

  defp normalize_top_level_key(key) when is_binary(key) do
    case Map.fetch(@string_field_keys, key) do
      {:ok, normalized_key} -> {:ok, normalized_key}
      :error -> {:error, "unexpected request step event field #{inspect(key)}"}
    end
  end

  defp normalize_top_level_key(key),
    do: {:error, "unexpected request step event field #{inspect(key)}"}

  defp normalize_field_value(:result, value) when is_map(value),
    do: normalize_payload_source(value)

  defp normalize_field_value(_key, value), do: value

  defp normalize_payload_source(payload) when is_map(payload) do
    Map.new(payload, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), normalize_payload_value(value)}
      {key, value} -> {key, normalize_payload_value(value)}
    end)
  end

  defp normalize_payload_value(%DateTime{} = value), do: value

  defp normalize_payload_value(value) when is_map(value) do
    Map.new(value, fn
      {key, nested_value} when is_atom(key) ->
        {Atom.to_string(key), normalize_payload_value(nested_value)}

      {key, nested_value} ->
        {key, normalize_payload_value(nested_value)}
    end)
  end

  defp normalize_payload_value(value) when is_list(value),
    do: Enum.map(value, &normalize_payload_value/1)

  defp normalize_payload_value(value), do: value

  defp fetch_required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, "#{key} must be a non-empty string, got: #{inspect(value)}"}
      :error -> {:error, "missing required field #{key}"}
    end
  end

  defp fetch_optional_string(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, "#{key} must be a non-empty string when present, got: #{inspect(value)}"}
    end
  end

  defp fetch_required_pos_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, "#{key} must be a positive integer, got: #{inspect(value)}"}
      :error -> {:error, "missing required field #{key}"}
    end
  end

  defp fetch_optional_pos_integer(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, "#{key} must be a positive integer when present, got: #{inspect(value)}"}
    end
  end

  defp fetch_required_map(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) -> {:ok, normalize_payload_source(value)}
      {:ok, value} -> {:error, "#{key} must be a map, got: #{inspect(value)}"}
      :error -> {:error, "missing required field #{key}"}
    end
  end

  defp fetch_optional_datetime(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      %DateTime{} = value -> {:ok, value}
      value -> {:error, "#{key} must be a DateTime when present, got: #{inspect(value)}"}
    end
  end

  defp payload_map(%__MODULE__{} = step_event) do
    %{
      "step_id" => step_event.step_id,
      "step_type" => step_event.step_type,
      "turn_index" => step_event.turn_index,
      "attempt" => step_event.attempt,
      "parent_step_id" => step_event.parent_step_id,
      "boundary" => step_event.boundary,
      "result" => step_event.result
    }
    |> maybe_put_payload_value("call_id", step_event.call_id)
    |> maybe_put_payload_value("tool_name", step_event.tool_name)
    |> maybe_put_payload_value("arguments_json", step_event.arguments_json)
    |> maybe_put_payload_value("model_id", step_event.model_id)
    |> maybe_put_payload_value("model_version", step_event.model_version)
  end

  defp maybe_put_payload_value(payload, _key, nil), do: payload
  defp maybe_put_payload_value(payload, key, value), do: Map.put(payload, key, value)
end
