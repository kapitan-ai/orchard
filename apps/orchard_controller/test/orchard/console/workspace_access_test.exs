defmodule OrchardConsole.WorkspaceAccessTest do
  use ExUnit.Case, async: true

  alias OrchardConsole.WorkspaceAccess
  alias OrchardConsole.WorkspacePresentation

  test "default presentation preserves custom names and UUID identity" do
    tenant = %{id: "00000000-0000-0000-0000-000000000000", name: "Legacy Single Tenant"}
    assert WorkspacePresentation.default?(tenant)
    assert WorkspacePresentation.display_name(tenant) == "Default workspace"
    assert WorkspacePresentation.display_name(%{tenant | name: "Research"}) == "Research"
    refute WorkspacePresentation.default?(%{id: "other", name: "Legacy Single Tenant"})
  end

  test "exact catalog identities retain independent enabled disabled and missing grant states" do
    models =
      for {id, version} <- [{"a", "1"}, {"b", "2"}, {"c", "3"}],
          do: %{id: id, model_id: "model", version: version}

    tenant = %{id: "scope"}

    reader = fn ^tenant ->
      {:ok, [%{model_id: "a", enabled: true}, %{model_id: "b", enabled: false}]}
    end

    assert {:ok, rows} =
             WorkspaceAccess.list(tenant, access_reader: reader, model_reader: fn -> models end)

    assert Enum.map(rows, & &1.grant_state) == [:enabled, :disabled, :not_granted]
    assert Enum.map(rows, & &1.model.version) == ["1", "2", "3"]
  end

  test "failed grant reads never appear as no grants" do
    assert {:error, :unavailable} =
             WorkspaceAccess.list(%{id: "scope"},
               access_reader: fn _ -> {:error, :unavailable} end,
               model_reader: fn -> flunk("must not read models after failed grants") end
             )
  end

  test "re-enabling a scoped grant preserves its routing policy" do
    commands =
      WorkspaceAccess.commands(%{id: "scope"}, %{model_id: "model", version: "1"}, %{
        routing_policy_id: "policy'1"
      })

    assert commands.grant =~ " --routing-policy-id 'policy'\\''1'"
    refute commands.inspect =~ "--routing-policy-id"
  end

  test "operator commands quote exact revision and workspace scope as shell arguments" do
    commands =
      WorkspaceAccess.commands(%{id: "scope'1"}, %{
        model_id: "org/model; touch x",
        version: "rev'2"
      })

    assert commands.grant ==
             "orchardctl models access grant 'org/model; touch x@rev'\\''2' --tenant 'scope'\\''1'"

    assert commands.inspect ==
             "orchardctl models access inspect 'org/model; touch x@rev'\\''2' --tenant 'scope'\\''1'"
  end
end
