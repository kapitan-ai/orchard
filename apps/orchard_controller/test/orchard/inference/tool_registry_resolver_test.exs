defmodule Orchard.Inference.ToolRegistryResolverTest do
  use Orchard.DataCase, async: true

  alias Orchard.CanonicalRequest.Tooling
  alias Orchard.Inference.ToolRegistryResolver
  alias Orchard.Tools

  describe "resolve/1" do
    test "passes inline tools through unchanged and leaves registry_snapshot empty" do
      requested_tools = [inline_tool("lookup_weather"), inline_tool("lookup_news")]
      tooling = %Tooling{requested_tools: requested_tools, tool_choice: "auto"}

      assert {:ok, resolved} = ToolRegistryResolver.resolve(tooling)
      assert resolved.requested_tools == requested_tools
      assert resolved.tools == requested_tools
      assert resolved.registry_snapshot == %{entries: []}
    end

    test "resolves registry refs in order and records registry metadata" do
      weather = create_tool!("lookup_weather", "2026-04-10")

      docs =
        create_tool!("lookup_docs", "2026-04-11", %{
          execution_mode: :server_hostable,
          source_kind: :mcp_server,
          source_ref: "mcp://docs-server/tools/lookup_docs"
        })

      requested_tools = [
        ref_tool("lookup_docs", "2026-04-11"),
        ref_tool("lookup_weather", "2026-04-10")
      ]

      assert {:ok, resolved} =
               ToolRegistryResolver.resolve(%Tooling{
                 requested_tools: requested_tools,
                 tool_choice: "auto"
               })

      assert resolved.tools == [docs.definition, weather.definition]

      assert resolved.registry_snapshot == %{
               entries: [
                 %{
                   "tool_id" => docs.id,
                   "ref" => "tool://lookup_docs@2026-04-11",
                   "name" => "lookup_docs",
                   "version" => "2026-04-11",
                   "execution_mode" => "server_hostable",
                   "source_kind" => "mcp_server",
                   "source_ref" => "mcp://docs-server/tools/lookup_docs"
                 },
                 %{
                   "tool_id" => weather.id,
                   "ref" => "tool://lookup_weather@2026-04-10",
                   "name" => "lookup_weather",
                   "version" => "2026-04-10",
                   "execution_mode" => "client_only",
                   "source_kind" => "manual",
                   "source_ref" => nil
                 }
               ]
             }
    end

    test "resolves mixed inline and registry tools into a single ordered runtime tools list" do
      docs = create_tool!("lookup_docs", "2026-04-11")
      inline = inline_tool("lookup_weather")
      requested_tools = [inline, ref_tool("lookup_docs", "2026-04-11")]

      assert {:ok, resolved} =
               ToolRegistryResolver.resolve(%Tooling{
                 requested_tools: requested_tools,
                 tool_choice: "auto"
               })

      assert resolved.tools == [inline, docs.definition]
      assert resolved.requested_tools == requested_tools

      assert resolved.registry_snapshot == %{
               entries: [
                 %{
                   "tool_id" => docs.id,
                   "ref" => "tool://lookup_docs@2026-04-11",
                   "name" => "lookup_docs",
                   "version" => "2026-04-11",
                   "execution_mode" => "client_only",
                   "source_kind" => "manual",
                   "source_ref" => nil
                 }
               ]
             }
    end

    test "rejects missing refs as validation errors on tools" do
      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_weather", "2026-04-10")],
        tool_choice: "auto"
      }

      assert {:error, :invalid_value, "tools",
              "tool ref tool://lookup_weather@2026-04-10 was not found or is not active"} =
               ToolRegistryResolver.resolve(tooling)
    end

    test "rejects deprecated refs as validation errors on tools" do
      create_tool!("lookup_weather", "2026-04-10", %{state: :deprecated})

      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_weather", "2026-04-10")],
        tool_choice: "auto"
      }

      assert {:error, :invalid_value, "tools",
              "tool ref tool://lookup_weather@2026-04-10 was not found or is not active"} =
               ToolRegistryResolver.resolve(tooling)
    end

    test "rejects duplicate effective function names after resolution" do
      create_tool!("lookup_weather", "2026-04-10")

      tooling = %Tooling{
        requested_tools: [inline_tool("lookup_weather"), ref_tool("lookup_weather", "2026-04-10")],
        tool_choice: "auto"
      }

      assert {:error, :invalid_value, "tools", "function names must be unique"} =
               ToolRegistryResolver.resolve(tooling)
    end

    test "enforces named tool_choice against resolved registry tools" do
      create_tool!("lookup_weather", "2026-04-10")

      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_weather", "2026-04-10")],
        tool_choice: named_tool_choice("lookup_docs")
      }

      assert {:error, :invalid_value, "tool_choice",
              "named function tool choice must reference a provided tool"} =
               ToolRegistryResolver.resolve(tooling)
    end

    test "accepts named tool_choice when it matches a resolved registry tool" do
      create_tool!("lookup_weather", "2026-04-10")

      tooling = %Tooling{
        requested_tools: [ref_tool("lookup_weather", "2026-04-10")],
        tool_choice: named_tool_choice("lookup_weather")
      }

      assert {:ok, resolved} = ToolRegistryResolver.resolve(tooling)
      assert resolved.tools == [function_definition("lookup_weather")]
    end

    test "rejects multiple versions for the same registry name before fetching" do
      tooling = %Tooling{
        requested_tools: [
          ref_tool("lookup_weather", "2026-04-09"),
          ref_tool("lookup_weather", "2026-04-10")
        ],
        tool_choice: "auto"
      }

      assert {:error, :invalid_value, "tools",
              "tool refs must use a single version per tool name"} =
               ToolRegistryResolver.resolve(tooling)
    end
  end

  defp create_tool!(name, version, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name,
          version: version,
          state: :active,
          definition: function_definition(name),
          execution_mode: :client_only,
          source_kind: :manual,
          source_ref: nil
        },
        overrides
      )

    case Tools.create_tool(attrs) do
      {:ok, tool} -> tool
      {:error, changeset} -> raise "create_tool! failed: #{inspect(changeset.errors)}"
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

  defp inline_tool(name), do: function_definition(name)

  defp ref_tool(name, version) do
    %{"type" => "function", "ref" => "tool://#{name}@#{version}"}
  end

  defp named_tool_choice(name) do
    %{"type" => "function", "function" => %{"name" => name}}
  end
end
