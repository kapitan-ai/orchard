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

    def lstat(path) do
      if vanish_output_path?(path) do
        Process.put(:cluster_file_ops_vanish_injected, true)
        {:error, :enoent}
      else
        real_lstat(path)
      end
    end

    defp vanish_output_path?(path) do
      Process.get(:cluster_file_ops_vanish_output_path) == path and
        Process.get(:cluster_file_ops_reservation_opened) == true and
        !Process.get(:cluster_file_ops_vanish_injected)
    end

    defp real_lstat(path) do
      case File.lstat(path) do
        {:ok, stat} ->
          maybe_replace_output_after_lstat(path, stat)

          cond do
            Process.get(:cluster_file_ops_foreign_owner_symlink) == path ->
              {:ok, %{stat | uid: stat.uid + 1}}

            drift_output_identity?(path) ->
              Process.put(:cluster_file_ops_identity_drift_injected, true)
              {:ok, %{stat | inode: stat.inode + 1}}

            true ->
              {:ok, stat}
          end

        error ->
          error
      end
    end

    defp drift_output_identity?(path) do
      Process.get(:cluster_file_ops_drift_output_identity) == path and
        !Process.get(:cluster_file_ops_identity_drift_injected)
    end

    def stat(path) do
      case File.stat(path) do
        {:ok, stat} ->
          if foreign_owner_parent?(path) do
            {:ok, %{stat | uid: stat.uid + 1}}
          else
            {:ok, stat}
          end

        error ->
          error
      end
    end

    defp foreign_owner_parent?(path) do
      Process.get(:cluster_file_ops_foreign_owner_parent) == path or
        (Process.get(:cluster_file_ops_foreign_owner_parent_after_write) == path and
           Process.get(:cluster_file_ops_descriptor_write_completed) == true)
    end

    def open(path, modes) do
      result = File.open(path, modes)

      case result do
        {:ok, file} ->
          role = if :exclusive in modes, do: :publication, else: :cleanup
          Process.put({:cluster_file_ops_descriptor_role, file}, role)
          if role == :publication, do: Process.put(:cluster_file_ops_reservation_opened, true)

        {:error, _reason} ->
          :ok
      end

      if match?({:ok, _file}, result) and :exclusive in modes and
           (is_binary(Process.get(:cluster_file_ops_foreign_output_after_lstat)) or
              is_binary(Process.get(:cluster_file_ops_foreign_output_before_close))) do
        Process.put(:cluster_file_ops_foreign_output_path, path)
      end

      result
    end

    def write(file, contents) do
      if Process.get(:cluster_file_ops_capture_token), do: capture_token_payload(contents)

      if Process.get(:cluster_file_ops_fail_write_after_persist) and
           !Process.get(:cluster_file_ops_write_failure_injected) do
        capture_token_payload(contents)
        :ok = IO.binwrite(file, contents)
        Process.put(:cluster_file_ops_descriptor_write_completed, true)
        Process.put(:cluster_file_ops_write_failure_injected, true)
        {:error, :eio}
      else
        result = IO.binwrite(file, contents)
        if result == :ok, do: Process.put(:cluster_file_ops_descriptor_write_completed, true)
        result
      end
    end

    def sync(file) do
      role = Process.get({:cluster_file_ops_descriptor_role, file})

      cond do
        Process.get(:cluster_file_ops_fail_cleanup_preflight_sync) and
          role == :cleanup and
          Process.get(:cluster_file_ops_descriptor_write_completed) != true and
            !Process.get(:cluster_file_ops_sync_failure_injected) ->
          Process.put(:cluster_file_ops_sync_failure_injected, true)
          {:error, :eio}

        Process.get(:cluster_file_ops_fail_sync_after_write) and
          Process.get(:cluster_file_ops_descriptor_write_completed) == true and
            !Process.get(:cluster_file_ops_sync_failure_injected) ->
          Process.put(:cluster_file_ops_sync_failure_injected, true)
          {:error, :eio}

        true ->
          :file.sync(file)
      end
    end

    def truncate(file) do
      if Process.get(:cluster_file_ops_fail_redaction_truncate) and
           Process.get(:cluster_file_ops_descriptor_write_completed) == true do
        {:error, :eio}
      else
        :file.truncate(file)
      end
    end

    def chmod(path, mode), do: File.chmod(path, mode)

    def close(file) do
      role = Process.get({:cluster_file_ops_descriptor_role, file})

      cond do
        role == :publication and replace_output_on_close?() ->
          replace_output_on_close(file)

        role == :publication and fail_close_after_write?() ->
          inject_invalidating_close_failure(file)

        role == :cleanup and fail_cleanup_close_after_commit?() ->
          inject_cleanup_close_anomaly(file)

        fail_close_before_write?() ->
          inject_close_failure()

        true ->
          close_descriptor(file, role)
      end
    end

    defp replace_output_on_close? do
      is_binary(Process.get(:cluster_file_ops_foreign_output_before_close)) and
        Process.get(:cluster_file_ops_descriptor_write_completed) == true and
        !Process.get(:cluster_file_ops_close_replacement_injected)
    end

    defp replace_output_on_close(file) do
      path = Process.get(:cluster_file_ops_foreign_output_path)
      moved_path = path <> ".reserved-at-close"
      File.rename!(path, moved_path)
      File.write!(path, Process.get(:cluster_file_ops_foreign_output_before_close))
      Process.put(:cluster_file_ops_foreign_output_moved_path, moved_path)
      Process.put(:cluster_file_ops_close_replacement_injected, true)
      close_descriptor(file, :publication)
    end

    defp fail_close_after_write? do
      Process.get(:cluster_file_ops_fail_close_after_write) and
        Process.get(:cluster_file_ops_descriptor_write_completed) == true and
        !Process.get(:cluster_file_ops_close_failure_injected)
    end

    defp fail_close_before_write? do
      Process.get(:cluster_file_ops_fail_close_before_write) and
        Process.get(:cluster_file_ops_descriptor_write_completed) != true and
        !Process.get(:cluster_file_ops_close_failure_injected)
    end

    defp fail_cleanup_close_after_commit? do
      Process.get(:cluster_file_ops_fail_cleanup_close_after_commit) and
        Process.get(:cluster_file_ops_publication_close_completed) == true and
        !Process.get(:cluster_file_ops_cleanup_close_failure_injected)
    end

    defp inject_close_failure do
      Process.put(:cluster_file_ops_close_failure_injected, true)
      {:error, :eio}
    end

    defp inject_invalidating_close_failure(file) do
      Process.put(:cluster_file_ops_close_failure_injected, true)
      :ok = File.close(file)
      {:error, :eio}
    end

    defp inject_cleanup_close_anomaly(file) do
      Process.put(:cluster_file_ops_cleanup_close_failure_injected, true)
      :ok = File.close(file)
      {:error, :eio}
    end

    defp close_descriptor(file, role) do
      result = File.close(file)

      if role == :publication and result == :ok,
        do: Process.put(:cluster_file_ops_publication_close_completed, true)

      result
    end

    defp maybe_replace_output_after_lstat(path, %File.Stat{type: :regular}) do
      if Process.get(:cluster_file_ops_foreign_output_path) == path and
           is_binary(Process.get(:cluster_file_ops_foreign_output_after_lstat)) and
           Process.get(:cluster_file_ops_descriptor_write_completed) == true and
           is_nil(Process.get(:cluster_file_ops_foreign_output_moved_path)) do
        moved_path = path <> ".reserved"
        File.rename!(path, moved_path)
        File.write!(path, Process.get(:cluster_file_ops_foreign_output_after_lstat))
        Process.put(:cluster_file_ops_foreign_output_moved_path, moved_path)
      end
    end

    defp maybe_replace_output_after_lstat(_path, _stat), do: :ok

    defp capture_token_payload(contents) do
      contents
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

    test "SPEC.md §10.2 partial descriptor write failure leaves no plaintext", %{
      tmp_dir: tmp_dir
    } do
      output_path = Path.join(tmp_dir, "failed-admin.json")

      {log, result, token} =
        with_configurable_file_ops([fail_write_after_persist: true], fn ->
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
      assert File.read!(output_path) == ""
      assert residual_files(tmp_dir) == [output_path]

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert output_failed.payload["api_token_prefix"] =~ ~r/^orchard_kp_/
      refute inspect(Repo.all(AuditLog)) =~ token
    end

    test "SPEC.md §10.2 descriptor sync failure returns failure with no plaintext residual",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "failed-sync-admin",
        capture_token: true,
        fail_sync_after_write: true,
        expected_output: ""
      )
    end

    test "SPEC.md §10.2 final-path replacement preserves foreign data and contains plaintext",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "foreign-target-admin",
        capture_token: true,
        foreign_output_after_lstat: "unrelated operator data",
        expected_output: "unrelated operator data"
      )
    end

    test "SPEC.md §10.2 final-path replacement at close preserves foreign data",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "close-race-admin",
        capture_token: true,
        foreign_output_before_close: "unrelated replacement data",
        expected_output: "unrelated replacement data"
      )
    end

    test "SPEC.md §10.2 descriptor close failure leaves no plaintext",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "close-failure-admin",
        capture_token: true,
        fail_close_after_write: true,
        expected_output: ""
      )
    end

    test "SPEC.md §10.2 recovery descriptor close anomaly preserves committed output once",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "cleanup-close-anomaly-admin.json")

      {log, result, token} =
        with_configurable_file_ops(
          [capture_token: true, fail_cleanup_close_after_commit: true],
          fn ->
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
                     "cleanup-close-anomaly-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}
            {log, result, Process.get(:cluster_file_ops_failed_token)}
          end
        )

      assert {:ok, output} = result
      assert is_binary(token)
      assert Jason.decode!(output)["api_token_prefix"] =~ ~r/^orchard_kp_/
      assert log =~ "recovery descriptor close failed after output commit"
      assert token_occurrences(File.read!(output_path), token) == 1
      assert residual_files(tmp_dir) == [output_path]
      refute output =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
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

      assert message =~ "Error: cluster_already_initialized"
      assert message =~ "Retained output reservation"
      assert message =~ "only after verifying"
      assert message =~ second_output
      assert_empty_reservation(second_output)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
    end

    test "SPEC.md §10.2 empty-reservation close failure preserves the primary error", %{
      tmp_dir: tmp_dir
    } do
      first_output = Path.join(tmp_dir, "first-admin.json")
      second_output = Path.join(tmp_dir, "second-admin.json")

      assert {:ok, _message} = ClusterCmd.run(["init", "--output", first_output])
      first_token = first_output |> File.read!() |> Jason.decode!() |> Map.fetch!("api_token")

      {log, result} =
        with_configurable_file_ops(
          [fail_close_before_write: true],
          fn ->
            log =
              capture_log(fn ->
                send(
                  self(),
                  {:cluster_result, ClusterCmd.run(["init", "--output", second_output, "--json"])}
                )
              end)

            assert_receive {:cluster_result, result}
            {log, result}
          end
        )

      assert {:error, message, 1} = result
      payload = Jason.decode!(message)
      assert payload["code"] == "cluster_already_initialized"
      assert payload["cleanup_unresolved"] =~ "descriptor_close"
      assert payload["output_reservation_retained"] == second_output
      refute message =~ first_token
      refute log =~ first_token
      assert File.read!(second_output) == ""
      assert Bitwise.band(File.stat!(second_output).mode, 0o777) == 0o600

      for path <- residual_files(tmp_dir), path != first_output do
        refute File.read!(path) =~ "orchard_sk_"
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1
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

    test "SPEC.md §11.9 rejects a foreign-owned private output parent before minting",
         %{tmp_dir: tmp_dir} do
      foreign_dir = Path.join(tmp_dir, "foreign-private")
      File.mkdir!(foreign_dir)
      File.chmod!(foreign_dir, 0o700)
      output_path = Path.join(foreign_dir, "admin.json")

      result =
        with_configurable_file_ops([foreign_owner_parent: foreign_dir], fn ->
          ClusterCmd.run(["init", "--output", output_path, "--json"])
        end)

      assert {:error, message, 1} = result
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute message =~ "orchard_sk_"
      assert_empty_reservation(output_path)

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ "orchard_sk_"
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §11.9 rejects a foreign-owned output ancestor before minting",
         %{tmp_dir: tmp_dir} do
      output_dir = Path.join(tmp_dir, "operator-private")
      File.mkdir!(output_dir)
      File.chmod!(output_dir, 0o700)
      output_path = Path.join(output_dir, "admin.json")

      result =
        with_configurable_file_ops([foreign_owner_parent: tmp_dir], fn ->
          ClusterCmd.run(["init", "--output", output_path, "--json"])
        end)

      assert {:error, message, 1} = result
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute message =~ "orchard_sk_"
      assert_empty_reservation(output_path)

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ "orchard_sk_"
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §11.9 rejects a foreign-owned ancestor symlink before minting",
         %{tmp_dir: tmp_dir} do
      safe_dir = Path.join(tmp_dir, "safe")
      output_dir = Path.join(safe_dir, "out")

      link_path =
        Path.join("/tmp", "orchard-cluster-attacker-link-#{System.unique_integer([:positive])}")

      File.mkdir_p!(output_dir)
      File.ln_s!(safe_dir, link_path)
      on_exit(fn -> File.rm(link_path) end)
      output_path = Path.join([link_path, "out", "admin.json"])

      result =
        with_configurable_file_ops([foreign_owner_symlink: link_path], fn ->
          ClusterCmd.run(["init", "--output", output_path, "--json"])
        end)

      assert {:error, message, 1} = result
      assert Jason.decode!(message)["code"] == "output_parent_not_writable"
      refute message =~ "orchard_sk_"
      assert_empty_reservation(output_path)

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ "orchard_sk_"
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §11.9 cleanup-descriptor preflight sync failure prevents minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "admin.json")

      {log, result} =
        with_configurable_file_ops([fail_cleanup_preflight_sync: true], fn ->
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
      decoded = Jason.decode!(message)
      assert decoded["code"] == "output_reservation_failed"
      assert decoded["message"] =~ "reservation failed"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      assert_empty_reservation(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ "orchard_sk_"
      end
    end

    test "SPEC.md §11.9 reservation identity drift reports a distinct stable error",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "identity-drift-admin.json")

      result =
        with_configurable_file_ops([drift_output_identity: output_path], fn ->
          ClusterCmd.run(["init", "--output", output_path, "--json"])
        end)

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "output_path_identity_changed"
      assert decoded["message"] =~ "identity changed during reservation"
      refute message =~ "orchard_sk_"
      assert_empty_reservation(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 reservation-stage cleanup failure surfaces top-level cleanup_unresolved",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "reservation-cleanup-admin.json")

      {log, result} =
        with_configurable_file_ops(
          [fail_cleanup_preflight_sync: true, fail_close_before_write: true],
          fn ->
            log =
              capture_log(fn ->
                send(
                  self(),
                  {:cluster_result, ClusterCmd.run(["init", "--output", output_path, "--json"])}
                )
              end)

            assert_receive {:cluster_result, result}
            {log, result}
          end
        )

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "output_reservation_failed"
      assert decoded["cleanup_unresolved"] =~ "cleanup_descriptor_close"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      assert_empty_reservation(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 unredactable plaintext renders qualified non-secret operator guidance",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "unredactable-admin.json")

      {log, result, token} =
        with_configurable_file_ops(
          [capture_token: true, fail_sync_after_write: true, fail_redaction_truncate: true],
          fn ->
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
                     "unredactable-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}
            token = Process.get(:cluster_file_ops_failed_token)
            assert is_binary(token)
            {log, result, token}
          end
        )

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "one_time_secret_output_failed"
      assert decoded["message"] =~ "Manual containment required"
      assert decoded["message"] =~ output_path
      assert decoded["message"] =~ "may now name unrelated data"
      assert decoded["message"] =~ tmp_dir
      assert decoded["message"] =~ ~r/orchard_kp_/
      assert decoded["message"] =~ "plaintext_redaction"
      refute Map.has_key?(decoded, "output_reservation_retained")
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      assert File.read!(output_path) =~ token

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      persisted_reason = output_failed.payload["error_summary"]["reason"]

      assert persisted_reason =~ "containment_unresolved:plaintext_redaction=eio"
      assert_path_free_output_failure(output_failed, tmp_dir, token)
      refute inspect(Repo.all(AuditLog)) =~ token
    end

    test "SPEC.md §10.2 post-mint ancestor-trust failure keeps the audit payload path-free",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "hierarchy-failure-admin.json")

      {log, result, token} =
        with_configurable_file_ops(
          [capture_token: true, foreign_owner_parent_after_write: tmp_dir],
          fn ->
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
                     "hierarchy-failure-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}
            token = Process.get(:cluster_file_ops_failed_token)
            assert is_binary(token)
            {log, result, token}
          end
        )

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "one_time_secret_output_failed"
      assert decoded["message"] =~ "output_parent_hierarchy_untrusted"
      assert decoded["output_reservation_retained"] == output_path
      assert decoded["message"] =~ "may remain occupied"
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      assert_empty_reservation(output_path)

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      persisted_reason = output_failed.payload["error_summary"]["reason"]

      assert persisted_reason =~ "output_parent_hierarchy_untrusted"
      assert_path_free_output_failure(output_failed, tmp_dir, token)
      refute inspect(Repo.all(AuditLog)) =~ token
    end

    test "SPEC.md §11.9 reserved path disappearing during reservation prevents minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "vanished-admin.json")

      result =
        with_configurable_file_ops([vanish_output_path: output_path], fn ->
          ClusterCmd.run(["init", "--output", output_path, "--json"])
        end)

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "output_path_identity_changed"
      assert decoded["message"] =~ "reserved_output_path"
      refute decoded["code"] == "output_parent_missing"
      refute decoded["message"] =~ "parent directory does not exist"
      refute message =~ "orchard_sk_"
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
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
      refute Map.has_key?(decoded, "output_reservation_retained")
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
      assert_empty_reservation(recovery_output)
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
      assert_empty_reservation(output_path)
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

  defp with_configurable_file_ops(settings, fun) do
    previous_impl = Application.get_env(:orchard_cli, :cluster_file_ops)

    process_settings = %{
      cluster_file_ops_capture_token: Keyword.get(settings, :capture_token, false),
      cluster_file_ops_foreign_output_after_lstat: settings[:foreign_output_after_lstat],
      cluster_file_ops_foreign_output_before_close: settings[:foreign_output_before_close],
      cluster_file_ops_fail_close_after_write:
        Keyword.get(settings, :fail_close_after_write, false),
      cluster_file_ops_fail_close_before_write:
        Keyword.get(settings, :fail_close_before_write, false),
      cluster_file_ops_fail_cleanup_close_after_commit:
        Keyword.get(settings, :fail_cleanup_close_after_commit, false),
      cluster_file_ops_fail_write_after_persist:
        Keyword.get(settings, :fail_write_after_persist, false),
      cluster_file_ops_fail_sync_after_write:
        Keyword.get(settings, :fail_sync_after_write, false),
      cluster_file_ops_fail_cleanup_preflight_sync:
        Keyword.get(settings, :fail_cleanup_preflight_sync, false),
      cluster_file_ops_fail_redaction_truncate:
        Keyword.get(settings, :fail_redaction_truncate, false),
      cluster_file_ops_drift_output_identity: settings[:drift_output_identity],
      cluster_file_ops_identity_drift_injected: nil,
      cluster_file_ops_vanish_output_path: settings[:vanish_output_path],
      cluster_file_ops_vanish_injected: nil,
      cluster_file_ops_reservation_opened: nil,
      cluster_file_ops_foreign_owner_parent: settings[:foreign_owner_parent],
      cluster_file_ops_foreign_owner_parent_after_write:
        settings[:foreign_owner_parent_after_write],
      cluster_file_ops_foreign_owner_symlink: settings[:foreign_owner_symlink],
      cluster_file_ops_foreign_output_path: nil,
      cluster_file_ops_foreign_output_moved_path: nil,
      cluster_file_ops_close_failure_injected: nil,
      cluster_file_ops_cleanup_close_failure_injected: nil,
      cluster_file_ops_close_replacement_injected: nil,
      cluster_file_ops_publication_close_completed: nil,
      cluster_file_ops_write_failure_injected: nil,
      cluster_file_ops_sync_failure_injected: nil,
      cluster_file_ops_descriptor_write_completed: nil,
      cluster_file_ops_failed_token: nil
    }

    previous_settings =
      Map.new(process_settings, fn {key, _value} -> {key, Process.get(key)} end)

    Application.put_env(:orchard_cli, :cluster_file_ops, ConfigurableFileOps)
    Enum.each(process_settings, fn {key, value} -> restore_process_setting(key, value) end)

    try do
      fun.()
    after
      restore_app_env(:cluster_file_ops, previous_impl)
      Enum.each(previous_settings, fn {key, value} -> restore_process_setting(key, value) end)
    end
  end

  defp assert_failed_delivery_has_no_plaintext(tmp_dir, client_name, settings) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")

    {log, result, token} =
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

        {log, result, token}
      end)

    assert {:error, message, 1} = result
    decoded = Jason.decode!(message)
    assert decoded["code"] == "one_time_secret_output_failed"
    assert decoded["output_reservation_retained"] == output_path
    assert decoded["message"] =~ "may remain occupied"
    assert decoded["message"] =~ "may now name unrelated data"
    assert decoded["message"] =~ ~r/orchard_kp_/
    refute decoded["message"] =~ "Manual containment required"
    refute message =~ token
    refute log =~ token
    refute log =~ "orchard_sk_"
    assert_output_state(output_path, Keyword.get(settings, :expected_output, :absent))

    for path <- residual_files(tmp_dir) do
      refute File.read!(path) =~ token
      refute File.read!(path) =~ "orchard_sk_"
    end

    assert Repo.aggregate(ServiceAccount, :count, :id) == 1
    assert Repo.aggregate(ApiKey, :count, :id) == 1
    assert Repo.aggregate(RoleBinding, :count, :id) == 1

    output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
    assert_path_free_output_failure(output_failed, tmp_dir, token)
    refute inspect(Repo.all(AuditLog)) =~ token
  end

  defp assert_path_free_output_failure(output_failed, tmp_dir, token) do
    persisted_reason = output_failed.payload["error_summary"]["reason"]

    assert persisted_reason =~ "one_time_secret_output_failed:"
    assert output_failed.payload["error_summary"]["api_token_prefix"] =~ ~r/^orchard_kp_/
    refute persisted_reason =~ tmp_dir
    refute persisted_reason =~ token
    refute persisted_reason =~ "orchard_sk_"
    refute persisted_reason =~ "may remain occupied"
    refute persisted_reason =~ "Manual containment"
  end

  defp assert_output_state(output_path, :absent), do: refute(File.exists?(output_path))
  defp assert_output_state(output_path, contents), do: assert(File.read!(output_path) == contents)

  defp assert_empty_reservation(path) do
    assert File.read!(path) == ""
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
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
