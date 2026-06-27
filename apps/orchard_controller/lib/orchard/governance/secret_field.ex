defmodule Orchard.Governance.SecretField do
  @moduledoc """
  Detects caller-supplied fields that look like plaintext credential material.
  """

  @secret_field_fragments ~w(secret token api_key api_token one_time_secret plaintext)
  @secret_field_names ~w(raw_csv)

  @type field :: String.t() | atom()

  @spec secret_field?(field()) :: boolean()
  def secret_field?(field) do
    normalized = field |> to_string() |> String.downcase()

    normalized in @secret_field_names or
      (not token_prefix_field?(normalized) and
         Enum.any?(@secret_field_fragments, &String.contains?(normalized, &1)))
  end

  @spec contains_secret_field?(term()) :: boolean()
  def contains_secret_field?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      secret_field?(key) or contains_secret_field?(value)
    end)
  end

  def contains_secret_field?(values) when is_list(values),
    do: Enum.any?(values, &contains_secret_field?/1)

  def contains_secret_field?(_value), do: false

  @spec reject_secret_fields(map()) :: map()
  def reject_secret_fields(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if secret_field?(key) do
        {key, "[redacted]"}
      else
        {key, sanitize_nested(value)}
      end
    end)
  end

  defp token_prefix_field?(field) do
    field in ["api_token_prefix", "api_token_prefixes", "token_prefix", "token_prefixes"] or
      String.ends_with?(field, "_token_prefix") or
      String.ends_with?(field, "_token_prefixes")
  end

  defp sanitize_nested(value) when is_map(value), do: reject_secret_fields(value)
  defp sanitize_nested(values) when is_list(values), do: Enum.map(values, &sanitize_nested/1)
  defp sanitize_nested(value), do: value
end
