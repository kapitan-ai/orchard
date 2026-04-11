defmodule Orchard.ToolsTest do
  use Orchard.DataCase, async: false

  alias Orchard.Tools

  test "create_tool/1 persists a tool identity with Phase 1 safe defaults" do
    attrs = tool_attrs()

    assert {:ok, tool} = Tools.create_tool(attrs)
    assert tool.name == attrs.name
    assert tool.version == attrs.version
    assert tool.state == :active
    assert tool.execution_mode == :client_only
    assert tool.source_kind == :manual
    assert tool.source_ref == nil

    assert {:error, changeset} = Tools.create_tool(attrs)
    assert %{name: ["has already been taken"]} = errors_on(changeset)
  end

  test "create_tool/1 accepts explicit server_hostable metadata" do
    assert {:ok, tool} =
             Tools.create_tool(
               tool_attrs(%{
                 name: "lookup_docs",
                 version: "2026-04-10",
                 execution_mode: :server_hostable,
                 source_kind: :mcp_server,
                 source_ref: "mcp://docs-server/tools/lookup_docs"
               })
             )

    assert tool.execution_mode == :server_hostable
    assert tool.source_kind == :mcp_server
    assert tool.source_ref == "mcp://docs-server/tools/lookup_docs"
  end

  test "create_tool/1 rejects non-function definitions before hitting the database" do
    assert {:error, changeset} =
             Tools.create_tool(
               tool_attrs(%{
                 definition: %{
                   "type" => "web_search",
                   "function" => %{"name" => "lookup_weather"}
                 }
               })
             )

    assert %{definition: ["must be a function tool definition"]} = errors_on(changeset)
  end

  test "create_tool/1 rejects definitions whose function name drifts from tool name" do
    assert {:error, changeset} =
             Tools.create_tool(
               tool_attrs(%{
                 definition: %{
                   "type" => "function",
                   "function" => %{
                     "name" => "lookup_forecast",
                     "parameters" => %{"type" => "object"}
                   }
                 }
               })
             )

    assert %{definition: ["function.name must match tool name"]} = errors_on(changeset)
  end

  test "create_tool/1 rejects ref-unsafe name values" do
    Enum.each(
      ["lookup@weather", "lookup weather", "lookup\tweather", "lookup\nweather"],
      fn name ->
        assert {:error, changeset} = Tools.create_tool(tool_attrs(%{name: name}))
        assert %{name: [message | _rest]} = errors_on(changeset)
        assert message =~ "tool://<name>@<version>"
      end
    )
  end

  test "create_tool/1 rejects ref-unsafe version values" do
    Enum.each(["v@1", "v 1", "v\t1", "v\n1"], fn version ->
      assert {:error, changeset} = Tools.create_tool(tool_attrs(%{version: version}))
      assert %{version: [message | _rest]} = errors_on(changeset)
      assert message =~ "tool://<name>@<version>"
    end)
  end

  test "list_active_tools/0 and fetch_active_tools_by_identity/1 return active rows only" do
    assert {:ok, active} =
             Tools.create_tool(tool_attrs(%{name: "lookup_weather", version: "2026-04-10"}))

    assert {:ok, deprecated} =
             Tools.create_tool(
               tool_attrs(%{
                 name: "lookup_weather_legacy",
                 version: "2026-04-09",
                 state: :deprecated
               })
             )

    assert {:ok, other_active} =
             Tools.create_tool(tool_attrs(%{name: "lookup_docs", version: "2026-04-10"}))

    assert Enum.map(Tools.list_active_tools(), & &1.id) == [active.id, other_active.id]

    assert %{
             {"lookup_weather", "2026-04-10"} => fetched_active,
             {"lookup_docs", "2026-04-10"} => fetched_other
           } =
             Tools.fetch_active_tools_by_identity([
               {"lookup_weather", "2026-04-10"},
               {"lookup_weather_legacy", "2026-04-09"},
               {"lookup_docs", "2026-04-10"}
             ])

    assert fetched_active.id == active.id
    assert fetched_other.id == other_active.id

    refute Map.has_key?(
             Tools.fetch_active_tools_by_identity([{"lookup_weather_legacy", "2026-04-09"}]),
             {deprecated.name, deprecated.version}
           )

    assert Tools.fetch_active_tools_by_identity([]) == %{}
  end

  test "get_tool_by_identity/2 returns the matching tool or nil" do
    assert {:ok, tool} = Tools.create_tool(tool_attrs(%{name: "lookup_docs", version: "v2"}))

    assert Tools.get_tool_by_identity("lookup_docs", "v2").id == tool.id
    assert Tools.get_tool_by_identity("missing", "v1") == nil
  end

  test "deprecate_tool/1 and activate_tool/1 support the Phase 1 state loop" do
    assert {:ok, tool} = Tools.create_tool(tool_attrs(%{name: "lookup_weather", version: "v3"}))

    assert {:ok, deprecated} = Tools.deprecate_tool(tool.id)
    assert deprecated.state == :deprecated

    assert {:ok, reactivated} = Tools.activate_tool(deprecated)
    assert reactivated.state == :active
  end

  test "state transitions reject invalid repeats and malformed ids" do
    assert {:ok, tool} = Tools.create_tool(tool_attrs(%{name: "lookup_weather", version: "v4"}))

    assert {:error, changeset} = Tools.activate_tool(tool.id)
    assert %{state: [message]} = errors_on(changeset)
    assert message =~ "cannot transition from active to active"

    assert {:ok, deprecated} = Tools.deprecate_tool(tool.id)
    assert {:error, changeset} = Tools.deprecate_tool(deprecated.id)
    assert %{state: [message]} = errors_on(changeset)
    assert message =~ "cannot transition from deprecated to deprecated"

    assert {:error, :not_found} = Tools.activate_tool("not-a-uuid")
  end

  defp tool_attrs(overrides \\ %{}) do
    name = Map.get(overrides, :name, "lookup_weather")
    version = Map.get(overrides, :version, "2026-04-09")

    defaults = %{
      name: name,
      version: version,
      state: :active,
      definition: function_definition(name),
      execution_mode: :client_only,
      source_kind: :manual,
      source_ref: nil
    }

    Map.merge(defaults, overrides)
  end

  defp function_definition(name) do
    %{
      "type" => "function",
      "function" => %{
        "name" => name,
        "description" => "Lookup weather details.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      }
    }
  end
end
