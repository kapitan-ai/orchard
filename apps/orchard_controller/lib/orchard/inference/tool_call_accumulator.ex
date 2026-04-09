defmodule Orchard.Inference.ToolCallAccumulator do
  @moduledoc """
  Assembles streamed tool-call delta events into stable chat and Responses API
  payload shapes.
  """

  alias Orchard.InferenceEvent

  @type call :: %{
          id: String.t(),
          index: non_neg_integer(),
          type: String.t(),
          function_name: String.t() | nil,
          arguments: String.t()
        }

  @type t :: %{
          order: [non_neg_integer()],
          calls: %{non_neg_integer() => call()},
          ids: %{String.t() => non_neg_integer()}
        }

  @type error_reason ::
          {:invalid_tool_call_delta, term()}
          | {:conflicting_tool_call_id, non_neg_integer(), String.t(), String.t()}
          | {:conflicting_tool_call_index, String.t(), non_neg_integer(), non_neg_integer()}
          | {:conflicting_tool_call_type, non_neg_integer(), String.t(), String.t()}
          | {:conflicting_tool_call_name, non_neg_integer(), String.t(), String.t()}

  @spec new() :: t()
  def new do
    %{order: [], calls: %{}, ids: %{}}
  end

  @spec apply_event(t(), InferenceEvent.t()) :: {:ok, t()} | {:error, error_reason()}
  def apply_event(accumulator, %InferenceEvent{event: %InferenceEvent.ToolCallDelta{} = delta}) do
    case decode_delta(delta.delta_json) do
      {:ok, normalized_delta} ->
        merge_delta(accumulator, delta.tool_call_id, normalized_delta)

      {:error, _reason} = error ->
        error
    end
  end

  def apply_event(accumulator, %InferenceEvent{}), do: {:ok, accumulator}

  @spec from_events([InferenceEvent.t()]) :: {:ok, t()} | {:error, error_reason()}
  def from_events(events) when is_list(events) do
    Enum.reduce_while(events, {:ok, new()}, fn event, {:ok, accumulator} ->
      case apply_event(accumulator, event) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec chat_tool_calls(t()) :: [map()]
  def chat_tool_calls(accumulator) do
    Enum.map(ordered_calls(accumulator), fn call ->
      %{
        id: call.id,
        type: call.type,
        function: %{
          name: call.function_name,
          arguments: call.arguments
        }
      }
    end)
  end

  @spec responses_output_items(t(), :completed | :incomplete | String.t()) :: [map()]
  def responses_output_items(accumulator, status) do
    normalized_status = normalize_item_status(status)

    Enum.map(ordered_calls(accumulator), fn call ->
      %{
        type: "function_call",
        id: call.id,
        call_id: call.id,
        name: call.function_name,
        arguments: call.arguments,
        status: normalized_status
      }
    end)
  end

  @spec preview(t()) :: String.t()
  def preview(accumulator) do
    accumulator
    |> ordered_calls()
    |> Enum.map_join("\n", fn call ->
      "Tool call: #{call.function_name || "(pending)"}(#{call.arguments})"
    end)
  end

  defp decode_delta(delta_json) when is_binary(delta_json) do
    case Jason.decode(delta_json) do
      {:ok, decoded} when is_map(decoded) -> normalize_delta(decoded)
      {:ok, other} -> {:error, {:invalid_tool_call_delta, {:invalid_shape, other}}}
      {:error, reason} -> {:error, {:invalid_tool_call_delta, {:invalid_json, reason}}}
    end
  end

  defp normalize_delta(delta) do
    with {:ok, index} <- normalize_index(Map.get(delta, "index")),
         {:ok, type} <- normalize_optional_type(Map.get(delta, "type")),
         {:ok, function_delta} <- normalize_function_delta(Map.get(delta, "function")) do
      {:ok,
       %{
         index: index,
         type: type,
         function_name: function_delta.name,
         arguments: function_delta.arguments
       }}
    end
  end

  defp normalize_index(index) when is_integer(index) and index >= 0, do: {:ok, index}
  defp normalize_index(index), do: {:error, {:invalid_tool_call_delta, {:invalid_index, index}}}

  defp normalize_optional_string(nil, _field), do: {:ok, nil}
  defp normalize_optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp normalize_optional_string(value, field) do
    {:error, {:invalid_tool_call_delta, {:invalid_field, field, value}}}
  end

  defp normalize_optional_type(nil), do: {:ok, nil}
  defp normalize_optional_type("function"), do: {:ok, "function"}

  defp normalize_optional_type(value) do
    {:error, {:invalid_tool_call_delta, {:invalid_field, :type, value}}}
  end

  defp normalize_function_delta(nil), do: {:ok, %{name: nil, arguments: ""}}

  defp normalize_function_delta(function_delta) when is_map(function_delta) do
    with {:ok, name} <- normalize_optional_string(Map.get(function_delta, "name"), :function_name),
         {:ok, arguments} <- normalize_arguments(function_delta) do
      {:ok, %{name: name, arguments: arguments}}
    end
  end

  defp normalize_function_delta(other) do
    {:error, {:invalid_tool_call_delta, {:invalid_function, other}}}
  end

  defp normalize_arguments(function_delta) do
    case {Map.get(function_delta, "arguments_delta"), Map.get(function_delta, "arguments")} do
      {value, _other} when is_binary(value) -> {:ok, value}
      {nil, value} when is_binary(value) -> {:ok, value}
      {nil, nil} -> {:ok, ""}
      {value, _other} -> {:error, {:invalid_tool_call_delta, {:invalid_arguments, value}}}
    end
  end

  defp merge_delta(accumulator, tool_call_id, normalized_delta) do
    with :ok <- ensure_id_index_consistency(accumulator, tool_call_id, normalized_delta.index) do
      case Map.get(accumulator.calls, normalized_delta.index) do
        nil ->
          {:ok, put_new_call(accumulator, tool_call_id, normalized_delta)}

        existing ->
          merge_existing_call(accumulator, existing, tool_call_id, normalized_delta)
      end
    end
  end

  defp ensure_id_index_consistency(accumulator, tool_call_id, index) do
    case Map.get(accumulator.ids, tool_call_id) do
      nil ->
        :ok

      ^index ->
        :ok

      existing_index ->
        {:error, {:conflicting_tool_call_index, tool_call_id, existing_index, index}}
    end
  end

  defp put_new_call(accumulator, tool_call_id, normalized_delta) do
    call = %{
      id: tool_call_id,
      index: normalized_delta.index,
      type: normalized_delta.type || "function",
      function_name: normalized_delta.function_name,
      arguments: normalized_delta.arguments
    }

    %{
      accumulator
      | order: accumulator.order ++ [normalized_delta.index],
        calls: Map.put(accumulator.calls, normalized_delta.index, call),
        ids: Map.put(accumulator.ids, tool_call_id, normalized_delta.index)
    }
  end

  defp merge_existing_call(accumulator, existing, tool_call_id, normalized_delta) do
    with :ok <- ensure_same_tool_call_id(existing, tool_call_id),
         :ok <- ensure_matching_type(existing, normalized_delta),
         :ok <- ensure_matching_name(existing, normalized_delta) do
      updated_call = %{
        existing
        | type: existing.type || normalized_delta.type || "function",
          function_name: existing.function_name || normalized_delta.function_name,
          arguments: existing.arguments <> normalized_delta.arguments
      }

      {:ok, %{accumulator | calls: Map.put(accumulator.calls, existing.index, updated_call)}}
    end
  end

  defp ensure_same_tool_call_id(existing, tool_call_id) do
    if existing.id == tool_call_id do
      :ok
    else
      {:error, {:conflicting_tool_call_id, existing.index, existing.id, tool_call_id}}
    end
  end

  defp ensure_matching_type(existing, normalized_delta) do
    case normalized_delta.type do
      nil ->
        :ok

      incoming_type when existing.type in [nil, incoming_type] ->
        :ok

      incoming_type ->
        {:error, {:conflicting_tool_call_type, existing.index, existing.type, incoming_type}}
    end
  end

  defp ensure_matching_name(existing, normalized_delta) do
    case normalized_delta.function_name do
      nil ->
        :ok

      incoming_name when existing.function_name in [nil, incoming_name] ->
        :ok

      incoming_name ->
        {:error,
         {:conflicting_tool_call_name, existing.index, existing.function_name, incoming_name}}
    end
  end

  defp ordered_calls(accumulator) do
    Enum.map(accumulator.order, &Map.fetch!(accumulator.calls, &1))
  end

  defp normalize_item_status(:completed), do: "completed"
  defp normalize_item_status(:incomplete), do: "incomplete"
  defp normalize_item_status("completed"), do: "completed"
  defp normalize_item_status("incomplete"), do: "incomplete"

  defp normalize_item_status(other) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} responses_output_items/2 expects :completed or :incomplete, got: #{inspect(other)}"
  end
end
