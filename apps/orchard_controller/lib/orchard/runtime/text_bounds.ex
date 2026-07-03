defmodule Orchard.Runtime.TextBounds do
  @moduledoc false

  @spec bounded_string(term(), String.t(), pos_integer()) :: String.t()
  def bounded_string(value, _fallback, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  def bounded_string(_value, fallback, _limit), do: fallback

  @spec bounded_optional_string(term(), pos_integer()) :: String.t() | nil
  def bounded_optional_string(value, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  def bounded_optional_string(_value, _limit), do: nil
end
