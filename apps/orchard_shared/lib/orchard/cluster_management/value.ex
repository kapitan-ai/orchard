defmodule Orchard.ClusterManagement.Value do
  @moduledoc false

  @spec normalize_string(term()) :: String.t() | nil
  def normalize_string(nil), do: nil
  def normalize_string(value) when is_atom(value), do: Atom.to_string(value)

  def normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_string(_value), do: nil

  @spec json_value(term()) :: term()
  def json_value(nil), do: nil
  def json_value(value) when is_boolean(value), do: value
  def json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_value(value) when is_atom(value), do: Atom.to_string(value)

  def json_value(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {key, json_value(val)} end)
  end

  def json_value(values) when is_list(values), do: Enum.map(values, &json_value/1)
  def json_value(value), do: value
end
