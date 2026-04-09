defmodule Orchard.Inference.ChatRequestValidator do
  alias Orchard.Inference.{MessageValidation, ToolingValidation}

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
         :ok <- ToolingValidation.validate(params),
         :ok <- check_stream_options(params),
         :ok <- check_metadata(params),
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
    MessageValidation.validate_chat_messages(messages)
  end

  defp check_messages(%{"messages" => _}) do
    {:error, :invalid_value, "messages", "must be an array"}
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

  defp check_stop(%{"stop" => stop}) when is_list(stop) do
    if Enum.all?(stop, &is_binary/1) do
      :ok
    else
      {:error, :invalid_value, "stop", "must be a string, array of strings, or null"}
    end
  end

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

  defp check_stream_options(%{"stream_options" => opts}) when is_map(opts), do: :ok
  defp check_stream_options(%{"stream_options" => nil}), do: :ok

  defp check_stream_options(%{"stream_options" => _}),
    do: {:error, :invalid_value, "stream_options", "must be an object or null"}

  defp check_stream_options(_), do: :ok

  defp check_metadata(%{"metadata" => meta}) when is_map(meta), do: :ok
  defp check_metadata(%{"metadata" => nil}), do: :ok

  defp check_metadata(%{"metadata" => _}),
    do: {:error, :invalid_value, "metadata", "must be an object or null"}

  defp check_metadata(_), do: :ok

  defp check_seed(%{"seed" => seed}) when is_integer(seed), do: :ok
  defp check_seed(%{"seed" => nil}), do: :ok

  defp check_seed(%{"seed" => _}),
    do: {:error, :invalid_value, "seed", "must be an integer or null"}

  defp check_seed(_), do: :ok
end
