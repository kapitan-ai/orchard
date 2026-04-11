defmodule Orchard.Inference.ToolExecutionSemantics do
  @moduledoc false

  alias Orchard.CanonicalRequest.Tooling
  alias Orchard.Inference.ToolingValidation

  @type reason ::
          :tool_count_mismatch
          | :invalid_requested_tool
          | :missing_runtime_name
          | :missing_registry_entry
          | :registry_entry_mismatch
          | :missing_execution_mode
          | :unexpected_registry_entry

  @type error_reason :: {:misaligned_tooling, reason()}

  @spec build(Tooling.t()) :: {:ok, Tooling.entries_snapshot()} | {:error, error_reason()}
  def build(%Tooling{tools: runtime_tools} = tooling) when is_list(runtime_tools) do
    cond do
      not ToolingValidation.effective_tool_calling?(runtime_tools, tooling.tool_choice) ->
        {:ok, %{entries: []}}

      tooling.requested_tools == [] ->
        {:ok, %{entries: []}}

      is_list(tooling.requested_tools) ->
        build_enabled_tooling(tooling, runtime_tools)

      true ->
        {:error, {:misaligned_tooling, :tool_count_mismatch}}
    end
  end

  def build(%Tooling{}), do: {:error, {:misaligned_tooling, :tool_count_mismatch}}

  defp build_enabled_tooling(%Tooling{requested_tools: requested_tools} = tooling, runtime_tools) do
    with :ok <- ensure_matching_tool_counts(requested_tools, runtime_tools),
         {:ok, registry_entries} <- registry_snapshot_entries(tooling.registry_snapshot),
         {:ok, entries, []} <- build_entries(requested_tools, runtime_tools, registry_entries) do
      {:ok, %{entries: entries}}
    else
      {:ok, _entries, _remaining_registry_entries} ->
        {:error, {:misaligned_tooling, :unexpected_registry_entry}}

      {:error, {:misaligned_tooling, _reason} = error_reason} ->
        {:error, error_reason}
    end
  end

  defp ensure_matching_tool_counts(requested_tools, runtime_tools) do
    if length(requested_tools) == length(runtime_tools) do
      :ok
    else
      {:error, {:misaligned_tooling, :tool_count_mismatch}}
    end
  end

  defp build_entries(requested_tools, runtime_tools, registry_entries) do
    requested_tools
    |> Enum.zip(runtime_tools)
    |> Enum.reduce_while({:ok, [], registry_entries}, &build_entry/2)
    |> finalize_entries()
  end

  defp finalize_entries({:ok, entries, registry_entries}),
    do: {:ok, Enum.reverse(entries), registry_entries}

  defp finalize_entries({:error, {:misaligned_tooling, _reason} = error_reason}),
    do: {:error, error_reason}

  defp build_entry({requested_tool, runtime_tool}, {:ok, entries, registry_entries}) do
    with {:ok, requested_kind} <- requested_tool_kind(requested_tool),
         {:ok, runtime_name} <- runtime_tool_name(runtime_tool),
         {:ok, entry, remaining_registry_entries} <-
           execution_entry(requested_kind, requested_tool, runtime_name, registry_entries) do
      {:cont, {:ok, [entry | entries], remaining_registry_entries}}
    else
      {:error, {:misaligned_tooling, _reason} = error_reason} ->
        {:halt, {:error, error_reason}}
    end
  end

  defp requested_tool_kind(tool) when is_map(tool) do
    ref = map_value(tool, :ref)
    name = tool |> map_value(:function) |> function_name()
    has_ref? = map_has_key?(tool, :ref)
    has_function? = map_has_key?(tool, :function)

    cond do
      has_ref? and has_function? -> {:error, {:misaligned_tooling, :invalid_requested_tool}}
      has_ref? and is_binary(ref) -> {:ok, {:registry, ref}}
      has_function? and is_binary(name) -> {:ok, :inline}
      true -> {:error, {:misaligned_tooling, :invalid_requested_tool}}
    end
  end

  defp requested_tool_kind(_tool), do: {:error, {:misaligned_tooling, :invalid_requested_tool}}

  defp runtime_tool_name(tool) when is_map(tool) do
    if is_nil(map_value(tool, :ref)) do
      case tool |> map_value(:function) |> function_name() do
        name when is_binary(name) -> {:ok, name}
        _other -> {:error, {:misaligned_tooling, :missing_runtime_name}}
      end
    else
      {:error, {:misaligned_tooling, :missing_runtime_name}}
    end
  end

  defp runtime_tool_name(_tool), do: {:error, {:misaligned_tooling, :missing_runtime_name}}

  defp execution_entry(:inline, _requested_tool, runtime_name, registry_entries) do
    {:ok,
     %{
       "name" => runtime_name,
       "provenance" => "inline",
       "disposition" => "client_passthrough",
       "execution_mode" => "client_only"
     }, registry_entries}
  end

  defp execution_entry({:registry, requested_ref}, _requested_tool, runtime_name, [entry | rest]) do
    with true <-
           registry_entry_matches?(entry, requested_ref, runtime_name) or
             {:error, {:misaligned_tooling, :registry_entry_mismatch}},
         execution_mode when is_binary(execution_mode) and execution_mode != "" <-
           map_value(entry, :execution_mode) do
      {:ok,
       %{
         "name" => runtime_name,
         "provenance" => "registry",
         "disposition" => "client_passthrough",
         "execution_mode" => execution_mode
       }, rest}
    else
      nil -> {:error, {:misaligned_tooling, :missing_execution_mode}}
      {:error, {:misaligned_tooling, _reason} = error_reason} -> {:error, error_reason}
      false -> {:error, {:misaligned_tooling, :registry_entry_mismatch}}
    end
  end

  defp execution_entry({:registry, _requested_ref}, _requested_tool, _runtime_name, []),
    do: {:error, {:misaligned_tooling, :missing_registry_entry}}

  defp registry_entry_matches?(entry, requested_ref, runtime_name) do
    map_value(entry, :ref) == requested_ref and map_value(entry, :name) == runtime_name
  end

  defp registry_snapshot_entries(%{entries: entries}) when is_list(entries), do: {:ok, entries}

  defp registry_snapshot_entries(%{"entries" => entries}) when is_list(entries),
    do: {:ok, entries}

  defp registry_snapshot_entries(_registry_snapshot),
    do: {:error, {:misaligned_tooling, :missing_registry_entry}}

  defp function_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp function_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp function_name(_function), do: nil

  defp map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_has_key?(map, key) do
    Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
  end
end
