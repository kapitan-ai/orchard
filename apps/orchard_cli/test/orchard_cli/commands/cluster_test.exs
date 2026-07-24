defmodule OrchardCLI.Commands.ClusterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.{ApiKey, AuditLog, RoleBinding, ServiceAccount}
  alias Orchard.Repo
  alias OrchardCLI.Commands.Cluster, as: ClusterCmd

  defmodule ConfigurableFileOps do
    def exists?(path), do: File.exists?(path)
    def dir?(path), do: File.dir?(path)
    def lstat(path), do: File.lstat(path)
    def open(path, modes), do: File.open(path, modes)
    def chmod(path, mode), do: File.chmod(path, mode)
    def close(file), do: File.close(file)
    def rm(path), do: File.rm(path)

    def ln(source, target) do
      if Process.get(:cluster_file_ops_fail_link) do
        source
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("api_token")
        |> then(&Process.put(:cluster_file_ops_failed_token, &1))

        {:error, :eperm}
      else
        File.ln(source, target)
      end
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    previous = Application.get_env(:orchard_controller, :control_plane)

    tmp_dir =
      Path.join(System.tmp_dir!(), "orchard-cluster-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if is_nil(previous) do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "help and usage" do
    test "group usage includes init and status" do
      assert {:error, message, 1} = ClusterCmd.run([])

      assert message =~ "orchardctl cluster"
      assert message =~ "init"
      assert message =~ "status"
    end

    test "status --help returns status usage" do
      assert {:ok, message} = ClusterCmd.run(["status", "--help"])

      assert message =~ "orchardctl cluster status"
      assert message =~ "--json"
    end

    test "unknown status option returns exit code 2" do
      assert {:error, message, 2} = ClusterCmd.run(["status", "--bogus"])

      assert message == "Unknown option: --bogus"
    end
  end

  describe "init" do
    test "SPEC.md §11.9 JSON success writes secret once to output and not stdout", %{
      tmp_dir: tmp_dir
    } do
      output_path = Path.join(tmp_dir, "admin.json")

      log =
        capture_log(fn ->
          send(
            self(),
            {:cluster_result,
             ClusterCmd.run([
               "init",
               "--output",
               output_path,
               "--json",
               "--client-name",
               "json-admin"
             ])}
          )
        end)

      assert_receive {:cluster_result, {:ok, message}}

      decoded = Jason.decode!(message)
      credential = Jason.decode!(File.read!(output_path))
      token = Map.fetch!(credential, "api_token")

      assert decoded["object"] == "cluster_management.cluster_init"
      assert decoded["contract_version"] == "orchard.cluster_management.cluster_init.v1"
      assert decoded["api_client_id"] == credential["api_client_id"]
      assert decoded["api_token_id"] == credential["api_token_id"]
      assert decoded["api_token_prefix"] == credential["api_token_prefix"]
      assert decoded["recovery"] == false
      assert decoded["output_path"] == output_path
      assert decoded["next_steps"] != []
      assert token =~ ~r/^orchard_sk_[A-Za-z0-9_-]{16}_[A-Za-z0-9_-]{43}$/
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      assert token_occurrences(File.read!(output_path), token) == 1
    end

    test "SPEC.md §10.2 post-mint output failure never logs or returns plaintext", %{
      tmp_dir: tmp_dir
    } do
      output_path = Path.join(tmp_dir, "failed-admin.json")

      {log, result, token} =
        with_configurable_file_ops(fn ->
          log =
            capture_log(fn ->
              send(
                self(),
                {:cluster_result,
                 ClusterCmd.run([
                   "init",
                   "--output",
                   output_path,
                   "--json",
                   "--client-name",
                   "output-failure-admin"
                 ])}
              )
            end)

          assert_receive {:cluster_result, result}
          token = Process.get(:cluster_file_ops_failed_token)
          assert is_binary(token)
          {log, result, token}
        end)

      assert {:error, message, 1} = result
      assert message =~ "one_time_secret_output_failed"
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)
      assert Path.wildcard(Path.join(tmp_dir, ".*.tmp-*")) == []

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert output_failed.payload["api_token_prefix"] =~ ~r/^orchard_kp_/
      refute inspect(Repo.all(AuditLog)) =~ token
    end

    test "SPEC.md §11.9 force-new-admin requires yes and then mints recovery additively", %{
      tmp_dir: tmp_dir
    } do
      first_output = Path.join(tmp_dir, "first-admin.json")
      blocked_output = Path.join(tmp_dir, "blocked-recovery.json")
      recovery_output = Path.join(tmp_dir, "recovery-admin.json")

      assert {:ok, _message} = ClusterCmd.run(["init", "--output", first_output])

      existing_name = "orchard-bootstrap-admin-recovery-00000000-0000-0000-0000-000000000001"

      assert {:ok, _existing} =
               %ServiceAccount{}
               |> ServiceAccount.changeset(%{
                 tenant_id: Orchard.Governance.legacy_tenant_id(),
                 name: existing_name,
                 owner_contact: "existing-operator",
                 purpose: "cluster_admin_bootstrap"
               })
               |> Repo.insert()

      assert {:error, blocked_message, 2} =
               ClusterCmd.run(["init", "--output", blocked_output, "--force-new-admin"])

      assert blocked_message =~ "--force-new-admin requires --yes"
      refute File.exists?(blocked_output)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 2

      assert {:ok, recovery_message} =
               ClusterCmd.run([
                 "init",
                 "--output",
                 recovery_output,
                 "--force-new-admin",
                 "--yes"
               ])

      recovery = Jason.decode!(File.read!(recovery_output))
      token = Map.fetch!(recovery, "api_token")

      api_client = Repo.get!(ServiceAccount, Map.fetch!(recovery, "api_client_id"))

      assert recovery_message =~ "Recovery credential: yes"
      refute recovery_message =~ token
      assert api_client.name != existing_name
      assert String.starts_with?(api_client.name, "orchard-bootstrap-admin-recovery-")

      suffix = String.replace_prefix(api_client.name, "orchard-bootstrap-admin-recovery-", "")
      assert {:ok, _uuid} = Ecto.UUID.cast(suffix)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 3
      assert Repo.aggregate(ApiKey, :count, :id) == 2
      assert Repo.aggregate(RoleBinding, :count, :id) == 2
    end

    test "SPEC.md §11.9 second init returns stable cluster_already_initialized error", %{
      tmp_dir: tmp_dir
    } do
      first_output = Path.join(tmp_dir, "first-admin.json")
      second_output = Path.join(tmp_dir, "second-admin.json")

      assert {:ok, _message} = ClusterCmd.run(["init", "--output", first_output])
      assert {:error, message, 1} = ClusterCmd.run(["init", "--output", second_output])

      assert message == "Error: cluster_already_initialized"
      refute File.exists?(second_output)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
    end

    test "SPEC.md §11.9 preflights output path before minting", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "admin.json")
      File.write!(output_path, "existing")

      assert {:error, message, 1} = ClusterCmd.run(["init", "--output", output_path])

      assert message =~ "output path already exists"
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §11.9 --json missing --output emits a stable JSON error object" do
      assert {:error, message, 1} = ClusterCmd.run(["init", "--json"])

      decoded = Jason.decode!(message)

      assert decoded["object"] == "error"
      assert decoded["code"] == "missing_output"
      assert decoded["message"] =~ "--output"
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
    end

    test "SPEC.md §11.9 --json existing output path emits a stable JSON error object", %{
      tmp_dir: tmp_dir
    } do
      output_path = Path.join(tmp_dir, "admin.json")
      File.write!(output_path, "existing")

      assert {:error, message, 1} = ClusterCmd.run(["init", "--output", output_path, "--json"])

      decoded = Jason.decode!(message)

      assert decoded["object"] == "error"
      assert decoded["code"] == "output_path_exists"
      assert decoded["message"] =~ "already exists"
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
    end

    test "SPEC.md §11.9 --json force-new-admin without --yes emits a stable JSON error object", %{
      tmp_dir: tmp_dir
    } do
      output_path = Path.join(tmp_dir, "recovery.json")

      assert {:error, message, 2} =
               ClusterCmd.run(["init", "--output", output_path, "--json", "--force-new-admin"])

      decoded = Jason.decode!(message)

      assert decoded["object"] == "error"
      assert decoded["code"] == "recovery_confirmation_required"
      assert decoded["message"] =~ "--yes"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
    end

    test "--help combined with other flags prints usage without minting", %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "admin.json")

      assert {:ok, message} = ClusterCmd.run(["init", "--output", output_path, "--help"])

      assert message =~ "orchardctl cluster init"
      assert message =~ "--output"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
    end

    test "recovery mint with a duplicate --client-name renders a clean error", %{tmp_dir: tmp_dir} do
      first_output = Path.join(tmp_dir, "first-admin.json")
      recovery_output = Path.join(tmp_dir, "recovery-admin.json")

      assert {:ok, _message} =
               ClusterCmd.run(["init", "--output", first_output, "--client-name", "dup-admin"])

      assert {:error, message, 1} =
               ClusterCmd.run([
                 "init",
                 "--output",
                 recovery_output,
                 "--json",
                 "--client-name",
                 "dup-admin",
                 "--force-new-admin",
                 "--yes"
               ])

      decoded = Jason.decode!(message)

      assert decoded["object"] == "error"
      assert decoded["code"] == "cluster_init_invalid"
      assert decoded["errors"] != []
      refute File.exists?(recovery_output)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
    end

    test "first mint colliding with a disabled service account renders a clean error", %{
      tmp_dir: tmp_dir
    } do
      {:ok, _disabled} =
        %ServiceAccount{}
        |> ServiceAccount.changeset(%{
          tenant_id: Orchard.Governance.legacy_tenant_id(),
          name: "orchard-bootstrap-admin",
          owner_contact: "prior-admin",
          purpose: "cluster_admin_bootstrap",
          disabled_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        })
        |> Repo.insert()

      output_path = Path.join(tmp_dir, "admin.json")

      assert {:error, message, 1} = ClusterCmd.run(["init", "--output", output_path])

      assert message =~ "cluster_init_invalid"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
    end
  end

  describe "status" do
    test "SPEC CLI/Console parity emits read-only control-plane JSON status" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-b",
            advisory_lock_status: :not_held,
            lock_age_ms: 1_200,
            last_renewed_at: ~U[2026-07-01 00:00:00Z]
          }
        end
      )

      assert {:ok, output} = ClusterCmd.run(["status", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "cluster_management.cluster_status"
      assert decoded["contract_version"] == "orchard.cluster_management.cluster_status.v1"

      assert decoded["summary"] == %{
               "deployment_mode" => "active_standby",
               "controller_role" => "standby",
               "advisory_lock_status" => "not_held"
             }

      assert decoded["control_plane"]["object"] == "cluster_management.control_plane_status"
      assert decoded["control_plane"]["deployment_mode"] == "active_standby"
      assert decoded["control_plane"]["this_controller_identity"] == "controller-a"
      assert decoded["control_plane"]["controller_role"] == "standby"
      assert decoded["control_plane"]["leader_identity"] == "controller-b"
      assert decoded["control_plane"]["advisory_lock_status"] == "not_held"
      assert decoded["control_plane"]["lock_age_ms"] == 1_200
      assert decoded["control_plane"]["last_renewed_at"] == "2026-07-01T00:00:00Z"

      assert decoded["control_plane"]["standby_write_path_behavior"] ==
               "writes_return_503_controller_standby"

      assert decoded["control_plane"]["last_observed_leadership_error"] == nil
    end

    test "human output explains directly addressed standby write paths without failover actions" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn -> %{advisory_lock_status: :unknown} end
      )

      assert {:ok, output} = ClusterCmd.run(["status"])

      assert output =~ "Role: standby"
      assert output =~ "Deployment: Active/Standby"
      refute output =~ "Active/Standby: standby"
      assert output =~ "Advisory lock: unknown"
      assert output =~ "Write paths: writes return 503 controller standby"
      refute output =~ "failover"
      refute output =~ "transfer"
    end

    test "SPEC Leadership status is unknown in JSON when advisory-lock status is unreadable" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a"
      )

      assert {:ok, output} = ClusterCmd.run(["status", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["summary"] == %{
               "deployment_mode" => "active_standby",
               "controller_role" => "unknown",
               "advisory_lock_status" => "unknown"
             }

      assert decoded["control_plane"]["controller_role"] == "unknown"
      assert decoded["control_plane"]["leader_identity"] == nil
      assert decoded["control_plane"]["standby_write_path_behavior"] == "unknown"
    end

    test "SPEC CLI/Console parity degrades malformed provider status to unavailable JSON" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn -> %{advisory_lock_status: "flaky"} end
      )

      assert {:ok, output} = ClusterCmd.run(["status", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["summary"] == %{
               "deployment_mode" => "active_standby",
               "controller_role" => "unknown",
               "advisory_lock_status" => "unavailable"
             }

      assert decoded["control_plane"]["leader_identity"] == nil
      assert decoded["control_plane"]["standby_write_path_behavior"] == "unknown"

      assert decoded["control_plane"]["last_observed_leadership_error"] ==
               "advisory_lock_read_failed: invalid_provider_status"
    end

    test "SPEC CLI/Console parity sanitizes provider-returned leadership error in JSON" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-b",
            advisory_lock_status: :not_held,
            last_observed_leadership_error:
              "password authentication failed for user orchard_admin at db.internal:5432"
          }
        end
      )

      assert {:ok, output} = ClusterCmd.run(["status", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["control_plane"]["last_observed_leadership_error"] ==
               "advisory_lock_read_failed: provider_reported_error"

      refute output =~ "orchard_admin"
      refute output =~ "db.internal"
    end
  end

  defp token_occurrences(contents, token) do
    contents
    |> String.split(token)
    |> length()
    |> Kernel.-(1)
  end

  defp with_configurable_file_ops(fun) do
    previous_impl = Application.get_env(:orchard_cli, :cluster_file_ops)
    previous_fail_link = Process.get(:cluster_file_ops_fail_link)
    previous_failed_token = Process.get(:cluster_file_ops_failed_token)

    Application.put_env(:orchard_cli, :cluster_file_ops, ConfigurableFileOps)
    Process.put(:cluster_file_ops_fail_link, true)
    Process.delete(:cluster_file_ops_failed_token)

    try do
      fun.()
    after
      restore_app_env(:cluster_file_ops, previous_impl)
      restore_process_setting(:cluster_file_ops_fail_link, previous_fail_link)
      restore_process_setting(:cluster_file_ops_failed_token, previous_failed_token)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:orchard_cli, key)
  defp restore_app_env(key, value), do: Application.put_env(:orchard_cli, key, value)

  defp restore_process_setting(key, nil), do: Process.delete(key)
  defp restore_process_setting(key, value), do: Process.put(key, value)
end
