defmodule Orchard.Inference.ResponsesRequestValidator do
  @moduledoc """
  Validates the bounded sync `/v1/responses` request subset for M2a.
  """

  alias Orchard.Inference.{
    MessageValidation,
    ResponsesRequestNormalizer,
    SamplingValidation,
    ToolingValidation
  }

  @supported_fields MapSet.new([
                      "model",
                      "input",
                      "instructions",
                      "temperature",
                      "top_p",
                      "max_output_tokens",
                      "metadata",
                      "store",
                      "stream",
                      "tools",
                      "tool_choice",
                      "prompt_cache_key"
                    ])

  @type validation_error ::
          {:error, :missing_required_field, String.t()}
          | {:error, :unsupported_parameter, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @spec validate(map()) :: {:ok, map()} | validation_error()
  def validate(params) when is_map(params) do
    with :ok <- check_unsupported_fields(params),
         :ok <- check_required_fields(params),
         :ok <- check_model(params),
         :ok <- check_input(params),
         :ok <- check_instructions(params),
         :ok <- check_temperature(params),
         :ok <- check_top_p(params),
         :ok <- check_max_output_tokens(params),
         :ok <- check_tooling(params),
         :ok <- check_metadata(params),
         :ok <- check_store(params),
         :ok <- check_prompt_cache_key(params),
         :ok <- check_stream(params) do
      {:ok, params}
    end
  end

  defp check_unsupported_fields(params) do
    case Enum.find(Map.keys(params), &(not MapSet.member?(@supported_fields, &1))) do
      nil -> :ok
      field -> {:error, :unsupported_parameter, field}
    end
  end

  defp check_required_fields(params) do
    cond do
      not Map.has_key?(params, "model") -> {:error, :missing_required_field, "model"}
      not Map.has_key?(params, "input") -> {:error, :missing_required_field, "input"}
      true -> :ok
    end
  end

  defp check_model(%{"model" => model}) when is_binary(model) and model != "" do
    case String.split(model, "@", parts: 2) do
      [model_id] when model_id != "" -> :ok
      [model_id, version] when model_id != "" and version != "" -> :ok
      _other -> {:error, :invalid_value, "model", "must be a non-empty model identifier"}
    end
  end

  defp check_model(%{"model" => _model}) do
    {:error, :invalid_value, "model", "must be a non-empty model identifier"}
  end

  defp check_input(%{"input" => input}) when is_binary(input), do: :ok

  defp check_input(%{"input" => input}) when is_list(input) do
    input
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {item, index}, {:ok, calls} ->
      case check_input_item(item, "input[#{index}]", calls) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _calls} -> :ok
      error -> error
    end
  end

  defp check_input(%{"input" => _input}) do
    {:error, :invalid_value, "input", "must be a string or array of message objects"}
  end

  defp check_input_item(%{"type" => "function_call"} = item, field, calls) do
    with :ok <- only_keys(item, ~w(type id call_id name arguments status), field),
         true <- is_nil(item["id"]) or nonempty_string?(item["id"]),
         true <- nonempty_string?(item["call_id"]) and nonempty_string?(item["name"]),
         true <- valid_arguments?(item["arguments"]),
         true <- item["status"] in [nil, "completed"],
         false <- Map.has_key?(calls, item["call_id"]) do
      {:ok, Map.put(calls, item["call_id"], :pending)}
    else
      {:error, _, _, _} = error -> error
      _ -> invalid(field, "requires a unique call_id, name and JSON object arguments")
    end
  end

  defp check_input_item(%{"type" => "function_call_output"} = item, field, calls) do
    with :ok <- only_keys(item, ~w(type id call_id output status), field),
         true <- is_nil(item["id"]) or nonempty_string?(item["id"]),
         true <- is_binary(item["output"]),
         true <- item["status"] in [nil, "completed"],
         :pending <- Map.get(calls, item["call_id"]) do
      {:ok, Map.put(calls, item["call_id"], :returned)}
    else
      {:error, _, _, _} = error -> error
      _ -> invalid(field, "requires string output and a preceding call without a result")
    end
  end

  defp check_input_item(item, field, calls) when is_map(item) do
    with true <- Map.get(item, "type", "message") == "message",
         :ok <- only_keys(item, ~w(type id role content status), field),
         true <- is_nil(item["id"]) or nonempty_string?(item["id"]),
         true <- item["status"] in [nil, "completed"],
         :ok <- MessageValidation.validate_responses_input_items([validation_message(item)]) do
      {:ok, calls}
    else
      false -> invalid(field, "unsupported input item type")
      error -> error
    end
  end

  defp check_input_item(_item, field, _calls), do: invalid(field, "must be an object")

  defp validation_message(%{"role" => "assistant", "content" => content} = item)
       when is_list(content) do
    Map.put(
      item,
      "content",
      Enum.map(content, fn
        %{"type" => "output_text"} = part -> Map.put(part, "type", "input_text")
        part -> part
      end)
    )
  end

  defp validation_message(item), do: item

  defp valid_arguments?(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, value} when is_map(value) -> true
      _ -> false
    end
  end

  defp valid_arguments?(_arguments), do: false
  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp check_tooling(params) do
    with :ok <- check_tool_shapes(Map.get(params, "tools")),
         :ok <- check_choice_shape(Map.get(params, "tool_choice")) do
      params |> ResponsesRequestNormalizer.normalize_tooling() |> ToolingValidation.validate()
    end
  end

  defp check_tool_shapes(tools) when is_list(tools) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      case check_tool_shape(tool) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_tool_shapes(_tools), do: :ok

  defp check_tool_shape(%{"type" => "function", "function" => function} = tool)
       when is_map(function) do
    with :ok <- only_keys(tool, ~w(type function), "tools") do
      check_function(function)
    end
  end

  defp check_tool_shape(%{"type" => "function", "ref" => _} = tool),
    do: only_keys(tool, ~w(type ref), "tools")

  defp check_tool_shape(%{"type" => "function"} = tool) do
    with :ok <- only_keys(tool, ~w(type name description parameters strict), "tools") do
      check_function(Map.delete(tool, "type"))
    end
  end

  defp check_tool_shape(_tool), do: :ok

  defp check_function(function) do
    with :ok <- only_keys(function, ~w(name description parameters strict), "tools"),
         true <- nonempty_string?(function["name"]),
         true <- is_nil(function["description"]) or is_binary(function["description"]),
         true <- is_nil(function["strict"]) or is_boolean(function["strict"]) do
      :ok
    else
      {:error, _, _, _} = error -> error
      _ -> invalid("tools", "requires name, optional string description and boolean strict")
    end
  end

  defp check_choice_shape(%{"type" => "function", "function" => function} = choice)
       when is_map(function) do
    with :ok <- only_keys(choice, ~w(type function), "tool_choice") do
      only_keys(function, ~w(name), "tool_choice")
    end
  end

  defp check_choice_shape(choice) when is_map(choice),
    do: only_keys(choice, ~w(type name), "tool_choice")

  defp check_choice_shape(_choice), do: :ok

  defp only_keys(value, keys, field) do
    if Enum.all?(Map.keys(value), &(&1 in keys)),
      do: :ok,
      else: invalid(field, "contains unsupported or mixed fields")
  end

  defp invalid(field, reason), do: {:error, :invalid_value, field, reason}

  defp check_instructions(%{"instructions" => instructions})
       when is_binary(instructions) or is_nil(instructions), do: :ok

  defp check_instructions(%{"instructions" => _}),
    do: {:error, :invalid_value, "instructions", "must be a string or null"}

  defp check_instructions(_), do: :ok

  defp check_temperature(params), do: SamplingValidation.validate_temperature(params)

  defp check_top_p(params), do: SamplingValidation.validate_top_p(params)

  defp check_max_output_tokens(%{"max_output_tokens" => max_output_tokens}) do
    SamplingValidation.validate_positive_integer(max_output_tokens, "max_output_tokens")
  end

  defp check_max_output_tokens(_), do: :ok

  defp check_metadata(%{"metadata" => metadata}) when is_map(metadata) or is_nil(metadata),
    do: :ok

  defp check_metadata(%{"metadata" => _}),
    do: {:error, :invalid_value, "metadata", "must be an object or null"}

  defp check_metadata(_), do: :ok

  defp check_store(%{"store" => store}) when is_boolean(store) or is_nil(store), do: :ok

  defp check_store(%{"store" => _}),
    do: {:error, :invalid_value, "store", "must be a boolean or null"}

  defp check_store(_), do: :ok

  defp check_prompt_cache_key(params) do
    case Map.get(params, "prompt_cache_key") do
      value when is_binary(value) or is_nil(value) -> :ok
      _ -> invalid("prompt_cache_key", "must be a string or null")
    end
  end

  defp check_stream(%{"stream" => stream}) when is_boolean(stream), do: :ok

  defp check_stream(%{"stream" => _}),
    do: {:error, :invalid_value, "stream", "must be a boolean"}

  defp check_stream(_), do: :ok
end
