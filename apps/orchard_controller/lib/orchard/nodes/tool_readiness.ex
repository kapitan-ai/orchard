defmodule Orchard.Nodes.ToolReadiness do
  @moduledoc false

  alias Orchard.ToolRef

  @enforce_keys [:ref, :ready, :status_code, :status_message]
  defstruct [:ref, :ready, :status_code, :status_message]

  @type t :: %__MODULE__{
          ref: String.t(),
          ready: boolean(),
          status_code: String.t(),
          status_message: String.t()
        }

  @type persisted :: %{required(String.t()) => %{required(String.t()) => boolean() | String.t()}}

  @spec normalize_all(term(), MapSet.t(String.t())) :: %{optional(String.t()) => t()}
  def normalize_all(entries, capability_refs) when is_list(entries) do
    entries
    |> Enum.reduce(%{}, fn entry, acc ->
      case normalize(entry, capability_refs) do
        {:ok, %__MODULE__{ref: ref} = readiness} -> Map.put_new(acc, ref, readiness)
        :error -> acc
      end
    end)
  end

  def normalize_all(_entries, _capability_refs), do: %{}

  @spec persist_all(%{optional(String.t()) => t()}) :: persisted()
  def persist_all(readiness_by_ref) when is_map(readiness_by_ref) do
    Map.new(readiness_by_ref, fn {ref, readiness} -> {ref, to_persisted(readiness)} end)
  end

  @spec to_persisted(t()) :: %{required(String.t()) => boolean() | String.t()}
  def to_persisted(%__MODULE__{} = readiness) do
    %{
      "ready" => readiness.ready,
      "status_code" => readiness.status_code,
      "status_message" => readiness.status_message
    }
  end

  defp normalize(entry, capability_refs) do
    with {:ok, attrs} <- normalize_attrs(entry),
         {:ok, name} <- fetch_ref_part(attrs, :name),
         {:ok, version} <- fetch_ref_part(attrs, :version),
         ref <- "tool://#{name}@#{version}",
         true <- MapSet.member?(capability_refs, ref),
         {:ok, ready} <- fetch_ready(attrs),
         {:ok, status_code} <- fetch_optional_binary(attrs, :readiness_code),
         {:ok, status_message} <- fetch_optional_binary(attrs, :readiness_message) do
      {:ok,
       %__MODULE__{
         ref: ref,
         ready: ready,
         status_code: status_code,
         status_message: status_message
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

  defp fetch_ready(attrs) do
    case map_value(attrs, :ready) do
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp fetch_optional_binary(attrs, key) do
    case map_value(attrs, key) do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
