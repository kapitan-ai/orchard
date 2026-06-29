defmodule Orchard.SchemaSupport do
  @moduledoc """
  Small shared helpers for context and schema boundary normalization.
  """

  @spec normalize_attrs(term()) :: map()
  def normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put_new(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  def normalize_attrs(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> normalize_attrs()
  def normalize_attrs(_attrs), do: %{}

  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
