defmodule Orchard.SentryFilter do
  @moduledoc """
  Shared Sentry event scrubber for Orchard.
  """

  @filtered "[Filtered]"

  @sensitive_headers MapSet.new([
                       "authorization",
                       "cookie",
                       "x-api-key"
                     ])

  @sensitive_keys MapSet.new([
                    "messages",
                    "content",
                    "prompt",
                    "input",
                    "rendered_prompt",
                    "metadata",
                    "abs_path",
                    "filename",
                    "source_url",
                    "token",
                    "api_key",
                    "secret",
                    "secret_hash",
                    "password"
                  ])

  @spec filter(term()) :: term()
  def filter(event) when is_map(event), do: scrub_value(event)
  def filter(event), do: event

  defp scrub_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_key = normalize_key(key)

      cond do
        MapSet.member?(@sensitive_keys, normalized_key) ->
          Map.put(acc, key, @filtered)

        normalized_key == "headers" ->
          Map.put(acc, key, scrub_headers(nested_value))

        true ->
          Map.put(acc, key, scrub_value(nested_value))
      end
    end)
  end

  defp scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)
  defp scrub_value(value), do: value

  defp scrub_headers(headers) when is_map(headers) do
    Enum.reduce(headers, %{}, fn {key, value}, acc ->
      scrubbed_value = if sensitive_header?(key), do: @filtered, else: scrub_value(value)
      Map.put(acc, key, scrubbed_value)
    end)
  end

  defp scrub_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      %{"name" => name, "value" => value} = header ->
        scrubbed_value = if sensitive_header?(name), do: @filtered, else: scrub_value(value)
        %{header | "value" => scrubbed_value}

      %{name: name, value: value} = header ->
        scrubbed_value = if sensitive_header?(name), do: @filtered, else: scrub_value(value)
        %{header | value: scrubbed_value}

      {key, value} ->
        scrubbed_value = if sensitive_header?(key), do: @filtered, else: scrub_value(value)
        {key, scrubbed_value}

      other ->
        scrub_value(other)
    end)
  end

  defp scrub_headers(other), do: scrub_value(other)

  defp sensitive_header?(key), do: MapSet.member?(@sensitive_headers, normalize_key(key))

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key), do: key |> to_string() |> String.downcase()
end
