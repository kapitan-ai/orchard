defmodule Orchard.Inference.ToolExecutionSemanticsTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest.Tooling
  alias Orchard.Inference.ToolExecutionSemantics

  describe "build/1" do
    test "builds inline client passthrough semantics for inline-only tooling" do
      inline_weather = function_definition("lookup_weather")
      inline_news = function_definition("lookup_news")

      tooling = %Tooling{
        requested_tools: [inline_weather, inline_news],
        tools: [inline_weather, inline_news],
        tool_choice: "auto",
        registry_snapshot: %{entries: []}
      }

      assert {:ok, %{entries: entries}} = ToolExecutionSemantics.build(tooling)

      assert entries == [
               %{
                 "name" => "lookup_weather",
                 "provenance" => "inline",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "client_only"
               },
               %{
                 "name" => "lookup_news",
                 "provenance" => "inline",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "client_only"
               }
             ]
    end

    test "copies registry execution_mode metadata for ref-backed tooling" do
      tooling = %Tooling{
        requested_tools: [
          ref_tool("lookup_docs", "2026-04-11"),
          ref_tool("lookup_weather", "2026-04-10")
        ],
        tools: [function_definition("lookup_docs"), function_definition("lookup_weather")],
        tool_choice: "auto",
        registry_snapshot: %{
          entries: [
            %{
              "ref" => "tool://lookup_docs@2026-04-11",
              "name" => "lookup_docs",
              "version" => "2026-04-11",
              "execution_mode" => "server_hostable"
            },
            %{
              "ref" => "tool://lookup_weather@2026-04-10",
              "name" => "lookup_weather",
              "version" => "2026-04-10",
              "execution_mode" => "client_only"
            }
          ]
        }
      }

      assert {:ok, %{entries: entries}} = ToolExecutionSemantics.build(tooling)

      assert entries == [
               %{
                 "name" => "lookup_docs",
                 "provenance" => "registry",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "server_hostable"
               },
               %{
                 "name" => "lookup_weather",
                 "provenance" => "registry",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "client_only"
               }
             ]
    end

    test "preserves effective tool order for mixed inline and registry-backed tooling" do
      inline_weather = function_definition("lookup_weather")

      tooling = %Tooling{
        requested_tools: [
          inline_weather,
          ref_tool("lookup_docs", "2026-04-11"),
          function_definition("summarize")
        ],
        tools: [
          inline_weather,
          function_definition("lookup_docs"),
          function_definition("summarize")
        ],
        tool_choice: "auto",
        registry_snapshot: %{
          entries: [
            %{
              "ref" => "tool://lookup_docs@2026-04-11",
              "name" => "lookup_docs",
              "version" => "2026-04-11",
              "execution_mode" => "server_hostable"
            }
          ]
        }
      }

      assert {:ok, %{entries: entries}} = ToolExecutionSemantics.build(tooling)

      assert entries == [
               %{
                 "name" => "lookup_weather",
                 "provenance" => "inline",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "client_only"
               },
               %{
                 "name" => "lookup_docs",
                 "provenance" => "registry",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "server_hostable"
               },
               %{
                 "name" => "summarize",
                 "provenance" => "inline",
                 "disposition" => "client_passthrough",
                 "execution_mode" => "client_only"
               }
             ]
    end

    test "returns an empty execution snapshot when inline tooling is disabled via tool_choice none" do
      inline_weather = function_definition("lookup_weather")

      tooling = %Tooling{
        requested_tools: [inline_weather],
        tools: [inline_weather],
        tool_choice: "none",
        registry_snapshot: %{entries: []}
      }

      assert {:ok, %{entries: []}} = ToolExecutionSemantics.build(tooling)
    end

    test "returns an empty execution snapshot when ref-backed tooling is disabled via tool_choice none" do
      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_docs", "2026-04-11")],
        tools: [function_definition("lookup_docs")],
        tool_choice: "none",
        registry_snapshot: %{
          entries: [
            %{
              "ref" => "tool://lookup_docs@2026-04-11",
              "name" => "lookup_docs",
              "version" => "2026-04-11",
              "execution_mode" => "server_hostable"
            }
          ]
        }
      }

      assert {:ok, %{entries: []}} = ToolExecutionSemantics.build(tooling)
    end

    test "returns an empty execution snapshot for legacy runtime-only tooling" do
      tooling = %Tooling{
        requested_tools: [],
        tools: [function_definition("lookup_docs")],
        tool_choice: "auto",
        registry_snapshot: %{entries: []}
      }

      assert {:ok, %{entries: []}} = ToolExecutionSemantics.build(tooling)
    end

    test "fails closed when a ref-backed tool is missing registry metadata" do
      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_docs", "2026-04-11")],
        tools: [function_definition("lookup_docs")],
        tool_choice: "auto",
        registry_snapshot: %{entries: []}
      }

      assert {:error, {:misaligned_tooling, :missing_registry_entry}} =
               ToolExecutionSemantics.build(tooling)
    end
  end

  defp function_definition(name) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => "Lookup details.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"query" => %{"type" => "string"}}
        }
      }
    }
  end

  defp ref_tool(name, version) do
    %{"type" => "function", "ref" => "tool://#{name}@#{version}"}
  end
end
