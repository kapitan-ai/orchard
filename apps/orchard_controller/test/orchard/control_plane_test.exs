defmodule Orchard.ControlPlaneTest do
  use ExUnit.Case, async: false

  alias Orchard.ClusterManagement.HALiteStatus
  alias Orchard.ControlPlane

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

  describe "read_only_status/0" do
    test "SPEC HA-lite Status Is Read-Only reports standby write-path behavior when standby is directly addressed" do
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

      status = ControlPlane.read_only_status()

      assert %HALiteStatus{} = status
      assert status.deployment_mode == "ha_lite"
      assert status.this_controller_identity == "controller-a"
      assert status.controller_role == "standby"
      assert status.leader_identity == "controller-b"
      assert status.advisory_lock_status == "not_held"
      assert status.lock_age_ms == 1_200
      assert status.last_renewed_at == ~U[2026-07-01 00:00:00Z]
      assert status.standby_write_path_behavior == "writes_return_503_controller_standby"
      assert status.last_observed_leadership_error == nil
    end

    test "SPEC Leadership status is unavailable when advisory-lock status cannot be read" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        ha_lite_status_provider: fn -> raise DBConnection.ConnectionError, message: "db down" end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "ha_lite"
      assert status.controller_role == "leader"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == nil
      assert status.advisory_lock_status == "unavailable"
      assert status.lock_age_ms == nil
      assert status.last_renewed_at == nil
      assert status.standby_write_path_behavior == "writes_allowed_when_authorized"
      assert status.last_observed_leadership_error =~ "db down"
    end

    test "SPEC Leadership status is unknown when no advisory-lock reader is configured" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a"
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "ha_lite"
      assert status.controller_role == "leader"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == nil
      assert status.advisory_lock_status == "unknown"
      assert status.last_observed_leadership_error == nil
    end
  end
end
