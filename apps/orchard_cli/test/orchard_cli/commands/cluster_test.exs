defmodule OrchardCLI.Commands.ClusterTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.{ApiKey, AuditLog, RoleBinding, ServiceAccount}
  alias Orchard.Repo
  alias OrchardCLI.Commands.Cluster, as: ClusterCmd

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

      assert {:ok, message} =
               ClusterCmd.run([
                 "init",
                 "--output",
                 output_path,
                 "--json",
                 "--client-name",
                 "json-admin"
               ])

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
      assert token =~ "orch_"
      refute message =~ token
      assert token_occurrences(File.read!(output_path), token) == 1
    end

    test "SPEC.md §11.9 force-new-admin requires yes and then mints recovery additively", %{
      tmp_dir: tmp_dir
    } do
      first_output = Path.join(tmp_dir, "first-admin.json")
      blocked_output = Path.join(tmp_dir, "blocked-recovery.json")
      recovery_output = Path.join(tmp_dir, "recovery-admin.json")

      assert {:ok, _message} = ClusterCmd.run(["init", "--output", first_output])

      assert {:error, blocked_message, 2} =
               ClusterCmd.run(["init", "--output", blocked_output, "--force-new-admin"])

      assert blocked_message =~ "--force-new-admin requires --yes"
      refute File.exists?(blocked_output)
      assert Repo.aggregate(ServiceAccount, :count, :id) == 1

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

      assert recovery_message =~ "Recovery credential: yes"
      refute recovery_message =~ token
      assert Repo.aggregate(ServiceAccount, :count, :id) == 2
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
end
