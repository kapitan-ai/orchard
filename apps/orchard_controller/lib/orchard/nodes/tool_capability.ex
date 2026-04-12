defmodule Orchard.Nodes.ToolCapability do
  @moduledoc false

  alias Orchard.ToolRef

  @enforce_keys [:ref, :name, :version, :adapter_kind]
  defstruct [:ref, :name, :version, :adapter_kind]

  @type t :: %__MODULE__{
          ref: String.t(),
          name: String.t(),
          version: String.t(),
          adapter_kind: String.t()
        }

  @type persisted :: %{required(String.t()) => String.t()}

  @spec normalize_all(term()) :: [t()]
  def normalize_all(entries) when is_list(entries) do
    entries
    |> Enum.reduce({MapSet.new(), []}, &reduce_entry/2)
    |> elem(1)
    |> Enum.reverse()
  end

  def normalize_all(_entries), do: []

  @spec persist_all([t()]) :: [persisted()]
  def persist_all(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, &to_persisted/1)
  end

  @spec refs([t()]) :: MapSet.t(String.t())
  def refs(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(& &1.ref)
    |> MapSet.new()
  end

  @spec to_persisted(t()) :: persisted()
  def to_persisted(%__MODULE__{} = capability) do
    %{
      "ref" => capability.ref,
      "name" => capability.name,
      "version" => capability.version,
      "adapter_kind" => capability.adapter_kind
    }
  end

  defp normalize(entry) do
    with {:ok, attrs} <- normalize_attrs(entry),
         {:ok, name} <- fetch_ref_part(attrs, :name),
         {:ok, version} <- fetch_ref_part(attrs, :version),
         {:ok, adapter_kind} <- fetch_non_empty(attrs, :adapter_kind) do
      {:ok,
       %__MODULE__{
         ref: "tool://#{name}@#{version}",
         name: name,
         version: version,
         adapter_kind: adapter_kind
       }}
    else
      _error -> :error
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs), do: {:ok, attrs}
  defp normalize_attrs(_attrs), do: :error

  defp fetch_ref_part(attrs, key) do
    case map_value(attrs, key) do
      value when is_binary(value) and value != "" ->
        if ToolRef.valid_part?(value), do: {:ok, value}, else: :error

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

  defp reduce_entry(entry, {seen, acc}) do
    case normalize(entry) do
      {:ok, capability} -> dedupe_capability(capability, seen, acc)
      :error -> {seen, acc}
    end
  end

  defp dedupe_capability(%__MODULE__{ref: ref} = capability, seen, acc) do
    if MapSet.member?(seen, ref) do
      {seen, acc}
    else
      {MapSet.put(seen, ref), [capability | acc]}
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
