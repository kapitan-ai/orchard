defmodule OrchardCLI.Commands.ApiClientsTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, ProvisioningBatch, ServiceAccount}
  alias Orchard.Repo
  alias OrchardCLI.Commands.ApiClients

  defmodule ConfigurableFileOps do
    def exists?(path), do: File.exists?(path)
    def dir?(path), do: File.dir?(path)
    def open(path, modes), do: File.open(path, modes)
    def chmod(path, mode), do: File.chmod(path, mode)
    def close(file), do: File.close(file)

    def ln(source, target) do
      case Process.get(:api_clients_file_ops_link_error) do
        nil -> File.ln(source, target)
        reason -> {:error, reason}
      end
    end

    def rm(path) do
      if Process.get(:api_clients_file_ops_fail_secret_tmp_cleanup) && secret_tmp?(path) do
        {:error, :eperm}
      else
        File.rm(path)
      end
    end

    defp secret_tmp?(path), do: String.contains?(Path.basename(path), ".tmp-")
  end

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

  test "apply preflights an unwritable output directory before mutating state", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-unwritable-output")
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

      assert message =~ "output parent directory is not ready for exclusive delivery"
      refute File.exists?(output_path)

      refute Repo.get_by(ServiceAccount,
               tenant_id: tenant.id,
               name: "cli-client-unwritable-output"
             )

      assert Repo.aggregate(ProvisioningBatch, :count, :id) == 0
    after
      File.chmod!(blocked_dir, 0o700)
    end
  end

  test "apply preflights the final output delivery primitive before mutating state", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-link-preflight")
    output_path = Path.join(tmp_dir, "tokens.csv")

    with_configurable_file_ops(%{link_error: :eperm}, fn ->
      assert {:error, message, 1} =
               ApiClients.run([
                 "bulk-provision",
                 "--apply",
                 "--file",
                 input_path,
                 "--output",
                 output_path
               ])

      assert message =~ "output parent directory"
    end)

    refute File.exists?(output_path)
    refute Repo.get_by(ServiceAccount, tenant_id: tenant.id, name: "cli-client-link-preflight")
    assert Repo.aggregate(ProvisioningBatch, :count, :id) == 0
  end

  test "apply reports output failure when post-link temp cleanup cannot be guaranteed", %{
    tenant: tenant,
    tmp_dir: tmp_dir
  } do
    input_path = write_csv!(tmp_dir, tenant, api_client: "cli-client-cleanup-failure")
    output_path = Path.join(tmp_dir, "tokens.csv")

    with_configurable_file_ops(%{fail_secret_tmp_cleanup: true}, fn ->
      assert {:error, message, 1} =
               ApiClients.run([
                 "bulk-provision",
                 "--apply",
                 "--file",
                 input_path,
                 "--output",
                 output_path
               ])

      assert message =~ "Apply succeeded but One-time Secret Output failed"
      assert message =~ "temporary output cleanup failed"
    end)

    assert Repo.get_by(ServiceAccount, tenant_id: tenant.id, name: "cli-client-cleanup-failure")
    assert [%ProvisioningBatch{status: :output_failed}] = Repo.all(ProvisioningBatch)

    {[headers], [row]} = read_output_csv!(output_path)
    output = headers |> Enum.zip(row) |> Map.new()
    assert Map.fetch!(output, "api_token") =~ "orch_"
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

  defp with_configurable_file_ops(settings, fun) do
    previous_impl = Application.get_env(:orchard_cli, :api_clients_file_ops)
    previous_link_error = Process.get(:api_clients_file_ops_link_error)
    previous_cleanup = Process.get(:api_clients_file_ops_fail_secret_tmp_cleanup)

    Application.put_env(:orchard_cli, :api_clients_file_ops, ConfigurableFileOps)
    put_process_setting(:api_clients_file_ops_link_error, Map.get(settings, :link_error))

    put_process_setting(
      :api_clients_file_ops_fail_secret_tmp_cleanup,
      Map.get(settings, :fail_secret_tmp_cleanup)
    )

    try do
      fun.()
    after
      restore_app_env(:api_clients_file_ops, previous_impl)
      put_process_setting(:api_clients_file_ops_link_error, previous_link_error)
      put_process_setting(:api_clients_file_ops_fail_secret_tmp_cleanup, previous_cleanup)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:orchard_cli, key)
  defp restore_app_env(key, value), do: Application.put_env(:orchard_cli, key, value)

  defp put_process_setting(key, nil), do: Process.delete(key)
  defp put_process_setting(key, value), do: Process.put(key, value)

  defp read_output_csv!(path) do
    [headers | rows] = path |> File.read!() |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
    {[headers], rows}
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
