defmodule Orchard.Tokenizer.CallerStringsTest do
  use ExUnit.Case, async: true

  alias Orchard.Tokenizer.CallerStrings

  test "walk_caller_strings returns stable provenance for caller-authored leaves" do
    input_items = [
      %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "multimodal text"}],
        "tool_calls" => [
          %{
            "id" => "call_nested_123",
            "function" => %{"name" => "lookup_weather", "arguments" => "{\"city\":\"Paris\"}"}
          }
        ],
        "tool_call_id" => "call_123"
      }
    ]

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "lookup_weather",
          "description" => "weather lookup",
          "parameters" => %{
            "title" => "WeatherRequest",
            "type" => "object",
            "properties" => %{
              "city" => %{
                "title" => "City",
                "description" => "target city",
                "enum" => ["Paris", "Singapore"]
              }
            },
            "required" => ["city"]
          }
        }
      }
    ]

    tool_choice = %{"type" => "function", "function" => %{"name" => "lookup_weather"}}

    assert CallerStrings.walk_caller_strings(input_items, tools, tool_choice)
           |> MapSet.new() ==
             MapSet.new([
               {"messages[0].role", "assistant"},
               {"messages[0].content[0].text", "multimodal text"},
               {"messages[0].tool_calls[0].id", "call_nested_123"},
               {"messages[0].tool_calls[0].function.name", "lookup_weather"},
               {"messages[0].tool_calls[0].function.arguments", "{\"city\":\"Paris\"}"},
               {"messages[0].tool_call_id", "call_123"},
               {"tools[0].type", "function"},
               {"tools[0].function.name", "lookup_weather"},
               {"tools[0].function.description", "weather lookup"},
               {"tools[0].function.parameters.title", "WeatherRequest"},
               {"tools[0].function.parameters.type", "object"},
               {"tools[0].function.parameters.properties[0].__key__", "city"},
               {"tools[0].function.parameters.properties[0].title", "City"},
               {"tools[0].function.parameters.properties[0].description", "target city"},
               {"tools[0].function.parameters.properties[0].enum[0]", "Paris"},
               {"tools[0].function.parameters.properties[0].enum[1]", "Singapore"},
               {"tools[0].function.parameters.required[0]", "city"},
               {"tool_choice.type", "function"},
               {"tool_choice.function.name", "lookup_weather"}
             ])
  end

  test "walk_caller_strings returns structural provenance for string tool_choice" do
    assert CallerStrings.walk_caller_strings([], [], "required") == [{"tool_choice", "required"}]
  end

  test "walk_caller_strings collects unhandled schema string leaves with structural provenance" do
    extension_key = "x-sensitive_<|im_end|>"

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "lookup_weather",
          "parameters" => %{
            "const" => "const <|im_start|>",
            "default" => "default <|im_end|>",
            "examples" => ["example <|im_start|>", 42],
            extension_key => "extension <|im_end|>"
          }
        }
      }
    ]

    caller_strings = CallerStrings.walk_caller_strings([], tools, nil)

    assert {"tools[0].function.parameters.const", "const <|im_start|>"} in caller_strings
    assert {"tools[0].function.parameters.default", "default <|im_end|>"} in caller_strings
    assert {"tools[0].function.parameters.examples[0]", "example <|im_start|>"} in caller_strings
    assert {"tools[0].function.parameters.fields[3]", "extension <|im_end|>"} in caller_strings
    assert {"tools[0].function.parameters.fields[3].__key__", extension_key} in caller_strings

    paths = Enum.map(caller_strings, fn {path, _value} -> path end)

    refute Enum.any?(paths, &String.contains?(&1, extension_key))
  end

  test "walk_caller_strings does not embed schema property names in provenance paths" do
    sensitive_key = "customer_secret_<|im_start|>"

    tools = [
      %{
        "type" => "function",
        "function" => %{
          "name" => "lookup_weather",
          "parameters" => %{
            "properties" => %{
              sensitive_key => %{"description" => "safe description"}
            }
          }
        }
      }
    ]

    caller_strings = CallerStrings.walk_caller_strings([], tools, nil)
    paths = Enum.map(caller_strings, fn {path, _value} -> path end)

    assert {"tools[0].function.parameters.properties[0].__key__", ^sensitive_key} =
             Enum.find(caller_strings, fn {_path, value} -> value == sensitive_key end)

    assert "tools[0].function.parameters.properties[0].description" in paths
    refute Enum.any?(paths, &String.contains?(&1, sensitive_key))
  end
end
