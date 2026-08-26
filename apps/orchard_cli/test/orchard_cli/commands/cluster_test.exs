defmodule OrchardCLI.Commands.ClusterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.{ApiKey, AuditLog, RoleBinding, ServiceAccount}
  alias Orchard.Repo
  alias OrchardCLI.Commands.Cluster, as: ClusterCmd

  defmodule ConfigurableFileOps do
    @descriptor_preflight_payload "orchard-cluster-init-write-preflight\n"

    def exists?(path), do: File.exists?(path)
    def dir?(path), do: File.dir?(path)

    def mkdir(path) do
      if Process.get(:cluster_file_ops_fail_mkdir_after_foreign_create) do
        File.mkdir!(path)
        File.chmod!(path, 0o711)
        Process.put(:cluster_file_ops_foreign_failed_mkdir_directory, path)
        {:error, :eexist}
      else
        result = File.mkdir(path)
        if result == :ok, do: Process.put(:cluster_file_ops_staging_dir, path)
        result
      end
    end

    def rmdir(path) do
      if staging_directory_cleanup_rmdir_failure?(path) do
        Process.put(:cluster_file_ops_retained_staging_directory, path)
        {:error, :eio}
      else
        File.rmdir(path)
      end
    end

    defp staging_directory_cleanup_rmdir_failure?(path) do
      staging_dir = Process.get(:cluster_file_ops_staging_dir)

      Process.get(:cluster_file_ops_fail_staging_directory_cleanup_rmdir_before_write) and
        is_binary(staging_dir) and
        String.starts_with?(path, staging_dir <> ".quarantine-") and
        Process.get(:cluster_file_ops_descriptor_write_completed) != true
    end

    def ln(source, destination) do
      cond do
        output_parent_link_denied?(destination) ->
          {:error, :eacces}

        not preflight_link?(destination) ->
          File.ln(source, destination)

        Process.get(:cluster_file_ops_fail_preflight_ln) ->
          {:error, :enotsup}

        true ->
          calls = (Process.get(:cluster_file_ops_preflight_link_calls) || 0) + 1
          Process.put(:cluster_file_ops_preflight_link_calls, calls)
          File.ln(source, destination)
      end
    end

    defp output_parent_link_denied?(destination) do
      output_path = Process.get(:cluster_file_ops_output_path)

      Process.get(:cluster_file_ops_fail_output_parent_ln) and
        is_binary(output_path) and
        Path.dirname(destination) == Path.dirname(output_path)
    end

    defp preflight_link?(destination) do
      staging_dir = Process.get(:cluster_file_ops_staging_dir)
      is_binary(staging_dir) and Path.dirname(destination) == staging_dir
    end

    def rename(source, destination) do
      if output_parent_probe_quarantine_rename_failure?(source, destination) do
        Process.put(:cluster_file_ops_retained_output_parent_probe_path, source)
        {:error, :eacces}
      else
        maybe_replace_preflight_probe_before_quarantine(source, destination)
        maybe_replace_staging_before_quarantine(source, destination)
        maybe_replace_staging_directory_before_quarantine(source, destination)
        result = File.rename(source, destination)
        maybe_block_staging_restore(source, destination, result)
        maybe_block_probe_restore(source, destination, result)
        result
      end
    end

    defp output_parent_probe_quarantine_rename_failure?(source, destination) do
      output_path = Process.get(:cluster_file_ops_output_path)

      Process.get(:cluster_file_ops_fail_output_parent_probe_quarantine_rename) and
        is_binary(output_path) and
        Path.dirname(source) == Path.dirname(output_path) and
        String.starts_with?(
          Path.basename(source),
          ".orchard-cluster-init-link-preflight-"
        ) and
        String.starts_with?(destination, source <> ".quarantine-")
    end

    defp maybe_block_staging_restore(source, destination, :ok) do
      blocker = Process.get(:cluster_file_ops_block_staging_restore)

      if is_binary(blocker) and source == Process.get(:cluster_file_ops_staging_path) and
           destination == Process.get(:cluster_file_ops_foreign_staging_path) do
        File.write!(source, blocker)
        Process.put(:cluster_file_ops_blocked_restore_path, source)
      end
    end

    defp maybe_block_staging_restore(_source, _destination, _result), do: :ok

    defp maybe_block_probe_restore(source, destination, :ok) do
      blocker = Process.get(:cluster_file_ops_block_probe_restore)

      if is_binary(blocker) and
           destination == Process.get(:cluster_file_ops_foreign_preflight_probe_path) do
        File.write!(source, blocker)
        Process.put(:cluster_file_ops_blocked_probe_restore_path, source)
      end
    end

    defp maybe_block_probe_restore(_source, _destination, _result), do: :ok

    defp maybe_replace_preflight_probe_before_quarantine(source, destination) do
      if is_binary(Process.get(:cluster_file_ops_foreign_preflight_probe_before_quarantine)) and
           String.starts_with?(Path.basename(source), "link-preflight-") and
           !Process.get(:cluster_file_ops_preflight_probe_replacement_injected) do
        owned_path = source <> ".owned"
        File.rename!(source, owned_path)

        File.write!(
          source,
          Process.get(:cluster_file_ops_foreign_preflight_probe_before_quarantine)
        )

        Process.put(:cluster_file_ops_owned_preflight_probe_path, owned_path)
        Process.put(:cluster_file_ops_foreign_preflight_probe_path, destination)
        Process.put(:cluster_file_ops_preflight_probe_replacement_injected, true)
      end
    end

    defp maybe_replace_staging_before_quarantine(source, destination) do
      if source == Process.get(:cluster_file_ops_staging_path) and
           is_binary(Process.get(:cluster_file_ops_foreign_staging_before_cleanup)) and
           (Process.get(:cluster_file_ops_directory_sync_calls) || 0) >= 1 and
           !Process.get(:cluster_file_ops_staging_replacement_injected) do
        owned_path = source <> ".owned"
        File.rename!(source, owned_path)
        File.write!(source, Process.get(:cluster_file_ops_foreign_staging_before_cleanup))
        Process.put(:cluster_file_ops_foreign_staging_path, destination)
        Process.put(:cluster_file_ops_owned_staging_moved_path, owned_path)
        Process.put(:cluster_file_ops_staging_replacement_injected, true)
      end
    end

    defp maybe_replace_staging_directory_before_quarantine(source, destination) do
      if source == Process.get(:cluster_file_ops_staging_dir) and
           Process.get(:cluster_file_ops_replace_staging_directory_before_cleanup) and
           (Process.get(:cluster_file_ops_directory_sync_calls) || 0) >= 1 and
           !Process.get(:cluster_file_ops_staging_directory_replacement_injected) do
        owned_path = source <> ".owned"
        File.rename!(source, owned_path)
        File.mkdir!(source)
        File.chmod!(source, 0o711)
        Process.put(:cluster_file_ops_foreign_staging_directory, destination)
        Process.put(:cluster_file_ops_owned_staging_directory, owned_path)
        Process.put(:cluster_file_ops_staging_directory_replacement_injected, true)
      end
    end

    def rm(path) do
      cond do
        output_parent_probe_cleanup_rm_failure?(path) ->
          Process.put(:cluster_file_ops_retained_output_parent_probe_path, path)
          {:error, :eio}

        staging_cleanup_rm_failure?(path) ->
          {:error, :eio}

        true ->
          File.rm(path)
      end
    end

    defp output_parent_probe_cleanup_rm_failure?(path) do
      basename = Path.basename(path)

      Process.get(:cluster_file_ops_fail_output_parent_probe_cleanup_rm) and
        String.starts_with?(basename, ".orchard-cluster-init-link-preflight-") and
        String.contains?(basename, ".quarantine-")
    end

    defp staging_cleanup_rm_failure?(path) do
      staging_path = Process.get(:cluster_file_ops_staging_path)

      is_binary(staging_path) and
        (path == staging_path or String.starts_with?(path, staging_path <> ".quarantine-")) and
        ((Process.get(:cluster_file_ops_fail_staging_cleanup_rm) and
            Process.get(:cluster_file_ops_descriptor_write_completed) == true) or
           (Process.get(:cluster_file_ops_fail_staging_cleanup_rm_before_write) and
              Process.get(:cluster_file_ops_descriptor_write_completed) != true))
    end

    def lstat(path) do
      cond do
        output_parent_probe_verification_failure?(path) ->
          Process.put(:cluster_file_ops_output_parent_probe_verification_failure_injected, true)
          Process.put(:cluster_file_ops_retained_output_parent_probe_path, path)
          {:error, :eio}

        vanish_output_path?(path) ->
          Process.put(:cluster_file_ops_vanish_injected, true)
          {:error, :enoent}

        true ->
          real_lstat(path)
      end
    end

    defp output_parent_probe_verification_failure?(path) do
      output_path = Process.get(:cluster_file_ops_output_path)

      Process.get(:cluster_file_ops_fail_output_parent_probe_verification) and
        is_binary(output_path) and
        Path.dirname(path) == Path.dirname(output_path) and
        String.starts_with?(
          Path.basename(path),
          ".orchard-cluster-init-link-preflight-"
        ) and
        !Process.get(:cluster_file_ops_output_parent_probe_verification_failure_injected)
    end

    defp vanish_output_path?(path) do
      injection_targets_reservation?(
        Process.get(:cluster_file_ops_vanish_output_path),
        path
      ) and
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
      injection_targets_reservation?(
        Process.get(:cluster_file_ops_drift_output_identity),
        path
      ) and
        !Process.get(:cluster_file_ops_identity_drift_injected)
    end

    defp injection_targets_reservation?(configured_path, actual_path) do
      is_binary(configured_path) and
        (configured_path == actual_path or
           (configured_path == Process.get(:cluster_file_ops_output_path) and
              actual_path == Process.get(:cluster_file_ops_staging_path)))
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
          record_opened_descriptor(file, path, modes)
          maybe_track_foreign_output_path(path, modes)

        {:error, _reason} ->
          :ok
      end

      result
    end

    defp record_opened_descriptor(file, path, modes) do
      role = if :exclusive in modes, do: :publication, else: :cleanup
      Process.put({:cluster_file_ops_descriptor_role, file}, role)

      if role == :publication do
        Process.put(:cluster_file_ops_reservation_opened, true)
        Process.put(:cluster_file_ops_staging_path, path)
      end

      maybe_retain_readable_creation_descriptor(path, role)
    end

    defp maybe_track_foreign_output_path(path, modes) do
      if :exclusive in modes and foreign_output_injection?() do
        Process.put(
          :cluster_file_ops_foreign_output_path,
          Process.get(:cluster_file_ops_output_path) || path
        )
      end
    end

    defp foreign_output_injection? do
      is_binary(Process.get(:cluster_file_ops_foreign_output_after_lstat)) or
        is_binary(Process.get(:cluster_file_ops_foreign_output_before_close))
    end

    defp maybe_retain_readable_creation_descriptor(path, :publication) do
      case Process.get(:cluster_file_ops_creation_attack_output_path) do
        output_path when is_binary(output_path) ->
          File.chmod!(path, 0o644)
          Process.put(:cluster_file_ops_creation_mode, Bitwise.band(File.stat!(path).mode, 0o777))

          case File.open(output_path, [:read, :binary]) do
            {:ok, attacker_io} ->
              Process.put(:cluster_file_ops_creation_attacker_io, attacker_io)

            {:error, _reason} ->
              :ok
          end

        _other ->
          :ok
      end
    end

    defp maybe_retain_readable_creation_descriptor(_path, _role), do: :ok

    def write(file, @descriptor_preflight_payload = contents) do
      if Process.get(:cluster_file_ops_fail_preflight_write) and
           !Process.get(:cluster_file_ops_preflight_write_failure_injected) do
        Process.put(:cluster_file_ops_preflight_write_failure_injected, true)
        {:error, :edquot}
      else
        result = IO.binwrite(file, contents)
        if result == :ok, do: Process.put(:cluster_file_ops_preflight_write_completed, true)
        result
      end
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

      result =
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

      maybe_create_foreign_output_after_stage_sync(role, result)
      result
    end

    defp maybe_create_foreign_output_after_stage_sync(:publication, :ok) do
      if Process.get(:cluster_file_ops_descriptor_write_completed) == true and
           is_binary(Process.get(:cluster_file_ops_foreign_output_after_stage_sync)) and
           !Process.get(:cluster_file_ops_stage_sync_race_injected) do
        result =
          File.write(
            Process.get(:cluster_file_ops_output_path),
            Process.get(:cluster_file_ops_foreign_output_after_stage_sync),
            [:exclusive]
          )

        Process.put(:cluster_file_ops_stage_sync_race_result, result)
        Process.put(:cluster_file_ops_stage_sync_race_injected, true)
      end
    end

    defp maybe_create_foreign_output_after_stage_sync(_role, _result), do: :ok

    def truncate(file) do
      if Process.get(:cluster_file_ops_fail_redaction_truncate) and
           Process.get(:cluster_file_ops_descriptor_write_completed) == true do
        {:error, :eio}
      else
        :file.truncate(file)
      end
    end

    def chmod(path, mode) do
      if staging_protection_target?(path, :cluster_file_ops_fail_staging_chmod) do
        Process.put(:cluster_file_ops_unprotected_staging_dir, path)
        {:error, :eio}
      else
        File.chmod(path, mode)
      end
    end

    def remove_acl(path) do
      if staging_protection_target?(path, :cluster_file_ops_fail_staging_acl_removal) do
        Process.put(:cluster_file_ops_unprotected_staging_dir, path)
        maybe_replace_unprotected_staging(path)
        {:error, :acl_removal_failed}
      else
        strip_acl(path)
      end
    end

    def acl_entries(path) do
      if output_parent_probe_acl_inspection_failure?(path) do
        Process.put(:cluster_file_ops_retained_output_parent_probe_path, path)
        {:error, :acl_inspection_failed}
      else
        case System.cmd("/bin/ls", ["-lde", path], stderr_to_stdout: true) do
          {output, 0} ->
            entries =
              output
              |> String.split("\n", trim: true)
              |> Enum.filter(&Regex.match?(~r/^\s+\d+:\s/, &1))

            {:ok, entries}

          {_output, _status} ->
            {:error, :acl_inspection_failed}
        end
      end
    end

    defp output_parent_probe_acl_inspection_failure?(path) do
      output_path = Process.get(:cluster_file_ops_output_path)

      Process.get(:cluster_file_ops_fail_output_parent_probe_acl_inspection) and
        is_binary(output_path) and
        Path.dirname(path) == Path.dirname(output_path) and
        String.starts_with?(
          Path.basename(path),
          ".orchard-cluster-init-link-preflight-"
        )
    end

    defp maybe_replace_unprotected_staging(path) do
      if Process.get(:cluster_file_ops_replace_unprotected_staging_before_cleanup) do
        File.rename!(path, path <> ".owned")
        File.mkdir!(path)
        File.write!(Path.join(path, "unrelated.txt"), "unrelated operator data")
      end
    end

    defp staging_protection_target?(path, key) do
      Process.get(key) == true and path == Process.get(:cluster_file_ops_staging_dir)
    end

    defp strip_acl(path) do
      case System.cmd("/bin/chmod", ["-N", path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {_output, _status} -> {:error, :acl_removal_failed}
      end
    end

    def sync_directory(_path) do
      if Process.get(:cluster_file_ops_descriptor_write_completed) == true,
        do: commit_directory_sync(),
        else: preflight_directory_sync()
    end

    defp preflight_directory_sync do
      calls = (Process.get(:cluster_file_ops_preflight_directory_sync_calls) || 0) + 1
      Process.put(:cluster_file_ops_preflight_directory_sync_calls, calls)

      if Process.get(:cluster_file_ops_fail_preflight_directory_sync),
        do: {:error, :eio},
        else: :ok
    end

    defp commit_directory_sync do
      call = (Process.get(:cluster_file_ops_directory_sync_calls) || 0) + 1
      Process.put(:cluster_file_ops_directory_sync_calls, call)

      if Process.get(:cluster_file_ops_fail_directory_sync_call) == call,
        do: {:error, :eio},
        else: :ok
    end

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

      case File.rename(path, path <> ".reserved-at-close") do
        :ok ->
          Process.put(:cluster_file_ops_foreign_output_moved_path, path <> ".reserved-at-close")

        {:error, :enoent} ->
          :ok
      end

      File.write!(path, Process.get(:cluster_file_ops_foreign_output_before_close), [:exclusive])
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
      assert decoded["contract_version"] == "orchard.cluster_management.cluster_init.v2"
      assert decoded["credential_authority"] == "committed_active"
      assert decoded["publication"] == "confirmed"
      assert decoded["containment"] == "not_required"
      assert decoded["warnings"] == []
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

    test "SPEC.md §7.4.4 protected output never exposes a readable final inode before chmod",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "protected-admin.json")

      {log, result, token, attacker_contents, creation_mode} =
        with_configurable_file_ops(
          [capture_token: true, creation_attack_output_path: output_path],
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
                     "protected-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}

            {
              log,
              result,
              Process.get(:cluster_file_ops_failed_token),
              read_retained_creation_descriptor(),
              Process.get(:cluster_file_ops_creation_mode)
            }
          end
        )

      assert {:ok, message} = result
      assert creation_mode == 0o644
      assert is_binary(token)
      refute is_binary(attacker_contents) and String.contains?(attacker_contents, token)
      refute message =~ token
      refute log =~ token
      assert token_occurrences(File.read!(output_path), token) == 1
    end

    @tag :macos
    test "SPEC.md §7.4.4 public init strips inherited non-owner read ACL before minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "acl-protected-admin.json")
      :ok = add_inheritable_read_acl(tmp_dir)
      assert acl_entries(tmp_dir) != []

      {stdout, stderr, log, halt_code} =
        run_public_cluster_init([
          "cluster",
          "init",
          "--output",
          output_path,
          "--json",
          "--client-name",
          "acl-protected-admin"
        ])

      credential = Jason.decode!(File.read!(output_path))
      token = Map.fetch!(credential, "api_token")

      assert halt_code == nil
      assert stderr == ""
      assert acl_entries(output_path) == []
      assert token_occurrences(File.read!(output_path), token) == 1
      assert residual_files(tmp_dir) == [output_path]
      refute stdout =~ token
      refute stderr =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
    end

    @tag :macos
    test "SPEC.md §7.4.4 public init rejects a parent ACL granting non-owner mutation",
         %{tmp_dir: tmp_dir} do
      assert_public_init_rejects_parent_acl(
        tmp_dir,
        "acl-mutation-admin",
        "everyone allow add_file,add_subdirectory,delete_child,file_inherit,directory_inherit"
      )
    end

    @tag :macos
    test "SPEC.md §7.4.4 public init rejects a parent ACL granting non-owner ownership control",
         %{tmp_dir: tmp_dir} do
      assert_public_init_rejects_parent_acl(
        tmp_dir,
        "acl-ownership-admin",
        "everyone allow chown,writesecurity,file_inherit,directory_inherit"
      )
    end

    test "SPEC.md §7.4.4 public init fails before minting when staging hard links are unsupported",
         %{tmp_dir: tmp_dir} do
      assert_public_init_preflight_fails(tmp_dir, "link-preflight-admin", fail_preflight_ln: true)
    end

    test "SPEC.md §7.4.4 public init fails before minting when the output parent denies links",
         %{tmp_dir: tmp_dir} do
      assert_public_init_preflight_fails(tmp_dir, "parent-link-preflight-admin",
        fail_output_parent_ln: true,
        expected_code: "output_parent_not_writable",
        expected_detail: "output_link_preflight: " <> to_string(:file.format_error(:eacces))
      )
    end

    test "SPEC.md §11.9 public init reports a retained output-parent probe before minting",
         %{tmp_dir: tmp_dir} do
      assert_public_init_reports_retained_parent_probe(
        tmp_dir,
        "parent-probe-cleanup-admin",
        fail_output_parent_probe_cleanup_rm: true
      )
    end

    test "SPEC.md §11.9 public init reports a parent probe whose verification fails",
         %{tmp_dir: tmp_dir} do
      assert_public_init_reports_retained_parent_probe(
        tmp_dir,
        "parent-probe-verification-admin",
        fail_output_parent_probe_verification: true
      )
    end

    test "SPEC.md §11.9 public init locates a parent probe despite persistent ACL failure",
         %{tmp_dir: tmp_dir} do
      assert_public_init_reports_retained_parent_probe(
        tmp_dir,
        "parent-probe-acl-inspection-admin",
        fail_output_parent_probe_acl_inspection: true
      )
    end

    test "SPEC.md §11.9 public init reports a parent probe whose quarantine rename fails",
         %{tmp_dir: tmp_dir} do
      assert_public_init_reports_retained_parent_probe(
        tmp_dir,
        "parent-probe-rename-admin",
        fail_output_parent_probe_quarantine_rename: true,
        expected_code: "output_parent_not_writable"
      )
    end

    test "SPEC.md §11.9 public init does not remap a retained parent probe to staging",
         %{tmp_dir: tmp_dir} do
      assert_public_init_reports_retained_parent_probe(
        tmp_dir,
        "parent-probe-compound-cleanup-admin",
        fail_output_parent_probe_cleanup_rm: true,
        fail_staging_directory_cleanup_rmdir_before_write: true,
        expect_retained_staging: true
      )
    end

    test "SPEC.md §7.4.4 public init fails before minting when a non-empty descriptor write fails",
         %{tmp_dir: tmp_dir} do
      assert_public_init_preflight_fails(tmp_dir, "write-preflight-admin",
        fail_preflight_write: true,
        expected_detail: "output_write_preflight: " <> to_string(:file.format_error(:edquot))
      )
    end

    test "SPEC.md §7.4.4 public init fails before minting when the parent directory sync fails",
         %{tmp_dir: tmp_dir} do
      assert_public_init_preflight_fails(tmp_dir, "directory-preflight-admin",
        fail_preflight_directory_sync: true,
        expected_detail: "output_directory_preflight: " <> to_string(:file.format_error(:eio))
      )
    end

    test "SPEC.md §7.4.4 public init preserves a probe replaced after verification and does not mint",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "probe-race-admin.json")
      foreign_contents = "unrelated probe data"

      {stdout, stderr, log, halt_code} =
        with_configurable_file_ops(
          [
            output_path: output_path,
            foreign_preflight_probe_before_quarantine: foreign_contents
          ],
          fn ->
            {stdout, stderr, log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "probe-race-admin"
              ])

            {stdout, stderr, log, halt_code}
          end
        )

      assert halt_code == 1
      assert stdout == ""
      assert Jason.decode!(stderr)["code"] == "output_reservation_failed"

      assert Enum.any?(
               residual_files(tmp_dir),
               &(File.read!(&1) == foreign_contents)
             )

      refute File.exists?(output_path)
      assert_no_credential_minted()
      assert Repo.aggregate(AuditLog, :count, :id) == 0
      refute stderr =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
    end

    test "SPEC.md §11.9 blocked probe restore names the final retained directory before minting",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "probe-retained-admin.json")
      foreign_contents = "unrelated probe data"
      blocker_contents = "unrelated blocking data"

      {stdout, stderr, log, halt_code, stale_child_path} =
        with_configurable_file_ops(
          [
            output_path: output_path,
            foreign_preflight_probe_before_quarantine: foreign_contents,
            block_probe_restore: blocker_contents
          ],
          fn ->
            {stdout, stderr, log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "probe-retained-admin"
              ])

            {stdout, stderr, log, halt_code,
             Process.get(:cluster_file_ops_foreign_preflight_probe_path)}
          end
        )

      assert halt_code == 1
      assert stdout == ""
      decoded = Jason.decode!(stderr)
      assert decoded["code"] == "output_reservation_failed"

      assert decoded["message"] =~ "foreign_path_retained"
      refute stderr =~ "unknown POSIX error"
      assert [retained_dir] = quarantined_directories(tmp_dir)
      assert decoded["message"] =~ retained_dir
      assert File.dir?(retained_dir)
      assert Enum.any?(residual_files(retained_dir), &(File.read!(&1) == foreign_contents))

      assert is_binary(stale_child_path)
      refute File.exists?(stale_child_path)
      refute stderr =~ stale_child_path

      refute File.exists?(output_path)
      assert_no_credential_minted()
      assert Repo.aggregate(AuditLog, :count, :id) == 0
      refute stderr =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
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
      decoded = Jason.decode!(message)
      assert decoded["code"] == "one_time_secret_output_unconfirmed"
      assert decoded["containment"] == "confirmed_logical"
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)
      assert residual_files(tmp_dir) == []

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert output_failed.payload["api_token_prefix"] =~ ~r/^orchard_kp_/
      refute inspect(Repo.all(AuditLog)) =~ token
    end

    test "SPEC.md §7.4.4 final installation is no-clobber after staged file sync",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "no-clobber-admin.json")
      foreign_contents = "unrelated operator data"

      {log, result, token, race_result} =
        with_configurable_file_ops(
          [
            capture_token: true,
            output_path: output_path,
            foreign_output_after_stage_sync: foreign_contents
          ],
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
                     "no-clobber-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}

            {
              log,
              result,
              Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_stage_sync_race_result)
            }
          end
        )

      assert {:error, message, 1} = result
      assert race_result == :ok
      assert File.read!(output_path) == foreign_contents
      assert is_binary(token)
      refute message =~ token
      refute log =~ token

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ token
      end
    end

    test "SPEC.md §7.4.4 final publication is unconfirmed when its directory sync fails",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "directory-sync-admin.json")

      {log, result, token, sync_calls} =
        with_configurable_file_ops(
          [capture_token: true, output_path: output_path, fail_directory_sync_call: 1],
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
                     "directory-sync-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}

            {
              log,
              result,
              Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_directory_sync_calls)
            }
          end
        )

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)
      assert decoded["contract_version"] == "orchard.cluster_management.cluster_init.v2"
      assert decoded["code"] == "one_time_secret_output_unconfirmed"
      assert decoded["credential_authority"] == "committed_active"
      assert decoded["publication"] == "unconfirmed"
      assert decoded["containment"] == "confirmed_logical"
      assert decoded["plaintext_may_remain"] == true
      assert decoded["recovery_required"] == true
      assert decoded["api_token_prefix"] =~ ~r/^orchard_kp_/
      assert decoded["message"] =~ "Plaintext may remain"
      refute Map.has_key?(decoded, "api_client_id")
      refute Map.has_key?(decoded, "api_token_id")
      assert sync_calls == 1
      assert is_binary(token)
      refute message =~ token
      refute log =~ token
      assert File.read!(output_path) == ""

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ token
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert_path_free_output_failure(output_failed, tmp_dir, token)
    end

    test "SPEC.md §7.4.4 staging-link removal is unconfirmed when its directory sync fails",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "staging-removal-sync-admin.json")

      {log, result, token, sync_calls} =
        with_configurable_file_ops(
          [capture_token: true, output_path: output_path, fail_directory_sync_call: 2],
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
                     "staging-removal-sync-admin"
                   ])}
                )
              end)

            assert_receive {:cluster_result, result}

            {
              log,
              result,
              Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_directory_sync_calls)
            }
          end
        )

      assert {:error, message, 1} = result
      assert sync_calls == 2
      assert is_binary(token)
      refute message =~ token
      refute log =~ token
      assert File.read!(output_path) == ""

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ token
      end

      assert Repo.aggregate(ServiceAccount, :count, :id) == 1
      assert Repo.aggregate(ApiKey, :count, :id) == 1
      assert Repo.aggregate(RoleBinding, :count, :id) == 1

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert_path_free_output_failure(output_failed, tmp_dir, token)
    end

    test "SPEC.md §10.2 descriptor sync failure returns failure with no plaintext residual",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "failed-sync-admin",
        capture_token: true,
        fail_sync_after_write: true,
        expected_output: :absent
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

    test "SPEC.md §7.4.4 same-UID staging replacement is preserved during cleanup",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "staging-race-admin.json")
      foreign_contents = "unrelated staging data"

      {stdout, stderr, log, halt_code, token, owned_basename} =
        with_configurable_file_ops(
          [
            capture_token: true,
            output_path: output_path,
            foreign_staging_before_cleanup: foreign_contents
          ],
          fn ->
            {stdout, stderr, log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "staging-race-admin"
              ])

            {
              stdout,
              stderr,
              log,
              halt_code,
              Process.get(:cluster_file_ops_failed_token),
              Path.basename(Process.get(:cluster_file_ops_owned_staging_moved_path))
            }
          end
        )

      assert halt_code == 1
      assert stdout == ""
      decoded = Jason.decode!(stderr)
      assert decoded["containment"] == "confirmed_logical"
      assert decoded["failure_category"] == "foreign_path_restored"
      refute inspect(decoded["cleanup_failures"]) =~ tmp_dir
      assert is_binary(token)

      residuals = residual_files(tmp_dir)

      assert Enum.any?(
               residuals,
               &(Path.basename(&1) == "credential" and File.read!(&1) == foreign_contents)
             )

      refute Enum.any?(residuals, &String.contains?(Path.basename(&1), "credential.quarantine-"))
      assert Enum.any?(residuals, &(Path.basename(&1) == owned_basename and File.read!(&1) == ""))
      assert File.read!(output_path) == ""
      refute stderr =~ token
      refute log =~ token

      for path <- residuals do
        refute File.read!(path) =~ token
      end

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert_path_free_output_failure(output_failed, tmp_dir, token)
    end

    test "SPEC.md §11.9 blocked foreign staging restore is retained and reported distinctly",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "blocked-restore-admin.json")
      foreign_contents = "unrelated staging data"
      blocker_contents = "unrelated blocking data"

      {stdout, stderr, log, halt_code, {token, stale_child_path}} =
        with_configurable_file_ops(
          [
            capture_token: true,
            output_path: output_path,
            foreign_staging_before_cleanup: foreign_contents,
            block_staging_restore: blocker_contents
          ],
          fn ->
            {stdout, stderr, log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "blocked-restore-admin"
              ])

            {stdout, stderr, log, halt_code,
             {Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_foreign_staging_path)}}
          end
        )

      assert halt_code == 1
      assert stdout == ""
      decoded = Jason.decode!(stderr)
      assert decoded["containment"] == "confirmed_logical"
      assert decoded["failure_category"] == "foreign_path_retained"
      refute inspect(decoded["cleanup_failures"]) =~ tmp_dir
      assert is_binary(token)

      assert [retained_dir] = quarantined_directories(tmp_dir)
      assert decoded["message"] =~ "foreign_path_retained"
      assert decoded["message"] =~ retained_dir
      refute stderr =~ "unknown POSIX error"
      assert File.dir?(retained_dir)

      assert is_binary(stale_child_path)
      refute File.exists?(stale_child_path)
      refute stderr =~ stale_child_path

      residuals = residual_files(tmp_dir)

      assert Enum.any?(
               residuals,
               &(String.contains?(Path.basename(&1), "credential.quarantine-") and
                   File.read!(&1) == foreign_contents)
             )

      assert Enum.any?(
               residuals,
               &(Path.basename(&1) == "credential" and File.read!(&1) == blocker_contents)
             )

      assert File.read!(output_path) == ""
      refute stderr =~ token
      refute log =~ token

      for path <- residuals do
        refute File.read!(path) =~ token
      end

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert_path_free_output_failure(output_failed, tmp_dir, token)
    end

    test "SPEC.md §7.4.4 public init preserves a replaced staging directory",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "staging-directory-race-admin.json")

      {stdout, stderr, log, halt_code, token, foreign_dir, owned_dir} =
        with_configurable_file_ops(
          [
            capture_token: true,
            output_path: output_path,
            replace_staging_directory_before_cleanup: true
          ],
          fn ->
            {stdout, stderr, log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "staging-directory-race-admin"
              ])

            {
              stdout,
              stderr,
              log,
              halt_code,
              Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_foreign_staging_directory),
              Process.get(:cluster_file_ops_owned_staging_directory)
            }
          end
        )

      assert halt_code == 1
      assert stdout == ""
      decoded = Jason.decode!(stderr)
      assert decoded["containment"] == "confirmed_logical"
      assert decoded["failure_category"] == "foreign_directory_quarantined"
      refute inspect(decoded["cleanup_failures"]) =~ tmp_dir
      assert is_binary(token)
      assert File.dir?(foreign_dir)
      assert Bitwise.band(File.stat!(foreign_dir).mode, 0o777) == 0o711
      assert File.dir?(owned_dir)
      assert File.read!(output_path) == ""
      refute stderr =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"

      for path <- residual_files(tmp_dir) do
        refute File.read!(path) =~ token
      end

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      assert_path_free_output_failure(output_failed, tmp_dir, token)
    end

    test "SPEC.md §7.4.4 public init never removes a foreign directory after failed mkdir",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "failed-mkdir-admin.json")

      {stdout, stderr, log, halt_code, foreign_dir} =
        with_configurable_file_ops([fail_mkdir_after_foreign_create: true], fn ->
          {stdout, stderr, log, halt_code} =
            run_public_cluster_init([
              "cluster",
              "init",
              "--output",
              output_path,
              "--json",
              "--client-name",
              "failed-mkdir-admin"
            ])

          {
            stdout,
            stderr,
            log,
            halt_code,
            Process.get(:cluster_file_ops_foreign_failed_mkdir_directory)
          }
        end)

      assert halt_code == 1
      assert stdout == ""
      assert Jason.decode!(stderr)["code"] == "output_reservation_failed"
      assert File.dir?(foreign_dir)
      assert Bitwise.band(File.stat!(foreign_dir).mode, 0o777) == 0o711
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(RoleBinding, :count, :id) == 0
      refute stderr =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
    end

    test "SPEC.md §11.9 public init removes its staging namespace after ACL removal fails",
         %{tmp_dir: tmp_dir} do
      assert_unprotected_staging_is_removed(tmp_dir, "acl-cleanup-admin",
        fail_staging_acl_removal: true
      )
    end

    test "SPEC.md §11.9 public init removes its staging namespace after chmod fails",
         %{tmp_dir: tmp_dir} do
      assert_unprotected_staging_is_removed(tmp_dir, "chmod-cleanup-admin",
        fail_staging_chmod: true
      )
    end

    test "SPEC.md §11.9 public init retains an unprotected staging namespace it does not own",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "unprotected-foreign-admin.json")

      {stderr, halt_code, staging_dir} =
        with_configurable_file_ops(
          [fail_staging_acl_removal: true, replace_unprotected_staging_before_cleanup: true],
          fn ->
            {_stdout, stderr, _log, halt_code} =
              run_public_cluster_init([
                "cluster",
                "init",
                "--output",
                output_path,
                "--json",
                "--client-name",
                "unprotected-foreign-admin"
              ])

            {stderr, halt_code, Process.get(:cluster_file_ops_unprotected_staging_dir)}
          end
        )

      assert halt_code == 1
      decoded = Jason.decode!(stderr)
      assert decoded["code"] == "output_reservation_failed"
      assert decoded["cleanup_unresolved"] =~ "staging_cleanup"
      assert File.dir?(staging_dir)
      assert File.read!(Path.join(staging_dir, "unrelated.txt")) == "unrelated operator data"
      refute File.exists?(output_path)
      assert_no_credential_minted()
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 descriptor close failure leaves no plaintext",
         %{tmp_dir: tmp_dir} do
      assert_failed_delivery_has_no_plaintext(
        tmp_dir,
        "close-failure-admin",
        capture_token: true,
        fail_close_after_write: true,
        expected_output: :absent
      )
    end

    test "SPEC.md §10.2 recovery descriptor close anomaly preserves committed output once",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "cleanup-close-anomaly-admin.json")

      {log, result, token, sync_calls} =
        with_configurable_file_ops(
          [
            capture_token: true,
            output_path: output_path,
            fail_cleanup_close_after_commit: true
          ],
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

            {
              log,
              result,
              Process.get(:cluster_file_ops_failed_token),
              Process.get(:cluster_file_ops_directory_sync_calls)
            }
          end
        )

      assert {:ok, output} = result
      assert is_binary(token)
      decoded = Jason.decode!(output)
      assert decoded["api_token_prefix"] =~ ~r/^orchard_kp_/
      assert decoded["credential_authority"] == "committed_active"
      assert decoded["publication"] == "confirmed"
      assert decoded["containment"] == "not_required"
      assert decoded["warnings"] == ["cleanup_descriptor_close_unconfirmed"]
      assert sync_calls == 2
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
      refute message =~ "Retained output reservation"
      refute File.exists?(second_output)
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
      refute Map.has_key?(payload, "output_reservation_retained")
      refute message =~ first_token
      refute log =~ first_token
      refute File.exists?(second_output)

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
      refute File.exists?(output_path)

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
      refute File.exists?(output_path)

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
      refute File.exists?(output_path)

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
      refute File.exists?(output_path)
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
        with_configurable_file_ops(
          [output_path: output_path, drift_output_identity: output_path],
          fn ->
            ClusterCmd.run(["init", "--output", output_path, "--json"])
          end
        )

      assert {:error, message, 1} = result
      decoded = Jason.decode!(message)

      assert decoded["code"] == "output_path_identity_changed"
      assert decoded["message"] =~ "identity changed during reservation"
      refute message =~ "orchard_sk_"
      refute File.exists?(output_path)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 reservation-stage cleanup failure surfaces top-level cleanup_unresolved",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "reservation-cleanup-admin.json")

      {log, result} =
        with_configurable_file_ops(
          [
            fail_cleanup_preflight_sync: true,
            fail_staging_cleanup_rm_before_write: true
          ],
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
      assert decoded["cleanup_unresolved"] =~ "staging_metadata_cleanup"
      assert decoded["cleanup_unresolved"] =~ "staging_path"
      refute message =~ "orchard_sk_"
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)

      residuals = residual_files(tmp_dir)
      assert length(residuals) == 1
      assert File.read!(hd(residuals)) == ""
      assert Bitwise.band(File.stat!(hd(residuals)).mode, 0o777) == 0o600
      assert Repo.aggregate(ServiceAccount, :count, :id) == 0
      assert Repo.aggregate(ApiKey, :count, :id) == 0
      assert Repo.aggregate(AuditLog, :count, :id) == 0
    end

    test "SPEC.md §10.2 unredactable plaintext renders qualified non-secret operator guidance",
         %{tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "unredactable-admin.json")

      {log, result, token} =
        with_configurable_file_ops(
          [
            capture_token: true,
            fail_sync_after_write: true,
            fail_redaction_truncate: true,
            fail_staging_cleanup_rm: true
          ],
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

      assert decoded["contract_version"] == "orchard.cluster_management.cluster_init.v2"
      assert decoded["code"] == "one_time_secret_containment_unresolved"
      assert decoded["credential_authority"] == "committed_active"
      assert decoded["publication"] == "unconfirmed"
      assert decoded["containment"] == "unresolved"
      assert decoded["plaintext_may_remain"] == true
      assert decoded["recovery_required"] == true
      assert decoded["api_token_prefix"] =~ ~r/^orchard_kp_/
      assert decoded["message"] =~ "Manual containment required"
      assert decoded["message"] =~ "protected staging namespace"
      assert decoded["message"] =~ "may name unrelated data"
      assert decoded["message"] =~ tmp_dir
      assert decoded["message"] =~ ~r/orchard_kp_/
      assert decoded["message"] =~ "plaintext_redaction"
      refute Map.has_key?(decoded, "api_client_id")
      refute Map.has_key?(decoded, "api_token_id")
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)

      residuals = residual_files(tmp_dir)
      assert length(residuals) == 1
      assert Enum.any?(residuals, &(File.read!(&1) =~ token))

      output_failed = Repo.get_by!(AuditLog, action: "cluster_admin_bootstrap.output_failed")
      persisted_reason = output_failed.payload["error_summary"]["reason"]

      assert persisted_reason =~ "containment_unresolved:plaintext_redaction=eio"
      assert persisted_reason =~ "staging_metadata_cleanup=staging_path.eio"

      staging_cleanup =
        Enum.find(decoded["cleanup_failures"], &(&1["step"] == "staging_metadata_cleanup"))

      assert staging_cleanup["category"] =~ "staging_path.eio"
      refute staging_cleanup["category"] =~ tmp_dir

      assert_path_free_output_failure(
        output_failed,
        tmp_dir,
        token,
        "one_time_secret_containment_unresolved"
      )

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

      assert decoded["code"] == "one_time_secret_output_unconfirmed"
      assert decoded["credential_authority"] == "committed_active"
      assert decoded["publication"] == "unconfirmed"
      assert decoded["containment"] == "confirmed_logical"
      assert decoded["message"] =~ "output_parent_hierarchy_untrusted"
      refute Map.has_key?(decoded, "output_reservation_retained")
      assert decoded["message"] =~ "Logical plaintext containment was confirmed"
      refute message =~ token
      refute log =~ token
      refute log =~ "orchard_sk_"
      refute File.exists?(output_path)

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
        with_configurable_file_ops(
          [output_path: output_path, vanish_output_path: output_path],
          fn ->
            ClusterCmd.run(["init", "--output", output_path, "--json"])
          end
        )

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

  defp with_configurable_file_ops(settings, fun) do
    previous_impl = Application.get_env(:orchard_cli, :cluster_file_ops)

    process_settings = %{
      cluster_file_ops_capture_token: Keyword.get(settings, :capture_token, false),
      cluster_file_ops_creation_attack_output_path: settings[:creation_attack_output_path],
      cluster_file_ops_creation_attacker_io: nil,
      cluster_file_ops_creation_mode: nil,
      cluster_file_ops_output_path: settings[:output_path],
      cluster_file_ops_foreign_output_after_lstat: settings[:foreign_output_after_lstat],
      cluster_file_ops_foreign_output_before_close: settings[:foreign_output_before_close],
      cluster_file_ops_foreign_output_after_stage_sync:
        settings[:foreign_output_after_stage_sync],
      cluster_file_ops_foreign_staging_before_cleanup: settings[:foreign_staging_before_cleanup],
      cluster_file_ops_fail_close_after_write:
        Keyword.get(settings, :fail_close_after_write, false),
      cluster_file_ops_fail_close_before_write:
        Keyword.get(settings, :fail_close_before_write, false),
      cluster_file_ops_fail_cleanup_close_after_commit:
        Keyword.get(settings, :fail_cleanup_close_after_commit, false),
      cluster_file_ops_fail_write_after_persist:
        Keyword.get(settings, :fail_write_after_persist, false),
      cluster_file_ops_fail_preflight_write: Keyword.get(settings, :fail_preflight_write, false),
      cluster_file_ops_preflight_write_failure_injected: nil,
      cluster_file_ops_preflight_write_completed: nil,
      cluster_file_ops_fail_sync_after_write:
        Keyword.get(settings, :fail_sync_after_write, false),
      cluster_file_ops_fail_cleanup_preflight_sync:
        Keyword.get(settings, :fail_cleanup_preflight_sync, false),
      cluster_file_ops_fail_redaction_truncate:
        Keyword.get(settings, :fail_redaction_truncate, false),
      cluster_file_ops_fail_staging_cleanup_rm:
        Keyword.get(settings, :fail_staging_cleanup_rm, false),
      cluster_file_ops_fail_staging_cleanup_rm_before_write:
        Keyword.get(settings, :fail_staging_cleanup_rm_before_write, false),
      cluster_file_ops_fail_staging_directory_cleanup_rmdir_before_write:
        Keyword.get(settings, :fail_staging_directory_cleanup_rmdir_before_write, false),
      cluster_file_ops_retained_staging_directory: nil,
      cluster_file_ops_drift_output_identity: settings[:drift_output_identity],
      cluster_file_ops_identity_drift_injected: nil,
      cluster_file_ops_vanish_output_path: settings[:vanish_output_path],
      cluster_file_ops_vanish_injected: nil,
      cluster_file_ops_reservation_opened: nil,
      cluster_file_ops_staging_path: nil,
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
      cluster_file_ops_stage_sync_race_injected: nil,
      cluster_file_ops_stage_sync_race_result: nil,
      cluster_file_ops_staging_replacement_injected: nil,
      cluster_file_ops_foreign_staging_path: nil,
      cluster_file_ops_owned_staging_moved_path: nil,
      cluster_file_ops_block_staging_restore: settings[:block_staging_restore],
      cluster_file_ops_blocked_restore_path: nil,
      cluster_file_ops_fail_staging_acl_removal:
        Keyword.get(settings, :fail_staging_acl_removal, false),
      cluster_file_ops_fail_staging_chmod: Keyword.get(settings, :fail_staging_chmod, false),
      cluster_file_ops_replace_unprotected_staging_before_cleanup:
        Keyword.get(settings, :replace_unprotected_staging_before_cleanup, false),
      cluster_file_ops_unprotected_staging_dir: nil,
      cluster_file_ops_staging_dir: nil,
      cluster_file_ops_replace_staging_directory_before_cleanup:
        Keyword.get(settings, :replace_staging_directory_before_cleanup, false),
      cluster_file_ops_staging_directory_replacement_injected: nil,
      cluster_file_ops_foreign_staging_directory: nil,
      cluster_file_ops_owned_staging_directory: nil,
      cluster_file_ops_fail_mkdir_after_foreign_create:
        Keyword.get(settings, :fail_mkdir_after_foreign_create, false),
      cluster_file_ops_foreign_failed_mkdir_directory: nil,
      cluster_file_ops_fail_directory_sync_call: settings[:fail_directory_sync_call],
      cluster_file_ops_directory_sync_calls: nil,
      cluster_file_ops_fail_preflight_ln: Keyword.get(settings, :fail_preflight_ln, false),
      cluster_file_ops_fail_output_parent_ln:
        Keyword.get(settings, :fail_output_parent_ln, false),
      cluster_file_ops_fail_output_parent_probe_cleanup_rm:
        Keyword.get(settings, :fail_output_parent_probe_cleanup_rm, false),
      cluster_file_ops_fail_output_parent_probe_acl_inspection:
        Keyword.get(settings, :fail_output_parent_probe_acl_inspection, false),
      cluster_file_ops_fail_output_parent_probe_quarantine_rename:
        Keyword.get(settings, :fail_output_parent_probe_quarantine_rename, false),
      cluster_file_ops_fail_output_parent_probe_verification:
        Keyword.get(settings, :fail_output_parent_probe_verification, false),
      cluster_file_ops_output_parent_probe_verification_failure_injected: nil,
      cluster_file_ops_retained_output_parent_probe_path: nil,
      cluster_file_ops_preflight_link_calls: nil,
      cluster_file_ops_foreign_preflight_probe_before_quarantine:
        settings[:foreign_preflight_probe_before_quarantine],
      cluster_file_ops_block_probe_restore: settings[:block_probe_restore],
      cluster_file_ops_blocked_probe_restore_path: nil,
      cluster_file_ops_preflight_probe_replacement_injected: nil,
      cluster_file_ops_owned_preflight_probe_path: nil,
      cluster_file_ops_foreign_preflight_probe_path: nil,
      cluster_file_ops_fail_preflight_directory_sync:
        Keyword.get(settings, :fail_preflight_directory_sync, false),
      cluster_file_ops_preflight_directory_sync_calls: nil,
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
      with_configurable_file_ops(Keyword.put(settings, :output_path, output_path), fn ->
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
    assert decoded["contract_version"] == "orchard.cluster_management.cluster_init.v2"
    assert decoded["code"] == "one_time_secret_output_unconfirmed"
    assert decoded["credential_authority"] == "committed_active"
    assert decoded["publication"] == "unconfirmed"
    assert decoded["containment"] == "confirmed_logical"
    assert decoded["plaintext_may_remain"] == true
    assert decoded["recovery_required"] == true
    refute Map.has_key?(decoded, "output_reservation_retained")
    assert decoded["message"] =~ "Logical plaintext containment was confirmed"
    assert decoded["message"] =~ "may name unrelated data"
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

  defp assert_public_init_rejects_parent_acl(tmp_dir, client_name, acl) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")
    :ok = add_acl(tmp_dir, acl)
    assert acl_entries(tmp_dir) != []

    {stdout, stderr, log, halt_code} =
      run_public_cluster_init([
        "cluster",
        "init",
        "--output",
        output_path,
        "--json",
        "--client-name",
        client_name
      ])

    assert halt_code == 1
    assert stdout == ""
    assert Jason.decode!(stderr)["code"] == "output_parent_not_writable"
    refute File.exists?(output_path)
    assert_no_credential_minted()
    refute stderr =~ "orchard_sk_"
    refute log =~ "orchard_sk_"
  end

  defp assert_public_init_preflight_fails(tmp_dir, client_name, settings) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")
    foreign_path = Path.join(tmp_dir, "#{client_name}-unrelated.txt")
    foreign_contents = "unrelated operator data"
    File.write!(foreign_path, foreign_contents)

    {stdout, stderr, log, halt_code} =
      with_configurable_file_ops(Keyword.put(settings, :output_path, output_path), fn ->
        run_public_cluster_init([
          "cluster",
          "init",
          "--output",
          output_path,
          "--json",
          "--client-name",
          client_name
        ])
      end)

    assert halt_code == 1
    assert stdout == ""
    decoded = Jason.decode!(stderr)
    assert decoded["code"] == Keyword.get(settings, :expected_code, "output_reservation_failed")
    assert_error_detail(decoded["message"], settings[:expected_detail])
    refute stderr =~ "unknown POSIX error"
    refute File.exists?(output_path)
    assert File.read!(foreign_path) == foreign_contents
    assert residual_files(tmp_dir) == [foreign_path]
    assert_no_credential_minted()
    assert Repo.aggregate(AuditLog, :count, :id) == 0
    refute stderr =~ "orchard_sk_"
    refute log =~ "orchard_sk_"
  end

  defp assert_public_init_reports_retained_parent_probe(tmp_dir, client_name, settings) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")

    file_ops_settings =
      settings
      |> Keyword.drop([:expect_retained_staging, :expected_code])
      |> Keyword.put(:output_path, output_path)

    {stdout, stderr, log, halt_code, retained_probe_path, retained_staging_directory} =
      with_configurable_file_ops(file_ops_settings, fn ->
        {stdout, stderr, log, halt_code} =
          run_public_cluster_init([
            "cluster",
            "init",
            "--output",
            output_path,
            "--json",
            "--client-name",
            client_name
          ])

        {stdout, stderr, log, halt_code,
         Process.get(:cluster_file_ops_retained_output_parent_probe_path),
         Process.get(:cluster_file_ops_retained_staging_directory)}
      end)

    assert halt_code == 1
    assert stdout == ""
    decoded = Jason.decode!(stderr)
    assert decoded["code"] == Keyword.get(settings, :expected_code, "output_reservation_failed")
    assert is_binary(retained_probe_path)
    assert decoded["message"] =~ retained_probe_path
    assert File.read!(retained_probe_path) == ""
    assert_retained_staging_directory(retained_staging_directory, settings)
    refute stderr =~ "unknown POSIX error"
    refute File.exists?(output_path)
    assert_no_credential_minted()
    assert Repo.aggregate(AuditLog, :count, :id) == 0
    refute stderr =~ "orchard_sk_"
    refute log =~ "orchard_sk_"
  end

  defp assert_retained_staging_directory(path, settings) do
    if Keyword.get(settings, :expect_retained_staging, false) do
      assert is_binary(path)
      assert File.dir?(path)
    else
      assert is_nil(path)
    end
  end

  defp assert_error_detail(_message, nil), do: :ok
  defp assert_error_detail(message, detail), do: assert(message =~ detail)

  defp assert_unprotected_staging_is_removed(tmp_dir, client_name, settings) do
    output_path = Path.join(tmp_dir, "#{client_name}.json")

    {stdout, stderr, log, halt_code, staging_dir} =
      with_configurable_file_ops(settings, fn ->
        {stdout, stderr, log, halt_code} =
          run_public_cluster_init([
            "cluster",
            "init",
            "--output",
            output_path,
            "--json",
            "--client-name",
            client_name
          ])

        {stdout, stderr, log, halt_code, Process.get(:cluster_file_ops_unprotected_staging_dir)}
      end)

    assert halt_code == 1
    assert stdout == ""
    decoded = Jason.decode!(stderr)
    assert decoded["code"] == "output_reservation_failed"
    refute Map.has_key?(decoded, "cleanup_unresolved")
    assert is_binary(staging_dir)
    refute File.exists?(staging_dir)
    refute File.exists?(output_path)
    assert File.ls!(tmp_dir) == []
    assert_no_credential_minted()
    assert Repo.aggregate(AuditLog, :count, :id) == 0
    refute stderr =~ "orchard_sk_"
    refute log =~ "orchard_sk_"
  end

  defp assert_no_credential_minted do
    assert Repo.aggregate(ServiceAccount, :count, :id) == 0
    assert Repo.aggregate(ApiKey, :count, :id) == 0
    assert Repo.aggregate(RoleBinding, :count, :id) == 0
  end

  defp assert_path_free_output_failure(
         output_failed,
         tmp_dir,
         token,
         expected_code \\ "one_time_secret_output_unconfirmed"
       ) do
    persisted_reason = output_failed.payload["error_summary"]["reason"]

    assert persisted_reason =~ expected_code <> ":"
    assert output_failed.payload["error_summary"]["api_token_prefix"] =~ ~r/^orchard_kp_/
    refute persisted_reason =~ tmp_dir
    refute persisted_reason =~ token
    refute persisted_reason =~ "orchard_sk_"
    refute persisted_reason =~ "may remain occupied"
    refute persisted_reason =~ "Manual containment"
  end

  defp read_retained_creation_descriptor do
    case Process.get(:cluster_file_ops_creation_attacker_io) do
      nil ->
        :not_opened

      io ->
        {:ok, 0} = :file.position(io, :bof)
        contents = IO.binread(io, :eof)
        :ok = File.close(io)
        contents
    end
  end

  defp run_public_cluster_init(args) do
    caller = self()
    log = capture_log(fn -> capture_public_cli_io(args, caller) end)

    assert_receive {:cluster_stdout, stdout}
    assert_receive {:cluster_stderr, stderr}

    halt_code =
      receive do
        {:cluster_halt, code} -> code
      after
        0 -> nil
      end

    {stdout, stderr, log, halt_code}
  end

  defp capture_public_cli_io(args, caller) do
    stderr = capture_io(:stderr, fn -> capture_public_cli_stdout(args, caller) end)
    send(caller, {:cluster_stderr, stderr})
  end

  defp capture_public_cli_stdout(args, caller) do
    stdout =
      capture_io(fn ->
        :ok = OrchardCLI.main(args, &send(caller, {:cluster_halt, &1}))
      end)

    send(caller, {:cluster_stdout, stdout})
  end

  defp add_inheritable_read_acl(path) do
    acl =
      "everyone allow read,readattr,readextattr,readsecurity,file_inherit,directory_inherit"

    add_acl(path, acl)
  end

  defp add_acl(path, acl) do
    case System.cmd("/bin/chmod", ["+a", acl, path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("failed to configure test ACL (#{status}): #{output}")
    end
  end

  defp acl_entries(path) do
    case System.cmd("/bin/ls", ["-lde", path], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r/^\s+\d+:\s/, &1))

      {output, status} ->
        flunk("failed to inspect test ACL (#{status}): #{output}")
    end
  end

  defp assert_output_state(output_path, :absent), do: refute(File.exists?(output_path))
  defp assert_output_state(output_path, contents), do: assert(File.read!(output_path) == contents)

  defp quarantined_directories(tmp_dir) do
    tmp_dir
    |> File.ls!()
    |> Enum.map(&Path.join(tmp_dir, &1))
    |> Enum.filter(&(File.dir?(&1) and String.contains?(Path.basename(&1), ".quarantine-")))
    |> Enum.sort()
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
