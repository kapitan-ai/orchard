defmodule Orchard.StructCasting do
  @moduledoc """
  Shared helpers for casting nested map/keyword attributes into structs.

  Used by `Orchard.CanonicalRequest` and `Orchard.ModelManifest` to handle
  flexible input shapes (maps, keyword lists, or already-constructed structs)
  while providing clear error messages on malformed data.
  """

  @doc """
  Casts a nested attribute at `key` in `attrs` into a struct of `module`.

  Handles maps, keyword lists, already-constructed structs, and nil (passthrough).
  Raises `ArgumentError` on unexpected types.
  """
  @spec cast_nested(map(), atom(), module()) :: map()
  def cast_nested(attrs, key, module) do
    case Map.get(attrs, key) do
      nil ->
        attrs

      %{__struct__: ^module} ->
        attrs

      value when is_list(value) ->
        if Keyword.keyword?(value) do
          Map.put(attrs, key, build_struct!(module, Map.new(value)))
        else
          raise ArgumentError,
                "expected #{inspect(key)} nested list input to be a keyword list, got: #{inspect(value)}"
        end

      value when is_map(value) ->
        Map.put(attrs, key, build_struct!(module, value))

      other ->
        raise ArgumentError,
              "expected #{inspect(key)} to be a #{inspect(module)} or map, got: #{inspect(other)}"
    end
  end

  @doc """
  Wraps `struct!/2` with a clear error message on malformed data.
  """
  @spec build_struct!(module(), map()) :: struct()
  def build_struct!(module, attrs) do
    struct!(module, attrs)
  rescue
    error in [ArgumentError, KeyError] ->
      reraise(
        ArgumentError.exception(
          "#{inspect(module)} received malformed nested data: #{Exception.message(error)}"
        ),
        __STACKTRACE__
      )
  end
end
