defmodule OrchardCLI.Commands.TenantsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.Tenant
  alias Orchard.Repo
  alias OrchardCLI.Commands.Tenants

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "run/1 without subcommand returns group usage" do
    assert {:error, message, 1} = Tenants.run([])
    assert message =~ "orchardctl tenants <command>"
    assert message =~ "create"
  end

  test "run/1 with help returns group usage" do
    assert {:ok, message} = Tenants.run(["help"])
    assert message =~ "orchardctl tenants <command>"
  end

  test "create --help returns usage" do
    assert {:ok, message} = Tenants.run(["create", "--help"])
    assert message =~ "orchardctl tenants create"
    assert message =~ "--slug"
    assert message =~ "--name"
  end

  test "create rejects unknown options" do
    assert {:error, message, 1} = Tenants.run(["create", "--unknown"])
    assert message =~ "unknown option"
  end

  test "create rejects positional arguments" do
    assert {:error, message, 1} = Tenants.run(["create", "extra"])
    assert message =~ "unexpected argument"
  end

  test "create requires --slug and --name" do
    assert {:error, message, 1} = Tenants.run(["create"])
    assert message =~ "missing required option(s): --slug, --name"
  end

  test "create persists tenant through governance" do
    slug = unique_slug("created")

    assert {:ok, message} =
             Tenants.run(["create", "--slug", slug, "--name", "Created Tenant"])

    assert message =~ "Created tenant"
    assert message =~ "Slug: #{slug}"
    assert message =~ "Name: Created Tenant"

    tenant = Repo.get_by!(Tenant, slug: slug)
    assert message =~ "Tenant ID: #{tenant.id}"

    assert Governance.list_tenants()
           |> Enum.any?(fn listed_tenant -> listed_tenant.id == tenant.id end)
  end

  test "create surfaces duplicate slug errors" do
    slug = unique_slug("duplicate")
    {:ok, _tenant} = Governance.create_tenant(%{slug: slug, name: "Existing Tenant"})

    assert {:error, message, 1} =
             Tenants.run(["create", "--slug", slug, "--name", "Duplicate Tenant"])

    assert message =~ "tenant create failed"
    assert message =~ "slug has already been taken"
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
