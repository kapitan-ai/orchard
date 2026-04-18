defmodule Orchard.SentryFilter do
  @moduledoc """
  Shared Sentry event scrubber for Orchard.

  Sentry 10.x `before_send` receives `%Sentry.Event{}` structs. We scrub known fields for
  PII/secrets.
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

  @spec filter(map() | %Sentry.Event{}) :: map() | %Sentry.Event{}
  def filter(%Sentry.Event{} = event) do
    %{
      event
      | extra: scrub_map(event.extra || %{}),
        request: scrub_map(event.request || %{}),
        contexts: scrub_map(event.contexts || %{}),
        tags: scrub_map(event.tags || %{}),
        exception: scrub_exceptions(event.exception),
        message: scrub_message(event.message)
    }
  end

  def filter(event) when is_map(event) do
    # Sentry sometimes passes plain maps - scrub directly
    scrub_map(event)
  end

  # For non-map inputs, pass through (shouldn't happen with Sentry events)
  def filter(other), do: other

  defp scrub_map(value) when is_map(value) do
    # Only scrub plain maps - skip Sentry.Interfaces.* structs
    # Sentry's render_event expects these to remain as structs
    if is_struct(value) do
      # Return Sentry struct unchanged - don't convert to map
      value
    else
      Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
        normalized_key = normalize_key(key)

        cond do
          normalized_key && MapSet.member?(@sensitive_keys, normalized_key) ->
            Map.put(acc, key, @filtered)

          normalized_key == "headers" ->
            Map.put(acc, key, scrub_headers(nested_value))

          true ->
            Map.put(acc, key, scrub_nested(nested_value))
        end
      end)
    end
  end

  defp scrub_map(other), do: other

  # Helper to handle nested values - either lists or maps
  defp scrub_nested(value) when is_list(value), do: Enum.map(value, &scrub_nested/1)
  defp scrub_nested(value) when is_map(value), do: scrub_map(value)
  defp scrub_nested(value), do: value

  # Helper to scrub lists recursively (for exceptions which are lists)
  defp scrub_list(list) when is_list(list), do: Enum.map(list, &scrub_nested/1)
  defp scrub_list(other), do: scrub_nested(other)

  defp scrub_headers(headers) when is_map(headers) do
    # Don't convert Sentry.Interfaces.* structs to maps
    if is_struct(headers) do
      headers
    else
      Enum.reduce(headers, %{}, fn {key, value}, acc ->
        scrubbed_value = if sensitive_header?(key), do: @filtered, else: scrub_nested(value)
        Map.put(acc, key, scrubbed_value)
      end)
    end
  end

  defp scrub_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      %{"name" => name, "value" => value} = header ->
        scrubbed_value = if sensitive_header?(name), do: @filtered, else: scrub_map(value)
        %{header | "value" => scrubbed_value}

      %{name: name, value: value} = header ->
        scrubbed_value = if sensitive_header?(name), do: @filtered, else: scrub_map(value)
        %{header | value: scrubbed_value}

      {key, value} ->
        scrubbed_value = if sensitive_header?(key), do: @filtered, else: scrub_nested(value)
        {key, scrubbed_value}

      other ->
        scrub_nested(other)
    end)
  end

  defp scrub_headers(other), do: scrub_map(other)

  defp scrub_exceptions(exceptions), do: scrub_list(exceptions)

  defp scrub_message(message), do: scrub_list(message)

  defp sensitive_header?(key) do
    normalized_key = normalize_key(key)
    normalized_key && MapSet.member?(@sensitive_headers, normalized_key)
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(_key), do: nil
end
