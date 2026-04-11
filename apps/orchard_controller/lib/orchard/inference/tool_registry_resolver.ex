defmodule Orchard.Inference.ToolRegistryResolver do
  @moduledoc false

  alias Orchard.CanonicalRequest.Tooling
  alias Orchard.Inference.ToolingValidation
  alias Orchard.Tools
  alias Orchard.Tools.Tool

  @type validation_error ::
          {:error, :unsupported_parameter, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @type parsed_tool ::
          {:inline, map()} | {:ref, String.t(), String.t(), String.t()}

  @spec resolve(Tooling.t()) :: {:ok, Tooling.t()} | validation_error()
  def resolve(%Tooling{} = tooling) do
    with {:ok, parsed_tools} <- parse_requested_tools(tooling.requested_tools),
         :ok <- validate_ref_identities(parsed_tools),
         {:ok, tools, registry_entries} <- resolve_tools(parsed_tools),
         :ok <-
           ToolingValidation.validate(%{"tools" => tools, "tool_choice" => tooling.tool_choice}) do
      {:ok,
       %Tooling{
         tooling
         | tools: tools,
           registry_snapshot: %{entries: registry_entries}
       }}
    end
  end

  defp parse_requested_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case parse_requested_tool(tool) do
        {:ok, parsed_tool} -> {:cont, {:ok, [parsed_tool | acc]}}
        {:error, _type, _field} = error -> {:halt, error}
        {:error, _type, _field, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_parsed_tools()
  end

  defp parse_requested_tools(_tools), do: invalid_tool_entry()

  defp reverse_parsed_tools({:ok, parsed_tools}), do: {:ok, Enum.reverse(parsed_tools)}
  defp reverse_parsed_tools(error), do: error

  defp parse_requested_tool(%{"type" => "function", "function" => %{}, "ref" => _ref}) do
    invalid_mixed_tool_entry()
  end

  defp parse_requested_tool(%{"type" => "function", "function" => %{} = function} = tool) do
    if function_name(function) do
      {:ok, {:inline, tool}}
    else
      invalid_tool_entry()
    end
  end

  defp parse_requested_tool(%{"type" => "function", "ref" => ref}) when is_binary(ref) do
    case ToolingValidation.parse_tool_ref(ref) do
      {:ok, name, version} -> {:ok, {:ref, ref, name, version}}
      :error -> invalid_tool_ref()
    end
  end

  defp parse_requested_tool(%{"type" => "function", "ref" => _ref}), do: invalid_tool_ref()

  defp parse_requested_tool(%{"type" => type}) when is_binary(type) and type != "function" do
    {:error, :unsupported_parameter, "tools"}
  end

  defp parse_requested_tool(_tool), do: invalid_tool_entry()

  defp validate_ref_identities(parsed_tools) do
    parsed_tools
    |> Enum.reduce_while({MapSet.new(), %{}}, &accumulate_ref_identity/2)
    |> finalize_ref_validation()
  end

  defp accumulate_ref_identity({:inline, _tool}, state), do: {:cont, state}

  defp accumulate_ref_identity({:ref, _ref, name, version}, {identities, versions_by_name}) do
    identity = {name, version}

    case {MapSet.member?(identities, identity), Map.get(versions_by_name, name)} do
      {true, _existing_version} ->
        {:halt, duplicate_tool_refs()}

      {false, nil} ->
        {:cont, {MapSet.put(identities, identity), Map.put(versions_by_name, name, version)}}

      {false, ^version} ->
        {:cont, {MapSet.put(identities, identity), versions_by_name}}

      {false, _other_version} ->
        {:halt, multiple_tool_versions()}
    end
  end

  defp finalize_ref_validation({:error, _type, _field} = error), do: error
  defp finalize_ref_validation({:error, _type, _field, _reason} = error), do: error
  defp finalize_ref_validation({_identities, _versions_by_name}), do: :ok

  defp resolve_tools(parsed_tools) do
    ref_identities = Enum.flat_map(parsed_tools, &ref_identity/1)

    case ref_identities do
      [] ->
        {:ok, Enum.map(parsed_tools, &inline_tool!/1), []}

      identities ->
        fetched_tools = Tools.fetch_active_tools_by_identity(identities)

        parsed_tools
        |> Enum.reduce_while({:ok, [], []}, &accumulate_resolved_tool(&1, fetched_tools, &2))
        |> finalize_resolution()
    end
  end

  defp finalize_resolution({:ok, tools_acc, entries_acc}) do
    {:ok, Enum.reverse(tools_acc), Enum.reverse(entries_acc)}
  end

  defp finalize_resolution(error), do: error

  defp accumulate_resolved_tool(parsed_tool, fetched_tools, {:ok, tools_acc, entries_acc}) do
    case resolve_tool(parsed_tool, fetched_tools) do
      {:ok, tool_definition, nil} ->
        {:cont, {:ok, [tool_definition | tools_acc], entries_acc}}

      {:ok, tool_definition, entry} ->
        {:cont, {:ok, [tool_definition | tools_acc], [entry | entries_acc]}}

      {:error, _type, _field, _reason} = error ->
        {:halt, error}
    end
  end

  defp resolve_tool({:inline, tool}, _fetched_tools), do: {:ok, tool, nil}

  defp resolve_tool({:ref, ref, name, version}, fetched_tools) do
    case Map.get(fetched_tools, {name, version}) do
      %Tool{} = tool -> {:ok, tool.definition, registry_entry(tool)}
      nil -> {:error, :invalid_value, "tools", "tool ref #{ref} was not found or is not active"}
    end
  end

  defp ref_identity({:ref, _ref, name, version}), do: [{name, version}]
  defp ref_identity({:inline, _tool}), do: []

  defp inline_tool!({:inline, tool}), do: tool

  defp registry_entry(%Tool{} = tool) do
    %{
      "tool_id" => tool.id,
      "ref" => "tool://#{tool.name}@#{tool.version}",
      "name" => tool.name,
      "version" => tool.version,
      "execution_mode" => stringify_enum(tool.execution_mode),
      "source_kind" => stringify_enum(tool.source_kind),
      "source_ref" => tool.source_ref
    }
  end

  defp stringify_enum(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_enum(value), do: value

  defp function_name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp function_name(_function), do: nil

  defp invalid_mixed_tool_entry do
    {:error, :invalid_value, "tools", "each tool must include either function or ref, not both"}
  end

  defp invalid_tool_entry do
    {:error, :invalid_value, "tools",
     "each tool must be an object with type \"function\" and exactly one of function or ref"}
  end

  defp invalid_tool_ref do
    {:error, :invalid_value, "tools", "tool refs must match tool://<name>@<version>"}
  end

  defp duplicate_tool_refs do
    {:error, :invalid_value, "tools", "duplicate tool refs are not allowed"}
  end

  defp multiple_tool_versions do
    {:error, :invalid_value, "tools", "tool refs must use a single version per tool name"}
  end
end
