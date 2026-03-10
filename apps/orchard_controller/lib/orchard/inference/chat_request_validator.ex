defmodule Orchard.Inference.ChatRequestValidator do
  @moduledoc """
  Validates incoming `/v1/chat/completions` request parameters.

  Enforces SPEC.md §7.2.4:
  - Only supported fields are accepted
  - Unsupported fields return `{:error, :unsupported_parameter, field}`
  - Required fields (model, messages) are validated
  - Supported roles: system, developer, user, assistant, tool
  - Supported content: plain string, array of text parts
  - `n != 1`, audio/modalities, image input, logprobs, hosted tools,
    `json_schema`, `parallel_tool_calls=true` are explicitly rejected
  """

  @supported_fields MapSet.new([
                      "model",
                      "messages",
                      "temperature",
                      "top_p",
                      "max_tokens",
                      "max_completion_tokens",
                      "stop",
                      "stream",
                      "stream_options",
                      "user",
                      "metadata",
                      "tools",
                      "tool_choice",
                      "response_format",
                      "seed"
                    ])

  @supported_roles MapSet.new(["system", "developer", "user", "assistant", "tool"])

  @type validation_error ::
          {:error, :missing_required_field, String.t()}
          | {:error, :unsupported_parameter, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @doc """
  Validates the raw request parameters.

  Returns `{:ok, params}` on success (params unchanged),
  or `{:error, type, field}` / `{:error, type, field, reason}` on failure.
  """
  @spec validate(map()) :: {:ok, map()} | validation_error()
  def validate(params) when is_map(params) do
    with :ok <- check_unsupported_fields(params),
         :ok <- check_required_fields(params),
         :ok <- check_explicitly_rejected(params),
         :ok <- check_messages(params),
         :ok <- check_stream(params),
         :ok <- check_temperature(params),
         :ok <- check_top_p(params),
         :ok <- check_max_tokens(params),
         :ok <- check_stop(params),
         :ok <- check_response_format(params),
         :ok <- check_tools(params),
         :ok <- check_seed(params) do
      {:ok, params}
    end
  end

  # -- Field presence checks --

  defp check_unsupported_fields(params) do
    unsupported = Map.keys(params) |> Enum.find(&(not MapSet.member?(@supported_fields, &1)))

    case unsupported do
      nil -> :ok
      field -> {:error, :unsupported_parameter, field}
    end
  end

  defp check_required_fields(params) do
    cond do
      not Map.has_key?(params, "model") -> {:error, :missing_required_field, "model"}
      not Map.has_key?(params, "messages") -> {:error, :missing_required_field, "messages"}
      true -> :ok
    end
  end

  # -- Explicitly rejected parameters per §7.2.4 --

  defp check_explicitly_rejected(params) do
    cond do
      Map.get(params, "n", 1) != 1 ->
        {:error, :unsupported_parameter, "n"}

      Map.has_key?(params, "modalities") ->
        {:error, :unsupported_parameter, "modalities"}

      Map.has_key?(params, "audio") ->
        {:error, :unsupported_parameter, "audio"}

      Map.has_key?(params, "logprobs") ->
        {:error, :unsupported_parameter, "logprobs"}

      Map.has_key?(params, "top_logprobs") ->
        {:error, :unsupported_parameter, "top_logprobs"}

      Map.get(params, "parallel_tool_calls") == true ->
        {:error, :unsupported_parameter, "parallel_tool_calls"}

      true ->
        :ok
    end
  end

  # -- Message validation --

  defp check_messages(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {msg, idx}, :ok ->
      case validate_message(msg, idx) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_messages(%{"messages" => _}) do
    {:error, :invalid_value, "messages", "must be an array"}
  end

  defp validate_message(msg, idx) when is_map(msg) do
    role = Map.get(msg, "role")

    cond do
      is_nil(role) ->
        {:error, :invalid_value, "messages[#{idx}].role", "is required"}

      not MapSet.member?(@supported_roles, role) ->
        {:error, :invalid_value, "messages[#{idx}].role", "unsupported role: #{inspect(role)}"}

      true ->
        validate_message_content(msg, idx)
    end
  end

  defp validate_message(_msg, idx) do
    {:error, :invalid_value, "messages[#{idx}]", "must be an object"}
  end

  defp validate_message_content(msg, idx) do
    case Map.get(msg, "content") do
      nil ->
        # content can be nil for tool-result or assistant messages
        :ok

      content when is_binary(content) ->
        :ok

      content when is_list(content) ->
        validate_content_parts(content, idx)

      _other ->
        {:error, :invalid_value, "messages[#{idx}].content",
         "must be a string or array of text parts"}
    end
  end

  defp validate_content_parts(parts, msg_idx) do
    parts
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {part, part_idx}, :ok ->
      case validate_content_part(part, msg_idx, part_idx) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_content_part(%{"type" => "text", "text" => text}, _msg_idx, _part_idx)
       when is_binary(text),
       do: :ok

  defp validate_content_part(%{"type" => "image_url"}, msg_idx, part_idx) do
    {:error, :unsupported_parameter, "messages[#{msg_idx}].content[#{part_idx}].type=image_url"}
  end

  defp validate_content_part(%{"type" => type}, msg_idx, part_idx) do
    {:error, :invalid_value, "messages[#{msg_idx}].content[#{part_idx}].type",
     "unsupported content type: #{inspect(type)}"}
  end

  defp validate_content_part(_part, msg_idx, part_idx) do
    {:error, :invalid_value, "messages[#{msg_idx}].content[#{part_idx}]",
     "must be a text content part object"}
  end

  # -- Type checks for optional fields --

  defp check_stream(%{"stream" => stream}) when is_boolean(stream), do: :ok
  defp check_stream(%{"stream" => _}), do: {:error, :invalid_value, "stream", "must be a boolean"}
  defp check_stream(_), do: :ok

  defp check_temperature(%{"temperature" => t}) when is_number(t) and t >= 0, do: :ok

  defp check_temperature(%{"temperature" => _}),
    do: {:error, :invalid_value, "temperature", "must be a non-negative number"}

  defp check_temperature(_), do: :ok

  defp check_top_p(%{"top_p" => p}) when is_number(p) and p > 0 and p <= 1, do: :ok

  defp check_top_p(%{"top_p" => _}),
    do: {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"}

  defp check_top_p(_), do: :ok

  defp check_max_tokens(params) do
    max_tokens = Map.get(params, "max_tokens")
    max_completion_tokens = Map.get(params, "max_completion_tokens")

    with :ok <- check_mutual_exclusion(max_tokens, max_completion_tokens),
         :ok <- validate_positive_integer(max_tokens, "max_tokens") do
      validate_positive_integer(max_completion_tokens, "max_completion_tokens")
    end
  end

  defp check_mutual_exclusion(nil, _), do: :ok
  defp check_mutual_exclusion(_, nil), do: :ok

  defp check_mutual_exclusion(_, _),
    do:
      {:error, :invalid_value, "max_tokens",
       "cannot specify both max_tokens and max_completion_tokens"}

  defp validate_positive_integer(nil, _field), do: :ok
  defp validate_positive_integer(v, _field) when is_integer(v) and v > 0, do: :ok

  defp validate_positive_integer(_, field),
    do: {:error, :invalid_value, field, "must be a positive integer"}

  defp check_stop(%{"stop" => stop}) when is_binary(stop), do: :ok
  defp check_stop(%{"stop" => stop}) when is_list(stop), do: :ok
  defp check_stop(%{"stop" => nil}), do: :ok

  defp check_stop(%{"stop" => _}),
    do: {:error, :invalid_value, "stop", "must be a string, array of strings, or null"}

  defp check_stop(_), do: :ok

  defp check_response_format(%{"response_format" => %{"type" => "text"}}), do: :ok
  defp check_response_format(%{"response_format" => %{"type" => "json_object"}}), do: :ok

  defp check_response_format(%{"response_format" => %{"type" => "json_schema"}}),
    do: {:error, :unsupported_parameter, "response_format.type=json_schema"}

  defp check_response_format(%{"response_format" => %{"type" => _}}),
    do: {:error, :invalid_value, "response_format.type", "must be \"text\" or \"json_object\""}

  defp check_response_format(%{"response_format" => _}),
    do: {:error, :invalid_value, "response_format", "must include a type field"}

  defp check_response_format(_), do: :ok

  defp check_tools(%{"tools" => tools}) when is_list(tools), do: :ok

  defp check_tools(%{"tools" => _}),
    do: {:error, :invalid_value, "tools", "must be an array"}

  defp check_tools(_), do: :ok

  defp check_seed(%{"seed" => seed}) when is_integer(seed), do: :ok
  defp check_seed(%{"seed" => nil}), do: :ok

  defp check_seed(%{"seed" => _}),
    do: {:error, :invalid_value, "seed", "must be an integer or null"}

  defp check_seed(_), do: :ok
end
