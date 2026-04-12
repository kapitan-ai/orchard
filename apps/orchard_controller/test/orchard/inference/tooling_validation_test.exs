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

    test "accepts valid inline function tools with unique names" do
      params = %{
        "tools" => [
          inline_tool("lookup_weather"),
          inline_tool("lookup_news")
        ],
        "tool_choice" => "auto"
      }

      assert :ok = ToolingValidation.validate(params)
    end

    test "accepts valid registry ref tools" do
      params = %{
        "tools" => [
          ref_tool("lookup_weather", "2026-04-09"),
          ref_tool("lookup_news", "2026-04-10")
        ],
        "tool_choice" => "auto"
      }

      assert :ok = ToolingValidation.validate(params)
    end

    test "accepts mixed inline and ref tools" do
      params = %{
        "tools" => [
          inline_tool("lookup_weather"),
          ref_tool("lookup_docs", "2026-04-10")
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

    test "rejects mixed function and ref entries" do
      assert {:error, :invalid_value, "tools",
              "each tool must include either function or ref, not both"} =
               ToolingValidation.validate(%{
                 "tools" => [
                   %{
                     "type" => "function",
                     "function" => %{"name" => "lookup_weather"},
                     "ref" => "tool://lookup_weather@2026-04-09"
                   }
                 ]
               })
    end

    test "rejects invalid ref syntax" do
      assert {:error, :invalid_value, "tools", "tool refs must match tool://<name>@<version>"} =
               ToolingValidation.validate(%{
                 "tools" => [%{"type" => "function", "ref" => "tool://lookup_weather"}]
               })
    end

    test "rejects duplicate function names for inline tools" do
      params = %{
        "tools" => [
          inline_tool("lookup_weather"),
          inline_tool("lookup_weather")
        ]
      }

      assert {:error, :invalid_value, "tools", "function names must be unique"} =
               ToolingValidation.validate(params)
    end

    test "rejects duplicate identical refs" do
      params = %{
        "tools" => [
          ref_tool("lookup_weather", "2026-04-09"),
          ref_tool("lookup_weather", "2026-04-09")
        ]
      }

      assert {:error, :invalid_value, "tools", "duplicate tool refs are not allowed"} =
               ToolingValidation.validate(params)
    end

    test "rejects same tool name at multiple ref versions" do
      params = %{
        "tools" => [
          ref_tool("lookup_weather", "2026-04-09"),
          ref_tool("lookup_weather", "2026-04-10")
        ]
      }

      assert {:error, :invalid_value, "tools",
              "tool refs must use a single version per tool name"} =
               ToolingValidation.validate(params)
    end

    test "accepts nil tool_choice" do
      assert :ok = ToolingValidation.validate(%{"tool_choice" => nil})
    end

    test "accepts supported string tool_choice values" do
      for choice <- ["none", "auto", "required"] do
        assert :ok =
                 ToolingValidation.validate(%{
                   "tools" => [inline_tool("lookup_weather")],
                   "tool_choice" => choice
                 })
      end
    end

    test "accepts named function tool_choice when inline tool exists" do
      assert :ok =
               ToolingValidation.validate(%{
                 "tools" => [inline_tool("lookup_weather")],
                 "tool_choice" => named_tool_choice("lookup_weather")
               })
    end

    test "defers named function tool_choice existence checks when refs are present" do
      assert :ok =
               ToolingValidation.validate(%{
                 "tools" => [ref_tool("lookup_weather", "2026-04-09")],
                 "tool_choice" => named_tool_choice("lookup_weather")
               })

      assert :ok =
               ToolingValidation.validate(%{
                 "tools" => [inline_tool("lookup_weather"), ref_tool("lookup_docs", "2026-04-10")],
                 "tool_choice" => named_tool_choice("lookup_docs")
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

    test "rejects named function tool_choice when inline tool is missing and refs are absent" do
      assert {:error, :invalid_value, "tool_choice", _} =
               ToolingValidation.validate(%{
                 "tools" => [inline_tool("lookup_weather")],
                 "tool_choice" => named_tool_choice("lookup_news")
               })
    end
  end

  describe "tool ref helpers" do
    test "parses valid tool refs" do
      assert {:ok, "lookup_docs", "2026-04-11"} =
               ToolingValidation.parse_tool_ref("tool://lookup_docs@2026-04-11")
    end

    test "rejects malformed tool refs and ref parts" do
      assert :error = ToolingValidation.parse_tool_ref("tool://lookup docs@2026-04-11")
      assert :error = ToolingValidation.parse_tool_ref("tool://lookup_docs@2026 04 11")
      assert ToolingValidation.valid_tool_ref_part?("lookup_docs")
      refute ToolingValidation.valid_tool_ref_part?("bad part")
      refute ToolingValidation.valid_tool_ref_part?("bad@part")
    end
  end

  describe "effective_tool_calling?/2" do
    test "returns false without tools" do
      refute ToolingValidation.effective_tool_calling?([], nil)
      refute ToolingValidation.effective_tool_calling?([], "auto")
      refute ToolingValidation.effective_tool_calling?([], "required")
    end

    test "returns false for tool_choice none" do
      tools = [inline_tool("lookup_weather")]
      refute ToolingValidation.effective_tool_calling?(tools, "none")
    end

    test "returns true for non-empty tools with nil or active tool choice" do
      tools = [inline_tool("lookup_weather")]
      assert ToolingValidation.effective_tool_calling?(tools, nil)
      assert ToolingValidation.effective_tool_calling?(tools, "auto")
      assert ToolingValidation.effective_tool_calling?(tools, "required")
      assert ToolingValidation.effective_tool_calling?(tools, named_tool_choice("lookup_weather"))
    end
  end

  defp inline_tool(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  defp ref_tool(name, version) do
    %{"type" => "function", "ref" => "tool://#{name}@#{version}"}
  end

  defp named_tool_choice(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end
end
