defmodule OrchardCLI.Commands.ClusterTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.Commands.Cluster, as: ClusterCmd

  setup do
    previous = Application.get_env(:orchard_controller, :control_plane)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous)
      end
    end)

    :ok
  end

  describe "help and usage" do
    test "group usage includes init and status" do
      assert {:error, message, 1} = ClusterCmd.run([])

      assert message =~ "orchardctl cluster"
      assert message =~ "cluster init"
      assert message =~ "cluster status"
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

  describe "status" do
    test "SPEC CLI/Console parity emits read-only HA-lite JSON status" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        ha_lite_status_provider: fn ->
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
               "deployment_mode" => "ha_lite",
               "controller_role" => "standby",
               "advisory_lock_status" => "not_held"
             }

      assert decoded["ha_lite"]["object"] == "cluster_management.ha_lite_status"
      assert decoded["ha_lite"]["deployment_mode"] == "ha_lite"
      assert decoded["ha_lite"]["this_controller_identity"] == "controller-a"
      assert decoded["ha_lite"]["controller_role"] == "standby"
      assert decoded["ha_lite"]["leader_identity"] == "controller-b"
      assert decoded["ha_lite"]["advisory_lock_status"] == "not_held"
      assert decoded["ha_lite"]["lock_age_ms"] == 1_200
      assert decoded["ha_lite"]["last_renewed_at"] == "2026-07-01T00:00:00Z"

      assert decoded["ha_lite"]["standby_write_path_behavior"] ==
               "writes_return_503_controller_standby"

      assert decoded["ha_lite"]["last_observed_leadership_error"] == nil
    end

    test "human output explains directly addressed standby write paths without failover actions" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        ha_lite_status_provider: fn -> %{advisory_lock_status: :unknown} end
      )

      assert {:ok, output} = ClusterCmd.run(["status"])

      assert output =~ "HA-lite: standby"
      assert output =~ "Deployment: ha lite"
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
               "deployment_mode" => "ha_lite",
               "controller_role" => "unknown",
               "advisory_lock_status" => "unknown"
             }

      assert decoded["ha_lite"]["controller_role"] == "unknown"
      assert decoded["ha_lite"]["leader_identity"] == nil
      assert decoded["ha_lite"]["standby_write_path_behavior"] == "unknown"
    end
  end
end
