defmodule Orchard.Inference.ToolCallAccumulatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ToolCallAccumulator
  alias Orchard.InferenceEvent

  test "assembles a single tool call with name and arguments" do
    events = [
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "lookup_weather"}}),
      tool_call_event("call_0", %{
        index: 0,
        function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
      })
    ]

    assert {:ok, accumulator} = ToolCallAccumulator.from_events(events)

    assert ToolCallAccumulator.chat_tool_calls(accumulator) == [
             %{
               id: "call_0",
               type: "function",
               function: %{
                 name: "lookup_weather",
                 arguments: "{\"city\":\"Singapore\"}"
               }
             }
           ]
  end

  test "preserves first-seen tool-call order across multiple calls" do
    events = [
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "lookup_weather"}}),
      tool_call_event("call_1", %{index: 1, type: "function", function: %{name: "lookup_time"}})
    ]

    assert {:ok, accumulator} = ToolCallAccumulator.from_events(events)

    assert Enum.map(ToolCallAccumulator.chat_tool_calls(accumulator), & &1.function.name) == [
             "lookup_weather",
             "lookup_time"
           ]
  end

  test "concatenates incremental argument fragments in arrival order" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.new()
             |> ToolCallAccumulator.apply_event(
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               })
             )
             |> then(fn {:ok, acc} ->
               ToolCallAccumulator.apply_event(
                 acc,
                 tool_call_event("call_0", %{
                   index: 0,
                   function: %{arguments_delta: "{\"city\":\"Sing"}
                 })
               )
             end)
             |> then(fn {:ok, acc} ->
               ToolCallAccumulator.apply_event(
                 acc,
                 tool_call_event("call_0", %{index: 0, function: %{arguments_delta: "apore\"}"}})
               )
             end)

    [tool_call] = ToolCallAccumulator.chat_tool_calls(accumulator)
    assert tool_call.function.arguments == "{\"city\":\"Singapore\"}"
  end

  test "returns an error when later metadata conflicts with earlier metadata" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.apply_event(
               ToolCallAccumulator.new(),
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               })
             )

    assert {:error, {:conflicting_tool_call_name, 0, "lookup_weather", "lookup_time"}} =
             ToolCallAccumulator.apply_event(
               accumulator,
               tool_call_event("call_0", %{index: 0, function: %{name: "lookup_time"}})
             )
  end

  test "returns an error when the same index is reused with a different tool_call_id" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.apply_event(
               ToolCallAccumulator.new(),
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               })
             )

    assert {:error, {:conflicting_tool_call_id, 0, "call_0", "call_1"}} =
             ToolCallAccumulator.apply_event(
               accumulator,
               tool_call_event("call_1", %{index: 0, function: %{arguments_delta: "{}"}})
             )
  end

  test "returns an error when a later delta changes the tool type" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.apply_event(
               ToolCallAccumulator.new(),
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               })
             )

    assert {:error, {:invalid_tool_call_delta, {:invalid_field, :type, "computer_use"}}} =
             ToolCallAccumulator.apply_event(
               accumulator,
               tool_call_event("call_0", %{index: 0, type: "computer_use"})
             )
  end

  test "preview returns a readable summary" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.from_events([
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               }),
               tool_call_event("call_0", %{
                 index: 0,
                 function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
               })
             ])

    assert ToolCallAccumulator.preview(accumulator) ==
             "Tool call: lookup_weather({\"city\":\"Singapore\"})"
  end

  test "responses_output_items/2 emits function_call items with terminal status" do
    assert {:ok, accumulator} =
             ToolCallAccumulator.from_events([
               tool_call_event("call_0", %{
                 index: 0,
                 type: "function",
                 function: %{name: "lookup_weather"}
               }),
               tool_call_event("call_0", %{index: 0, function: %{arguments_delta: "{}"}})
             ])

    assert ToolCallAccumulator.responses_output_items(accumulator, :incomplete) == [
             %{
               type: "function_call",
               id: "call_0",
               call_id: "call_0",
               name: "lookup_weather",
               arguments: "{}",
               status: "incomplete"
             }
           ]
  end

  defp tool_call_event(tool_call_id, delta) do
    InferenceEvent.tool_call_delta(tool_call_id, Jason.encode!(delta))
  end
end
