defmodule Orchard.SentryFilter do
  @moduledoc """
  Shared Sentry event scrubber for Orchard.

  Operates on generic maps and structs so orchard_shared does not need a Sentry compile dependency.
  """

  @filtered "[Filtered]"
  @redacted "[redacted]"

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
                    "url",
                    "raw_url",
                    "request_url",
                    "query_string",
                    "path",
                    "node_id",
                    "orchard_node_id",
                    "token",
                    "token_prefix",
                    "access_token",
                    "refresh_token",
                    "api_key",
                    "api_key_prefix",
                    "apikey",
                    "key_prefix",
                    "x_api_key",
                    "api_key_id",
                    "tenant_id",
                    "principal_id",
                    "secret",
                    "client_secret",
                    "secret_access_key",
                    "secret_hash",
                    "password",
                    "authorization",
                    "authorization_header",
                    "bearer",
                    "cookie",
                    "cookies",
                    "email",
                    "ip_address"
                  ])

  @safe_token_keys MapSet.new([
                     "input_tokens",
                     "output_tokens",
                     "total_tokens",
                     "prompt_tokens",
                     "completion_tokens",
                     "max_tokens",
                     "token_usage"
                   ])

  @spec filter(map() | struct()) :: map() | struct()

  def filter(event) when is_map(event) do
    scrub_nested(event)
  rescue
    _exception -> fail_closed(event)
  catch
    _kind, _reason -> fail_closed(event)
  end

  def filter(other), do: other

  defp fail_closed(%{__struct__: module} = event) when is_atom(module) do
    base = struct(module)
    allowed_keys = base |> Map.from_struct() |> Map.keys() |> MapSet.new()

    safe_values =
      event
      |> Map.from_struct()
      |> Map.take([:event_id, :timestamp, :level, :platform, :release, :environment])
      |> Map.take(MapSet.to_list(allowed_keys))

    base
    |> Map.from_struct()
    |> Map.merge(safe_values)
    |> maybe_put_allowed(allowed_keys, :message, @filtered)
    |> maybe_put_allowed(allowed_keys, :server_name, @redacted)
    |> maybe_put_allowed(allowed_keys, :user, %{})
    |> maybe_put_allowed(allowed_keys, :extra, %{sentry_filter_failed: true})
    |> then(&struct(module, &1))
  rescue
    _exception -> fail_closed_map(event)
  catch
    _kind, _reason -> fail_closed_map(event)
  end

  defp fail_closed(event) when is_map(event), do: fail_closed_map(event)

  defp fail_closed_map(event) when is_map(event) do
    event
    |> Map.take(["event_id", :event_id, "timestamp", :timestamp, "level", :level])
    |> Map.merge(%{message: @filtered, server_name: @redacted, user: %{}})
  end

  defp maybe_put_allowed(map, allowed_keys, key, value) do
    if MapSet.member?(allowed_keys, key), do: Map.put(map, key, value), else: map
  end

  defp scrub_nested(value) when is_list(value), do: Enum.map(value, &scrub_nested/1)
  defp scrub_nested(value) when is_struct(value), do: scrub_struct(value)
  defp scrub_nested(value) when is_map(value), do: scrub_map(value)
  defp scrub_nested(value), do: value

  defp scrub_struct(%{__struct__: module} = value) do
    value
    |> Map.from_struct()
    |> scrub_map()
    |> then(&struct(module, &1))
  end

  defp scrub_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_key = normalize_key(key)
      Map.put(acc, key, scrub_value(normalized_key, nested_value))
    end)
  end

  defp scrub_value("server_name", _value), do: @redacted
  defp scrub_value("user", value), do: scrub_user(value)
  defp scrub_value("headers", value), do: scrub_headers(value)

  defp scrub_value(normalized_key, _value)
       when normalized_key in ["cookie", "cookies"],
       do: @filtered

  defp scrub_value(normalized_key, value) when is_binary(normalized_key) do
    if sensitive_key?(normalized_key) do
      @filtered
    else
      scrub_nested(value)
    end
  end

  defp scrub_value(_normalized_key, value), do: scrub_nested(value)

  defp scrub_user(value) when is_nil(value) or value == %{}, do: value

  defp scrub_user(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> scrub_user()
    |> then(&struct(value.__struct__, &1))
  end

  defp scrub_user(value) when is_map(value),
    do: Map.new(value, fn {key, _value} -> {key, @filtered} end)

  defp scrub_user(_value), do: @filtered

  defp scrub_headers(value) when is_map(value),
    do: Map.new(value, fn {key, _value} -> {key, @filtered} end)

  defp scrub_headers(value) when is_list(value), do: []
  defp scrub_headers(_value), do: %{}

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, key) or
      String.ends_with?(key, "_secret") or
      String.ends_with?(key, "_password") or
      (String.ends_with?(key, "_token") and not MapSet.member?(@safe_token_keys, key))
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    key
    |> Macro.underscore()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp normalize_key(_key), do: nil
end
