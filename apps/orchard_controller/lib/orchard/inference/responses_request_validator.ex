defmodule Orchard.Inference.ResponsesRequestValidator do
  @moduledoc """
  Validates the bounded sync `/v1/responses` request subset for M2a.
  """

  alias Orchard.Inference.MessageValidation

  @supported_fields MapSet.new([
                      "model",
                      "input",
                      "instructions",
                      "temperature",
                      "top_p",
                      "max_output_tokens",
                      "metadata",
                      "store"
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
         :ok <- check_metadata(params),
         :ok <- check_store(params) do
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
    MessageValidation.validate_responses_input_items(input)
  end

  defp check_input(%{"input" => _input}) do
    {:error, :invalid_value, "input", "must be a string or array of message objects"}
  end

  defp check_instructions(%{"instructions" => instructions})
       when is_binary(instructions) or is_nil(instructions), do: :ok

  defp check_instructions(%{"instructions" => _}),
    do: {:error, :invalid_value, "instructions", "must be a string or null"}

  defp check_instructions(_), do: :ok

  defp check_temperature(%{"temperature" => temperature})
       when is_number(temperature) and temperature >= 0, do: :ok

  defp check_temperature(%{"temperature" => _}),
    do: {:error, :invalid_value, "temperature", "must be a non-negative number"}

  defp check_temperature(_), do: :ok

  defp check_top_p(%{"top_p" => top_p}) when is_number(top_p) and top_p > 0 and top_p <= 1,
    do: :ok

  defp check_top_p(%{"top_p" => _}),
    do: {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"}

  defp check_top_p(_), do: :ok

  defp check_max_output_tokens(%{"max_output_tokens" => max_output_tokens})
       when is_integer(max_output_tokens) and max_output_tokens > 0,
       do: :ok

  defp check_max_output_tokens(%{"max_output_tokens" => _}),
    do: {:error, :invalid_value, "max_output_tokens", "must be a positive integer"}

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
end
