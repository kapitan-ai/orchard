defmodule Orchard.ToolRef do
  @moduledoc """
  Shared grammar helpers for Orchard tool refs.
  """

  @ref_prefix "tool://"

  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse(@ref_prefix <> rest) do
    case String.split(rest, "@", parts: 2) do
      [name, version] ->
        case {valid_part?(name), valid_part?(version)} do
          {true, true} -> {:ok, name, version}
          _other -> :error
        end

      _other ->
        :error
    end
  end

  def parse(_ref), do: :error

  @spec valid_part?(term()) :: boolean()
  def valid_part?(value) when is_binary(value) and value != "" do
    not String.contains?(value, ["@", " ", "\n", "\t"])
  end

  def valid_part?(_value), do: false
end
