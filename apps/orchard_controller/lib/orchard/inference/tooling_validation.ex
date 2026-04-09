defmodule Orchard.Inference.ToolingValidation do
  @moduledoc """
  Shared validation for tool-calling request fields across chat and responses endpoints.
  """

  @type validation_error ::
          {:error, :unsupported_parameter, String.t()}
          | {:error, :invalid_value, String.t(), String.t()}

  @spec validate(map()) :: :ok | validation_error()
  def validate(params) when is_map(params) do
    tool_choice = Map.get(params, "tool_choice")

    with {:ok, tool_names} <- validate_tools(Map.get(params, "tools")),
         :ok <- validate_tool_choice_shape(tool_choice) do
      validate_tool_choice_against_tools(tool_choice, tool_names)
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

  defp validate_tools(nil), do: {:ok, []}

  defp validate_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, MapSet.new()}, &validate_tool_entry/2)
    |> case do
      {:ok, names} -> {:ok, MapSet.to_list(names)}
      error -> error
    end
  end

  defp validate_tools(_tools), do: {:error, :invalid_value, "tools", "must be an array"}

  defp validate_tool_entry(tool, {:ok, names}) do
    case validate_tool(tool) do
      {:ok, name} -> validate_unique_tool_name(name, names)
      {:error, _type, _field} = error -> {:halt, error}
      {:error, _type, _field, _reason} = error -> {:halt, error}
    end
  end

  defp validate_unique_tool_name(name, names) do
    if MapSet.member?(names, name) do
      {:halt, {:error, :invalid_value, "tools", "function names must be unique"}}
    else
      {:cont, {:ok, MapSet.put(names, name)}}
    end
  end

  defp validate_tool(%{"type" => "function", "function" => %{"name" => name}})
       when is_binary(name) and name != "" do
    {:ok, name}
  end

  defp validate_tool(%{"type" => type}) when is_binary(type) and type != "function" do
    {:error, :unsupported_parameter, "tools"}
  end

  defp validate_tool(_tool) do
    {:error, :invalid_value, "tools",
     "each tool must be an object with type \"function\" and a non-empty function name"}
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

  defp validate_tool_choice_against_tools("required", []), do: invalid_required_tools()
  defp validate_tool_choice_against_tools("required", _tool_names), do: :ok
  defp validate_tool_choice_against_tools(nil, _tool_names), do: :ok

  defp validate_tool_choice_against_tools(choice, _tool_names) when choice in ["none", "auto"],
    do: :ok

  defp validate_tool_choice_against_tools(
         %{"type" => "function", "function" => %{"name" => name}},
         tool_names
       ) do
    if name in tool_names do
      :ok
    else
      {:error, :invalid_value, "tool_choice",
       "named function tool choice must reference a provided tool"}
    end
  end

  defp validate_tool_choice_against_tools(_choice, _tool_names), do: :ok

  defp invalid_required_tools do
    {:error, :invalid_value, "tool_choice", "\"required\" requires at least one provided tool"}
  end
end
