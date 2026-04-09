defmodule Orchard.Inference.ToolingValidationTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.ToolingValidation

  describe "validate/1" do
    test "accepts omitted tooling" do
      assert :ok = ToolingValidation.validate(%{})
    end

    test "accepts empty tools list" do
      assert :ok = ToolingValidation.validate(%{"tools" => []})
    end

    test "accepts valid function tools with unique names" do
      params = %{
        "tools" => [
          %{"type" => "function", "function" => %{"name" => "lookup_weather"}},
          %{"type" => "function", "function" => %{"name" => "lookup_news"}}
        ],
        "tool_choice" => "auto"
      }

      assert :ok = ToolingValidation.validate(params)
    end

    test "rejects non-list tools" do
      assert {:error, :invalid_value, "tools", _} =
               ToolingValidation.validate(%{"tools" => %{"type" => "function"}})
    end

    test "rejects non-function tool types as unsupported" do
      assert {:error, :unsupported_parameter, "tools"} =
               ToolingValidation.validate(%{
                 "tools" => [
                   %{"type" => "web_search", "function" => %{"name" => "lookup_weather"}}
                 ]
               })
    end

    test "rejects malformed tool entries" do
      assert {:error, :invalid_value, "tools", _} =
               ToolingValidation.validate(%{
                 "tools" => [%{"type" => "function", "function" => %{}}]
               })
    end

    test "rejects duplicate function names" do
      params = %{
        "tools" => [
          %{"type" => "function", "function" => %{"name" => "lookup_weather"}},
          %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
        ]
      }

      assert {:error, :invalid_value, "tools", "function names must be unique"} =
               ToolingValidation.validate(params)
    end

    test "accepts nil tool_choice" do
      assert :ok = ToolingValidation.validate(%{"tool_choice" => nil})
    end

    test "accepts supported string tool_choice values" do
      for choice <- ["none", "auto", "required"] do
        assert :ok =
                 ToolingValidation.validate(%{
                   "tools" => [
                     %{"type" => "function", "function" => %{"name" => "lookup_weather"}}
                   ],
                   "tool_choice" => choice
                 })
      end
    end

    test "accepts named function tool_choice when tool exists" do
      assert :ok =
               ToolingValidation.validate(%{
                 "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
                 "tool_choice" => %{
                   "type" => "function",
                   "function" => %{"name" => "lookup_weather"}
                 }
               })
    end

    test "rejects invalid tool_choice shape" do
      assert {:error, :invalid_value, "tool_choice", _} =
               ToolingValidation.validate(%{"tool_choice" => %{"type" => "function"}})
    end

    test "rejects required tool_choice without tools" do
      assert {:error, :invalid_value, "tool_choice", _} =
               ToolingValidation.validate(%{"tool_choice" => "required"})

      assert {:error, :invalid_value, "tool_choice", _} =
               ToolingValidation.validate(%{"tools" => [], "tool_choice" => "required"})
    end

    test "rejects named function tool_choice when tool is missing" do
      assert {:error, :invalid_value, "tool_choice", _} =
               ToolingValidation.validate(%{
                 "tools" => [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}],
                 "tool_choice" => %{
                   "type" => "function",
                   "function" => %{"name" => "lookup_news"}
                 }
               })
    end
  end

  describe "effective_tool_calling?/2" do
    test "returns false without tools" do
      refute ToolingValidation.effective_tool_calling?([], nil)
      refute ToolingValidation.effective_tool_calling?([], "auto")
      refute ToolingValidation.effective_tool_calling?([], "required")
    end

    test "returns false for tool_choice none" do
      tools = [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}]
      refute ToolingValidation.effective_tool_calling?(tools, "none")
    end

    test "returns true for non-empty tools with nil or active tool choice" do
      tools = [%{"type" => "function", "function" => %{"name" => "lookup_weather"}}]
      assert ToolingValidation.effective_tool_calling?(tools, nil)
      assert ToolingValidation.effective_tool_calling?(tools, "auto")
      assert ToolingValidation.effective_tool_calling?(tools, "required")

      assert ToolingValidation.effective_tool_calling?(tools, %{
               "type" => "function",
               "function" => %{"name" => "lookup_weather"}
             })
    end
  end
end
