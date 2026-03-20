defmodule OrchardCLI.Commands.ApiKeysTest.CollisionSecret do
  alias Orchard.Governance.ApiKeySecret

  @token "orch_collision.fixedsecret"

  def generate do
    %{
      token: @token,
      token_prefix: "orch_collision",
      secret_hash: ApiKeySecret.hash(@token)
    }
  end

  def token, do: @token
end

defmodule OrchardCLI.Commands.ApiKeysTest.InvalidSecret do
  def generate, do: %{token: "invalid-token"}
end

defmodule OrchardCLI.Commands.ApiKeysTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret}
  alias Orchard.Repo
  alias OrchardCLI.Commands.ApiKeys
  alias OrchardCLI.Commands.ApiKeysTest.{CollisionSecret, InvalidSecret}

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "run/1 without subcommand returns group usage" do
    assert {:error, message, 1} = ApiKeys.run([])
    assert message =~ "orchardctl api-keys <command>"
    assert message =~ "create"
    assert message =~ "revoke"
  end

  test "run/1 with help returns group usage" do
    assert {:ok, message} = ApiKeys.run(["help"])
    assert message =~ "orchardctl api-keys <command>"
  end

  test "create --help returns usage" do
    assert {:ok, message} = ApiKeys.run(["create", "--help"])
    assert message =~ "orchardctl api-keys create"
    assert message =~ "--tenant-id"
    assert message =~ "--name"
  end

  test "revoke --help returns usage" do
    assert {:ok, message} = ApiKeys.run(["revoke", "--help"])
    assert message =~ "orchardctl api-keys revoke"
    assert message =~ "--api-key-id"
  end

  test "create rejects unknown options" do
    assert {:error, message, 1} = ApiKeys.run(["create", "--unknown"])
    assert message =~ "unknown option"
  end

  test "revoke rejects positional arguments" do
    assert {:error, message, 1} = ApiKeys.run(["revoke", "extra"])
    assert message =~ "unexpected argument"
  end

  test "create requires --tenant-id and --name" do
    assert {:error, message, 1} = ApiKeys.run(["create"])
    assert message =~ "missing required option(s): --tenant-id, --name"
  end

  test "revoke requires --api-key-id" do
    assert {:error, message, 1} = ApiKeys.run(["revoke"])
    assert message =~ "missing required option(s): --api-key-id"
  end

  test "create rejects malformed tenant ids before calling governance" do
    assert {:error, message, 1} =
             ApiKeys.run(["create", "--tenant-id", "not-a-uuid", "--name", "Primary"])

    assert message =~ "--tenant-id must be a valid UUID"
  end

  test "revoke rejects malformed api key ids before calling governance" do
    assert {:error, message, 1} =
             ApiKeys.run(["revoke", "--api-key-id", "not-a-uuid"])

    assert message =~ "--api-key-id must be a valid UUID"
  end

  test "create returns not found for unknown tenant ids" do
    tenant_id = Ecto.UUID.generate()

    assert {:error, message, 1} =
             ApiKeys.run(["create", "--tenant-id", tenant_id, "--name", "Primary"])

    assert message =~ "tenant not found: #{tenant_id}"
  end

  test "revoke returns not found for unknown api key ids" do
    api_key_id = Ecto.UUID.generate()

    assert {:error, message, 1} = ApiKeys.run(["revoke", "--api-key-id", api_key_id])
    assert message =~ "API key not found: #{api_key_id}"
  end

  test "create prints the token exactly once and persists the API key" do
    tenant = create_tenant!("tenant-create")

    assert {:ok, message} =
             ApiKeys.run([
               "create",
               "--tenant-id",
               tenant.id,
               "--name",
               "Primary Key"
             ])

    assert message =~ "Created API key"
    assert message =~ "Tenant ID: #{tenant.id}"
    assert message =~ "Name: Primary Key"

    api_key = Repo.get_by!(ApiKey, tenant_id: tenant.id, name: "Primary Key")
    assert message =~ "API key ID: #{api_key.id}"

    token = token_from_message(message)
    assert token_occurrences(message, token) == 1
    assert {:ok, api_key.token_prefix} == ApiKeySecret.token_prefix(token)
    assert ApiKeySecret.verify(token, api_key.secret_hash)
  end

  test "create error paths do not leak generated tokens" do
    tenant = create_tenant!("tenant-collision")
    create_api_key_record!(tenant, %{token_prefix: "orch_collision"})
    token = CollisionSecret.token()

    with_env(
      :governance_api_key_secret_impl,
      CollisionSecret,
      fn ->
        assert {:error, message, 1} =
                 ApiKeys.run([
                   "create",
                   "--tenant-id",
                   tenant.id,
                   "--name",
                   "Collision"
                 ])

        assert message =~ "API key create failed"
        assert message =~ "token_prefix has already been taken"
        refute message =~ token
      end
    )
  end

  test "create surfaces invalid generated secret failures without echoing a token" do
    tenant = create_tenant!("tenant-invalid-secret")

    with_env(:governance_api_key_secret_impl, InvalidSecret, fn ->
      assert {:error, message, 1} =
               ApiKeys.run([
                 "create",
                 "--tenant-id",
                 tenant.id,
                 "--name",
                 "Primary"
               ])

      assert message =~ "unable to generate a valid token"
      refute message =~ "Token:"
      refute message =~ "invalid-token"
    end)
  end

  test "revoke succeeds and preserves idempotent governance behavior" do
    tenant = create_tenant!("tenant-revoke")
    api_key = create_api_key_record!(tenant, %{name: "Primary Key"})

    assert {:ok, first_message} = ApiKeys.run(["revoke", "--api-key-id", api_key.id])
    assert first_message =~ "API key is revoked"
    assert first_message =~ "API key ID: #{api_key.id}"

    revoked = Repo.get!(ApiKey, api_key.id)
    assert %DateTime{} = revoked.revoked_at
    assert first_message =~ DateTime.to_iso8601(revoked.revoked_at)

    assert {:ok, second_message} = ApiKeys.run(["revoke", "--api-key-id", api_key.id])
    assert second_message =~ DateTime.to_iso8601(revoked.revoked_at)
  end

  defp create_tenant!(slug_prefix) do
    slug = unique_slug(slug_prefix)
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    tenant
  end

  defp create_api_key_record!(tenant, overrides) do
    attrs = %{
      tenant_id: tenant.id,
      name: "Key for #{tenant.slug}",
      token_prefix: "orch_#{System.unique_integer([:positive])}",
      secret_hash: "sha256$#{System.unique_integer([:positive])}"
    }

    {:ok, api_key} =
      %ApiKey{}
      |> ApiKey.changeset(Map.merge(attrs, overrides))
      |> Repo.insert()

    api_key
  end

  defp token_from_message(message) do
    message
    |> String.split("\n")
    |> Enum.find_value(fn
      "  Token: " <> token -> token
      _line -> nil
    end)
  end

  defp token_occurrences(message, token) do
    message
    |> String.split(token)
    |> length()
    |> Kernel.-(1)
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp with_env(key, value, fun) do
    previous = Application.get_env(:orchard_controller, key, :__missing__)
    Application.put_env(:orchard_controller, key, value)

    try do
      fun.()
    after
      case previous do
        :__missing__ -> Application.delete_env(:orchard_controller, key)
        previous -> Application.put_env(:orchard_controller, key, previous)
      end
    end
  end
end
