defmodule Orchard.TestSupport.AgenticExecutionClient do
  @moduledoc """
  Synthetic client for the corpus's scale tool, not a general JSON Schema validator.
  Only this client records tool effects; the runtime fixture has no tool implementation.
  """

  @spec execute([map()], [map()]) :: {list(), list()}
  def execute(calls, tools) do
    Enum.reduce(calls, {[], []}, fn call, {decisions, effects} ->
      tool = Enum.find(tools, &(get_in(&1, ["function", "name"]) == call["function"]["name"]))
      arguments = Jason.decode(call["function"]["arguments"])

      if valid?(arguments, tool) do
        {:ok, %{"n" => n}} = arguments
        {decisions ++ [[call["id"], "execute"]], effects ++ [[call["id"], n * 5]]}
      else
        {decisions ++ [[call["id"], "reject"]], effects}
      end
    end)
  end

  @spec continuation([map()], list(), String.t()) :: map()
  def continuation(calls, effects, "chat" <> _) do
    %{
      "messages" =>
        [%{"role" => "assistant", "content" => nil, "tool_calls" => calls}] ++
          Enum.map(effects, fn [id, result] ->
            %{"role" => "tool", "tool_call_id" => id, "content" => to_string(result)}
          end)
    }
  end

  def continuation(calls, effects, "responses" <> _) do
    %{
      "input" =>
        Enum.map(calls, fn call ->
          %{
            "type" => "function_call",
            "call_id" => call["id"],
            "name" => call["function"]["name"],
            "arguments" => call["function"]["arguments"]
          }
        end) ++
          Enum.map(effects, fn [id, result] ->
            %{"type" => "function_call_output", "call_id" => id, "output" => to_string(result)}
          end)
    }
  end

  defp valid?({:ok, %{"n" => n} = args}, %{
         "function" => %{"name" => "scale", "parameters" => schema}
       }) do
    schema["type"] == "object" and schema["required"] == ["n"] and
      schema["additionalProperties"] == false and map_size(args) == 1 and
      schema["properties"]["n"]["type"] == "integer" and is_integer(n) and
      n >= schema["properties"]["n"]["minimum"]
  end

  defp valid?(_arguments, _tool), do: false
end
