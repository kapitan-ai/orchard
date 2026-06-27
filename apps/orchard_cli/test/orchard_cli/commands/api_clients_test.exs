defmodule OrchardCLI.Commands.ApiClientsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, AuditLog, ProvisioningBatch, ServiceAccount}
  alias Orchard.Repo
  alias OrchardCLI.Commands.ApiClients

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-api-clients-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: unique_slug("cli-org"),
        name: "CLI Organization"
      })

    %{tenant: tenant, tmp_dir: tmp_dir}
  end

  test "run/1 without subcommand returns group usage" do
    assert {:error, message, 1} = ApiClients.run([])
    assert message =~ "orchardctl api-clients <command>"
    assert message =~ "bulk-provision"
  end

  test "bulk-provision --help returns usage" do
    assert {:ok, message} = ApiClients.run(["bulk-provision", "--help"])
    assert message =~ "orchardctl api-clients bulk-provision"
    assert message =~ "--dry-run"
    assert message =~ "--apply"
  end

  test "dry run validates CSV without creating API Clients", %{tenant: tenant, tmp_dir: tmp_dir} do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-dry-run")

    assert {:ok, message} =
             ApiClients.run(["bulk-provision", "--dry-run", "--file", input_path])

    assert message =~ "Dry run passed"
    assert message =~ "Organization: #{tenant.slug}"
    assert message =~ "API Clients to create: 1"

    refute Repo.get_by(ServiceAccount, tenant_id: tenant.id, name: "cli-client-dry-run")
  end

  test "apply writes one-time API Token output and does not echo the token", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-apply", key_name: "prod")
    output_path = Path.join(tmp_dir, "tokens.csv")

    assert {:ok, message} =
             ApiClients.run([
               "bulk-provision",
               "--apply",
               "--file",
               input_path,
               "--output",
               output_path
             ])

    assert message =~ "Apply complete"
    assert message =~ "One-time Secret Output: #{output_path}"

    {[headers], [row]} = read_output_csv!(output_path)
    output = headers |> Enum.zip(row) |> Map.new()
    token = Map.fetch!(output, "api_token")

    assert token =~ "orch_"
    refute message =~ token
    assert Bitwise.band(File.stat!(output_path).mode, 0o777) == 0o600

    api_key = Repo.get!(ApiKey, Map.fetch!(output, "api_token_id"))
    assert ApiKeySecret.verify(token, api_key.secret_hash)
    assert Repo.get_by!(ServiceAccount, tenant_id: tenant.id, name: "cli-client-apply")
  end

  test "apply preflights an existing output path before mutating state", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-preflight")
    output_path = Path.join(tmp_dir, "tokens.csv")
    File.write!(output_path, "existing")

    assert {:error, message, 1} =
             ApiClients.run([
               "bulk-provision",
               "--apply",
               "--file",
               input_path,
               "--output",
               output_path
             ])

    assert message =~ "output path already exists"
    refute Repo.get_by(ServiceAccount, tenant_id: tenant.id, name: "cli-client-preflight")
  end

  test "apply marks output failure when one-time output cannot be written", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-output-failure")
    blocked_dir = Path.join(tmp_dir, "blocked-output")
    output_path = Path.join(blocked_dir, "tokens.csv")
    File.mkdir!(blocked_dir)
    File.chmod!(blocked_dir, 0o500)

    try do
      assert {:error, message, 1} =
               ApiClients.run([
                 "bulk-provision",
                 "--apply",
                 "--file",
                 input_path,
                 "--output",
                 output_path
               ])

      assert message =~ "Apply succeeded"
      assert message =~ "One-time Secret Output failed"
      assert message =~ "Rotate or revoke these API Token prefixes"
      refute File.exists?(output_path)

      api_client =
        Repo.get_by!(ServiceAccount,
          tenant_id: tenant.id,
          name: "cli-client-output-failure"
        )

      api_key = Repo.get_by!(ApiKey, service_account_id: api_client.id, name: "primary")
      assert message =~ api_key.token_prefix
      refute message =~ api_key.secret_hash

      assert [batch] = Repo.all(ProvisioningBatch)
      assert batch.status == :output_failed
      assert batch.error_summary["api_token_prefixes"] == [api_key.token_prefix]

      audit_log =
        Repo.get_by!(AuditLog,
          action: "provisioning_batch.output_failed",
          target_type: "provisioning_batch",
          target_id: batch.id
        )

      assert audit_log.payload["error_summary"]["api_token_prefixes"] == [
               api_key.token_prefix
             ]
    after
      File.chmod!(blocked_dir, 0o700)
    end
  end

  test "duplicate API Token names require explicit rotation", %{tenant: tenant, tmp_dir: tmp_dir} do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-rotate", key_name: "prod")
    first_output_path = Path.join(tmp_dir, "first-tokens.csv")
    second_output_path = Path.join(tmp_dir, "second-tokens.csv")
    rotated_output_path = Path.join(tmp_dir, "rotated-tokens.csv")

    assert {:ok, _message} =
             ApiClients.run([
               "bulk-provision",
               "--apply",
               "--file",
               input_path,
               "--output",
               first_output_path
             ])

    {[headers], [first_row]} = read_output_csv!(first_output_path)
    first_token = headers |> Enum.zip(first_row) |> Map.new() |> Map.fetch!("api_token")

    assert {:error, duplicate_message, 1} =
             ApiClients.run([
               "bulk-provision",
               "--apply",
               "--file",
               input_path,
               "--output",
               second_output_path
             ])

    assert duplicate_message =~ "Key Rotation mode"
    refute File.exists?(second_output_path)
    refute duplicate_message =~ first_token

    assert {:ok, rotation_message} =
             ApiClients.run([
               "bulk-provision",
               "--apply",
               "--rotation",
               "--file",
               input_path,
               "--output",
               rotated_output_path
             ])

    assert rotation_message =~ "API Tokens rotated: 1"
    {[headers], [rotated_row]} = read_output_csv!(rotated_output_path)
    rotated_token = headers |> Enum.zip(rotated_row) |> Map.new() |> Map.fetch!("api_token")
    assert rotated_token != first_token
  end

  defp write_csv!(tmp_dir, tenant, overrides) do
    row =
      %{
        organization: tenant.slug,
        api_client: "cli-client",
        owner_contact: "owner@example.com",
        key_name: "primary"
      }
      |> Map.merge(Map.new(overrides))

    path = Path.join(tmp_dir, "#{row.api_client}.csv")

    File.write!(path, """
    organization,api_client,owner_contact,key_name
    #{row.organization},#{row.api_client},#{row.owner_contact},#{row.key_name}
    """)

    path
  end

  defp read_output_csv!(path) do
    [headers | rows] = path |> File.read!() |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
    {[headers], rows}
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
