defmodule Orchard.Inference.SamplingValidation do
  @moduledoc """
  Shared validation for native sampling parameters accepted by Orchard's
  OpenAI-compatible API surfaces.
  """

  @type validation_error :: {:error, :invalid_value, String.t(), String.t()}

  @spec validate_temperature(map()) :: :ok | validation_error()
  def validate_temperature(%{"temperature" => temperature})
      when is_number(temperature) and temperature >= 0,
      do: :ok

  def validate_temperature(%{"temperature" => _temperature}),
    do: {:error, :invalid_value, "temperature", "must be a non-negative number"}

  def validate_temperature(_params), do: :ok

  @spec validate_top_p(map()) :: :ok | validation_error()
  def validate_top_p(%{"top_p" => top_p}) when is_number(top_p) and top_p > 0 and top_p <= 1,
    do: :ok

  def validate_top_p(%{"top_p" => _top_p}),
    do: {:error, :invalid_value, "top_p", "must be between 0 (exclusive) and 1 (inclusive)"}

  def validate_top_p(_params), do: :ok

  @spec validate_positive_integer(term(), String.t()) :: :ok | validation_error()
  def validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  def validate_positive_integer(_value, field),
    do: {:error, :invalid_value, field, "must be a positive integer"}
end
