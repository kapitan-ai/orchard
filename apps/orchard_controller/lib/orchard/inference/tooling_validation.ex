defmodule Orchard.Inference.ToolingValidation do
  @moduledoc """
  Shared validation for tool-calling request fields across chat and responses endpoints.
  """

  alias Orchard.ToolRef

  @type validation_error ::
          {:error, :unsupported_parameter, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @type tool_state :: %{
          inline_names: MapSet.t(String.t()),
          ref_identities: MapSet.t({String.t(), String.t()}),
          ref_versions_by_name: %{optional(String.t()) => String.t()},
          refs_present?: boolean(),
          tool_count: non_neg_integer()
        }

  @spec validate(map()) :: :ok | validation_error()
  def validate(params) when is_map(params) do
    tool_choice = Map.get(params, "tool_choice")

    with {:ok, tool_state} <- validate_tools(Map.get(params, "tools")),
         :ok <- validate_tool_choice_shape(tool_choice) do
      validate_tool_choice_against_tools(tool_choice, tool_state)
    end
  end

  @spec effective_tool_calling?([map()], map() | String.t() | nil) :: boolean()
  def effective_tool_calling?(tools, tool_choice)
      when is_list(tools) and tool_choice in [nil, "auto", "required", "none"] do
    tools != [] and tool_choice != "none"
  end

  def effective_tool_calling?(tools, tool_choice) when is_list(tools) and is_map(tool_choice) do
    tools != []
  end

  def effective_tool_calling?(_tools, _tool_choice), do: false

  defp validate_tools(nil), do: {:ok, empty_tool_state()}

  defp validate_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, empty_tool_state()}, &validate_tool_entry/2)
  end

  defp validate_tools(_tools), do: {:error, :invalid_value, "tools", "must be an array"}

  defp validate_tool_entry(tool, {:ok, state}) do
    case validate_tool(tool) do
      {:ok, {:inline, name}} ->
        validate_unique_inline_name(name, state)

      {:ok, {:ref, {name, version}}} ->
        state
        |> validate_unique_ref_identity(name, version)
        |> validate_single_ref_version(name, version)

      {:error, _type, _field} = error ->
        {:halt, error}

      {:error, _type, _field, _reason} = error ->
        {:halt, error}
    end
  end

  defp validate_unique_inline_name(name, %{inline_names: names} = state) do
    if MapSet.member?(names, name) do
      {:halt, {:error, :invalid_value, "tools", "function names must be unique"}}
    else
      {:cont,
       {:ok, %{state | inline_names: MapSet.put(names, name), tool_count: state.tool_count + 1}}}
    end
  end

  defp validate_unique_ref_identity({:halt, _error} = halted, _name, _version), do: halted

  defp validate_unique_ref_identity(%{ref_identities: identities} = state, name, version) do
    identity = {name, version}

    if MapSet.member?(identities, identity) do
      {:halt, {:error, :invalid_value, "tools", "duplicate tool refs are not allowed"}}
    else
      %{
        state
        | ref_identities: MapSet.put(identities, identity),
          refs_present?: true,
          tool_count: state.tool_count + 1
      }
    end
  end

  defp validate_single_ref_version({:halt, _error} = halted, _name, _version), do: halted

  defp validate_single_ref_version(%{ref_versions_by_name: versions} = state, name, version) do
    case Map.get(versions, name) do
      nil ->
        {:cont, {:ok, %{state | ref_versions_by_name: Map.put(versions, name, version)}}}

      ^version ->
        {:cont, {:ok, state}}

      _other_version ->
        {:halt,
         {:error, :invalid_value, "tools", "tool refs must use a single version per tool name"}}
    end
  end

  defp validate_tool(%{"type" => "function", "function" => %{}, "ref" => _ref}) do
    invalid_mixed_tool_entry()
  end

  defp validate_tool(%{"type" => "function", "function" => %{"name" => name}})
       when is_binary(name) and name != "" do
    {:ok, {:inline, name}}
  end

  defp validate_tool(%{"type" => "function", "ref" => ref}) when is_binary(ref) do
    case parse_tool_ref(ref) do
      {:ok, name, version} -> {:ok, {:ref, {name, version}}}
      :error -> invalid_tool_ref()
    end
  end

  defp validate_tool(%{"type" => "function", "ref" => _ref}) do
    invalid_tool_ref()
  end

  defp validate_tool(%{"type" => type}) when is_binary(type) and type != "function" do
    {:error, :unsupported_parameter, "tools"}
  end

  defp validate_tool(_tool) do
    {:error, :invalid_value, "tools",
     "each tool must be an object with type \"function\" and exactly one of function or ref"}
  end

  defp validate_tool_choice_shape(nil), do: :ok
  defp validate_tool_choice_shape(choice) when choice in ["none", "auto", "required"], do: :ok

  defp validate_tool_choice_shape(%{"type" => "function", "function" => %{"name" => name}})
       when is_binary(name) and name != "" do
    :ok
  end

  defp validate_tool_choice_shape(_choice) do
    {:error, :invalid_value, "tool_choice",
     "must be \"none\", \"auto\", \"required\", or {type: \"function\", function: {name: ...}}"}
  end

  defp validate_tool_choice_against_tools("required", %{tool_count: 0}),
    do: invalid_required_tools()

  defp validate_tool_choice_against_tools("required", _tool_state), do: :ok
  defp validate_tool_choice_against_tools(nil, _tool_state), do: :ok

  defp validate_tool_choice_against_tools(choice, _tool_state) when choice in ["none", "auto"],
    do: :ok

  defp validate_tool_choice_against_tools(
         %{"type" => "function", "function" => %{"name" => name}},
         %{refs_present?: true}
       )
       when is_binary(name) do
    :ok
  end

  defp validate_tool_choice_against_tools(
         %{"type" => "function", "function" => %{"name" => name}},
         %{inline_names: inline_names}
       ) do
    if MapSet.member?(inline_names, name) do
      :ok
    else
      {:error, :invalid_value, "tool_choice",
       "named function tool choice must reference a provided tool"}
    end
  end

  defp validate_tool_choice_against_tools(_choice, _tool_state), do: :ok

  defp empty_tool_state do
    %{
      inline_names: MapSet.new(),
      ref_identities: MapSet.new(),
      ref_versions_by_name: %{},
      refs_present?: false,
      tool_count: 0
    }
  end

  @spec parse_tool_ref(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_tool_ref(ref), do: ToolRef.parse(ref)

  @spec valid_tool_ref_part?(String.t()) :: boolean()
  def valid_tool_ref_part?(value), do: ToolRef.valid_part?(value)

  defp invalid_mixed_tool_entry do
    {:error, :invalid_value, "tools", "each tool must include either function or ref, not both"}
  end

  defp invalid_tool_ref do
    {:error, :invalid_value, "tools", "tool refs must match tool://<name>@<version>"}
  end

  defp invalid_required_tools do
    {:error, :invalid_value, "tool_choice", "\"required\" requires at least one provided tool"}
  end
end
