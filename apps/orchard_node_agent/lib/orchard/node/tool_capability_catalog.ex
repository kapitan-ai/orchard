defmodule Orchard.Node.ToolCapabilityCatalog do
  @moduledoc false

  alias Orchard.Cluster.V1.{HostedToolCapability, HostedToolReadiness}
  alias Orchard.Node
  alias Orchard.ToolRef

  @invalid_readiness_code "invalid_config"
  @invalid_readiness_message "invalid hosted tool readiness configuration"

  @type snapshot :: %{
          capabilities: [HostedToolCapability.t()],
          readiness: [HostedToolReadiness.t()]
        }

  @type normalized_entry :: %{
          name: String.t(),
          version: String.t(),
          adapter_kind: String.t(),
          ready: boolean(),
          readiness_code: String.t(),
          readiness_message: String.t()
        }

  @spec snapshot() :: snapshot()
  def snapshot do
    build_snapshot(Node.runtime_config()[:hosted_tools])
  end

  @spec build_snapshot(term()) :: snapshot()
  def build_snapshot(entries) when is_list(entries) do
    entries
    |> Enum.reduce({MapSet.new(), []}, &reduce_entry/2)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.sort_by(&{&1.name, &1.version})
    |> to_snapshot()
  end

  def build_snapshot(_entries), do: empty_snapshot()

  defp normalize_entry(entry) do
    with {:ok, attrs} <- normalize_attrs(entry),
         {:ok, name} <- fetch_ref_part(attrs, :name),
         {:ok, version} <- fetch_ref_part(attrs, :version),
         {:ok, adapter_kind} <- fetch_non_empty(attrs, :adapter_kind) do
      {ready, readiness_code, readiness_message} = normalize_readiness(attrs)

      {:ok,
       %{
         name: name,
         version: version,
         adapter_kind: adapter_kind,
         ready: ready,
         readiness_code: readiness_code,
         readiness_message: readiness_message
       }}
    else
      _error -> :drop
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: {:ok, attrs}

  defp normalize_attrs(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      {:ok, Map.new(attrs)}
    else
      :drop
    end
  end

  defp normalize_attrs(_attrs), do: :drop

  defp fetch_ref_part(attrs, key) do
    case map_value(attrs, key) do
      value when is_binary(value) and value != "" ->
        if ToolRef.valid_part?(value) do
          {:ok, value}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp fetch_non_empty(attrs, key) do
    case map_value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp normalize_readiness(attrs) do
    attrs
    |> readiness_fields()
    |> readiness_tuple()
  end

  defp valid_optional_binary?(nil), do: true
  defp valid_optional_binary?(value), do: is_binary(value)

  defp reduce_entry(entry, {seen, acc}) do
    case normalize_entry(entry) do
      {:ok, normalized} -> dedupe_entry(normalized, seen, acc)
      :drop -> {seen, acc}
    end
  end

  defp dedupe_entry(%{name: name, version: version} = normalized, seen, acc) do
    identity = {name, version}

    if MapSet.member?(seen, identity) do
      {seen, acc}
    else
      {MapSet.put(seen, identity), [normalized | acc]}
    end
  end

  defp readiness_fields(attrs) do
    %{
      ready: map_value(attrs, :ready),
      readiness_code: map_value(attrs, :readiness_code),
      readiness_message: map_value(attrs, :readiness_message)
    }
  end

  defp readiness_tuple(%{
         ready: ready,
         readiness_code: readiness_code,
         readiness_message: readiness_message
       })
       when is_nil(ready) and is_nil(readiness_code) and is_nil(readiness_message),
       do: {true, "", ""}

  defp readiness_tuple(%{
         ready: ready,
         readiness_code: readiness_code,
         readiness_message: readiness_message
       }) do
    if is_boolean(ready) and valid_optional_binary?(readiness_code) and
         valid_optional_binary?(readiness_message) do
      {ready, readiness_code || "", readiness_message || ""}
    else
      invalid_readiness()
    end
  end

  defp invalid_readiness do
    {false, @invalid_readiness_code, @invalid_readiness_message}
  end

  defp to_snapshot(entries) do
    %{
      capabilities: Enum.map(entries, &to_capability/1),
      readiness: Enum.map(entries, &to_readiness/1)
    }
  end

  defp to_capability(%{name: name, version: version, adapter_kind: adapter_kind}) do
    %HostedToolCapability{name: name, version: version, adapter_kind: adapter_kind}
  end

  defp to_readiness(%{
         name: name,
         version: version,
         ready: ready,
         readiness_code: readiness_code,
         readiness_message: readiness_message
       }) do
    %HostedToolReadiness{
      name: name,
      version: version,
      ready: ready,
      readiness_code: readiness_code,
      readiness_message: readiness_message
    }
  end

  defp empty_snapshot do
    %{capabilities: [], readiness: []}
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
