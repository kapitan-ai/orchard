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

    def open(path, modes) do
      case Process.get(:cluster_file_ops_foreign_temporary) do
        contents when is_binary(contents) ->
          if :exclusive in modes and String.contains?(Path.basename(path), ".tmp-") do
            File.write!(path, contents)
            Process.put(:cluster_file_ops_foreign_temporary_path, path)
            {:error, :eexist}
          else
            File.open(path, modes)
          end

        _other ->
          File.open(path, modes)
      end
    end

    def mkdir(path), do: File.mkdir(path)

    def rmdir(path) do
      if Process.get(:cluster_file_ops_fail_rmdir) == :preflight_parent and
           String.contains?(Path.basename(path), ".preflight-dir-") do
        {:error, :eperm}
      else
        File.rmdir(path)
      end
    end

    def chmod(path, mode), do: File.chmod(path, mode)

    def close(file) do
      result = File.close(file)

      if result == :ok && Process.get(:cluster_file_ops_fail_close_after_link) &&
           Process.get(:cluster_file_ops_link_succeeded) &&
           !Process.get(:cluster_file_ops_close_failure_injected) do
        Process.put(:cluster_file_ops_close_failure_injected, true)
        {:error, :eio}
      else
        result
      end
    end

    def rm(path) do
      if fail_remove?(path) do
        {:error, :eperm}
      else
        File.rm(path)
      end
    end

    def ln(source, target) do
      if Process.get(:cluster_file_ops_capture_token) ||
           Process.get(:cluster_file_ops_fail_link) ||
           Process.get(:cluster_file_ops_foreign_target) ||
           Process.get(:cluster_file_ops_foreign_temporary_after_link) do
        capture_token(source)
      end

      case Process.get(:cluster_file_ops_foreign_target) do
        contents when is_binary(contents) ->
          File.write!(target, contents)
          {:error, :eexist}

        _other ->
          if Process.get(:cluster_file_ops_fail_link) do
            {:error, :eperm}
          else
            source
            |> File.ln(target)
            |> replace_temporary_after_link(source)
          end
      end
    end

    defp replace_temporary_after_link(:ok, source) do
      Process.put(:cluster_file_ops_link_succeeded, true)

      case Process.get(:cluster_file_ops_foreign_temporary_after_link) do
        contents when is_binary(contents) ->
          File.rm!(source)
          File.write!(source, contents)
          Process.put(:cluster_file_ops_foreign_temporary_after_link_path, source)
          :ok

        _other ->
          :ok
      end
    end

    defp replace_temporary_after_link(result, _source), do: result

    defp fail_remove?(path) do
      case Process.get(:cluster_file_ops_fail_remove) do
        :preflight -> String.contains?(Path.basename(path), ".preflight-")
        :temporary_secret -> String.contains?(Path.basename(path), ".tmp-")
        _other -> false
      end
    end

    defp capture_token(source) do
      source
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("api_token")
      |> then(&Process.put(:cluster_file_ops_failed_token, &1))
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    previous = Application.get_env(:orchard_controller, :control_plane)

    tmp_dir =
      Path.join(System.tmp_dir!(), "orchard-cluster-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    File.chmod!(tmp_dir, 0o700)

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
      assert residual_files(tmp_dir) == [output_path]
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

    test "SPEC.md §10.2 temporary unlink failure returns failure with no plaintext residual",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "failed-cleanup-admin",
        capture_token: true,
        fail_remove: :temporary_secret,
        expected_output: ""
      )
    end

    test "SPEC.md §10.2 link and cleanup failures leave no plaintext residual",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "failed-link-cleanup-admin",
        fail_link: true,
        fail_remove: :temporary_secret
      )
    end

    test "SPEC.md §10.2 link race preserves a foreign target while containing plaintext",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "foreign-target-admin",
        fail_remove: :temporary_secret,
        foreign_target: "unrelated operator data",
        expected_output: "unrelated operator data"
      )
    end

    test "SPEC.md §10.2 generated staging collision preserves the foreign file before minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "staging-collision-admin.json")
      foreign_contents = "unrelated staging data"

      {log, result, foreign_path} =
        with_configurable_file_ops([foreign_temporary: foreign_contents], fn ->
          log =
            capture_log(fn ->
              send(
                self(),
                {:cluster_result, ClusterCmd.run(["init", "--output", output_path, "--json"])}
              )
            end)

          assert_receive {:cluster_result, result}
          foreign_path = Process.get(:cluster_file_ops_foreign_temporary_path)
          assert is_binary(foreign_path)
          {log, result, foreign_path}
        end)

      assert {:error, message, 1} = result
      assert File.read!(foreign_path) == foreign_contents
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      assert Jason.decode!(message)["message"] =~ "cleanup_unresolved"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 staging replacement after publication is preserved and plaintext is redacted",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "staging-replacement-admin",
        foreign_temporary_after_link: "unrelated replacement data",
        expected_foreign_temporary: "unrelated replacement data",
        expected_output: ""
      )
    end

    test "SPEC.md §10.2 close failure after publication leaves no plaintext",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "close-failure-admin",
        capture_token: true,
        fail_close_after_link: true,
        expected_output: ""
      )
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

    test "SPEC.md §11.9 rejects a cross-user-writable output parent before minting",
         %{tmp_dir: tmp_dir} do
      shared_dir = Path.join(tmp_dir, "shared")
      File.mkdir!(shared_dir)
      File.chmod!(shared_dir, 0o777)
      output_path = Path.join(shared_dir, "admin.json")

      assert {:error, message, 1} =
               ClusterCmd.run(["init", "--output", output_path, "--json"])

      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §11.9 preflight removal failure prevents minting and leaves no plaintext",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "admin.json")

      {log, result} =
        with_configurable_file_ops([fail_remove: :preflight], fn ->
          log =
            capture_log(fn ->
              send(
                self(),
                {:cluster_result, ClusterCmd.run(["init", "--output", output_path, "--json"])}
              )
            end)

          assert_receive {:cluster_result, result}
          {log, result}
        end)

      assert {:error, message, 1} = result
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ "orchard_sk_"
      end
    end

    test "SPEC.md §11.9 parent directory removal failure prevents minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "admin.json")

      {log, result} =
        with_configurable_file_ops([fail_rmdir: :preflight_parent], fn ->
          log =
            capture_log(fn ->
              send(
                self(),
                {:cluster_result, ClusterCmd.run(["init", "--output", output_path, "--json"])}
              )
            end)

          assert_receive {:cluster_result, result}
          {log, result}
        end)

      assert {:error, message, 1} = result
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)
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

  defp with_configurable_file_ops(fun),
    do: with_configurable_file_ops([fail_link: true], fun)

  defp with_configurable_file_ops(settings, fun) do
    previous_impl = Application.get_env(:orchard_cli, :cluster_file_ops)
    previous_fail_link = Process.get(:cluster_file_ops_fail_link)
    previous_fail_remove = Process.get(:cluster_file_ops_fail_remove)
    previous_capture_token = Process.get(:cluster_file_ops_capture_token)
    previous_foreign_target = Process.get(:cluster_file_ops_foreign_target)
    previous_foreign_temporary = Process.get(:cluster_file_ops_foreign_temporary)
    previous_foreign_temporary_path = Process.get(:cluster_file_ops_foreign_temporary_path)

    previous_foreign_temporary_after_link =
      Process.get(:cluster_file_ops_foreign_temporary_after_link)

    previous_foreign_temporary_after_link_path =
      Process.get(:cluster_file_ops_foreign_temporary_after_link_path)

    previous_fail_close_after_link = Process.get(:cluster_file_ops_fail_close_after_link)
    previous_fail_rmdir = Process.get(:cluster_file_ops_fail_rmdir)
    previous_link_succeeded = Process.get(:cluster_file_ops_link_succeeded)
    previous_close_failure_injected = Process.get(:cluster_file_ops_close_failure_injected)
    previous_failed_token = Process.get(:cluster_file_ops_failed_token)

    Application.put_env(:orchard_cli, :cluster_file_ops, ConfigurableFileOps)
    Process.put(:cluster_file_ops_fail_link, Keyword.get(settings, :fail_link, false))
    restore_process_setting(:cluster_file_ops_fail_remove, settings[:fail_remove])
    Process.put(:cluster_file_ops_capture_token, Keyword.get(settings, :capture_token, false))
    restore_process_setting(:cluster_file_ops_foreign_target, settings[:foreign_target])
    restore_process_setting(:cluster_file_ops_foreign_temporary, settings[:foreign_temporary])

    restore_process_setting(
      :cluster_file_ops_foreign_temporary_after_link,
      settings[:foreign_temporary_after_link]
    )

    Process.put(
      :cluster_file_ops_fail_close_after_link,
      Keyword.get(settings, :fail_close_after_link, false)
    )

    restore_process_setting(:cluster_file_ops_fail_rmdir, settings[:fail_rmdir])
    Process.delete(:cluster_file_ops_foreign_temporary_path)
    Process.delete(:cluster_file_ops_foreign_temporary_after_link_path)
    Process.delete(:cluster_file_ops_link_succeeded)
    Process.delete(:cluster_file_ops_close_failure_injected)
    Process.delete(:cluster_file_ops_failed_token)

    try do
      fun.()
    after
      restore_app_env(:cluster_file_ops, previous_impl)
      restore_process_setting(:cluster_file_ops_fail_link, previous_fail_link)
      restore_process_setting(:cluster_file_ops_fail_remove, previous_fail_remove)
      restore_process_setting(:cluster_file_ops_capture_token, previous_capture_token)
      restore_process_setting(:cluster_file_ops_foreign_target, previous_foreign_target)
      restore_process_setting(:cluster_file_ops_foreign_temporary, previous_foreign_temporary)

      restore_process_setting(
        :cluster_file_ops_foreign_temporary_path,
        previous_foreign_temporary_path
      )

      restore_process_setting(
        :cluster_file_ops_foreign_temporary_after_link,
        previous_foreign_temporary_after_link
      )

      restore_process_setting(
        :cluster_file_ops_foreign_temporary_after_link_path,
        previous_foreign_temporary_after_link_path
      )

      restore_process_setting(
        :cluster_file_ops_fail_close_after_link,
        previous_fail_close_after_link
      )

      restore_process_setting(:cluster_file_ops_fail_rmdir, previous_fail_rmdir)
      restore_process_setting(:cluster_file_ops_link_succeeded, previous_link_succeeded)

      restore_process_setting(
        :cluster_file_ops_close_failure_injected,
        previous_close_failure_injected
      )

      restore_process_setting(:cluster_file_ops_failed_token, previous_failed_token)
    end
  end

  defp assert_failed_delivery_has_no_plaintext(tmp_dir, client_name, settings) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")

    {log, result, token, foreign_temporary_path} =
      with_configurable_file_ops(settings, fn ->
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
                 client_name
               ])}
            )
          end)

        assert_receive {:cluster_result, result}
        token = Process.get(:cluster_file_ops_failed_token)
        assert is_binary(token)

        {log, result, token, Process.get(:cluster_file_ops_foreign_temporary_after_link_path)}
      end)

    assert {:error, message, 1} = result
    assert Jason.decode!(message)["code"] == "one_time_secret_output_failed"
    refute message =~ token
    refute log =~ token
    refute log =~ "orchard_sk_"
    assert_output_state(output_path, Keyword.get(settings, :expected_output, :absent))

    assert_foreign_temporary(
      foreign_temporary_path,
      Keyword.get(settings, :expected_foreign_temporary)
    )

    for path <- residual_files(tmp_dir) do
      refute File.read!(path) =~ token
      refute File.read!(path) =~ "orchard_sk_"
    end

    assert Repo.aggregate(ServiceAccount, :count, :id) == 1
    assert Repo.aggregate(ApiKey, :count, :id) == 1
    assert Repo.aggregate(RoleBinding, :count, :id) == 1
    assert Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
    refute inspect(Repo.all(AuditLog)) =~ token
  end

  defp assert_output_state(output_path, :absent), do: refute(File.exists?(output_path))
  defp assert_output_state(output_path, contents), do: assert(File.read!(output_path) == contents)

  defp assert_foreign_temporary(_path, nil), do: :ok

  defp assert_foreign_temporary(path, contents) do
    assert is_binary(path)
    assert File.read!(path) == contents
  end

  defp residual_files(tmp_dir) do
    tmp_dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(tmp_dir, entry)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> residual_files(path)
        {:ok, %File.Stat{type: :regular}} -> [path]
        _other -> []
      end
    end)
    |> Enum.sort()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:orchard_cli, key)
  defp restore_app_env(key, value), do: Application.put_env(:orchard_cli, key, value)

  defp restore_process_setting(key, nil), do: Process.delete(key)
  defp restore_process_setting(key, value), do: Process.put(key, value)
end
