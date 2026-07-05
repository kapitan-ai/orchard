defmodule Orchard.ControlPlaneTest do
  use ExUnit.Case, async: false

  alias Orchard.ClusterManagement.ControlPlaneStatus
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
    test "SPEC Control-Plane Status Is Read-Only reports standby write-path behavior when standby is directly addressed" do
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

      status = ControlPlane.read_only_status()

      assert %ControlPlaneStatus{} = status
      assert status.deployment_mode == "active_standby"
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
        control_plane_status_provider: fn ->
          raise DBConnection.ConnectionError,
            message: "password authentication failed for user orchard_admin at db.internal:5432"
        end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "unknown"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == nil
      assert status.advisory_lock_status == "unavailable"
      assert status.lock_age_ms == nil
      assert status.last_renewed_at == nil
      assert status.standby_write_path_behavior == "unknown"

      assert status.last_observed_leadership_error ==
               "advisory_lock_read_failed: db_connection_error"

      refute status.last_observed_leadership_error =~ "orchard_admin"
      refute status.last_observed_leadership_error =~ "db.internal"
    end

    test "SPEC Leadership status is unknown when no advisory-lock reader is configured" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a"
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "unknown"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == nil
      assert status.advisory_lock_status == "unknown"
      assert status.standby_write_path_behavior == "unknown"
      assert status.last_observed_leadership_error == nil
    end

    test "SPEC Leadership status reports leader only when advisory lock is held" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-a",
            advisory_lock_status: :held,
            lock_age_ms: 400,
            last_renewed_at: ~U[2026-07-01 00:00:00Z]
          }
        end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "leader"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == "controller-a"
      assert status.advisory_lock_status == "held"
      assert status.standby_write_path_behavior == "writes_allowed_when_authorized"
    end

    test "SPEC Leadership status ignores provider attempts to override local role metadata" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            deployment_mode: "active_standby",
            this_controller_identity: "provider-controller",
            controller_role: "leader",
            leader_identity: "controller-b",
            advisory_lock_status: "not_held",
            standby_write_path_behavior: "writes_allowed_when_authorized"
          }
        end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "unknown"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == "controller-b"
      assert status.advisory_lock_status == "not_held"
      assert status.standby_write_path_behavior == "unknown"
    end

    test "SPEC Leadership status is unavailable when provider emits out-of-vocabulary lock status" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-a",
            advisory_lock_status: "flaky"
          }
        end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "unknown"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == nil
      assert status.advisory_lock_status == "unavailable"
      assert status.standby_write_path_behavior == "unknown"

      assert status.last_observed_leadership_error ==
               "advisory_lock_read_failed: invalid_provider_status"
    end

    test "SPEC Leadership status sanitizes provider-returned leadership error into a stable reason" do
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

      status = ControlPlane.read_only_status()

      assert status.advisory_lock_status == "not_held"
      assert status.leader_identity == "controller-b"

      assert status.last_observed_leadership_error ==
               "advisory_lock_read_failed: provider_reported_error"

      refute status.last_observed_leadership_error =~ "orchard_admin"
      refute status.last_observed_leadership_error =~ "db.internal"
    end

    test "SPEC Leadership status demotes held-lock evidence owned by another controller" do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-b",
            advisory_lock_status: :held,
            lock_age_ms: 400
          }
        end
      )

      status = ControlPlane.read_only_status()

      assert status.deployment_mode == "active_standby"
      assert status.controller_role == "unknown"
      assert status.this_controller_identity == "controller-a"
      assert status.leader_identity == "controller-b"
      assert status.advisory_lock_status == "held"
      assert status.standby_write_path_behavior == "unknown"
    end
  end
end
