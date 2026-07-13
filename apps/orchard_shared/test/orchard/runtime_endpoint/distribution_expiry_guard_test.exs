defmodule Orchard.RuntimeEndpoint.DistributionExpiryGuardTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.DistributionExpiryGuard

  test "SPEC.md §7.5.0 expires an active exact peer and stops Distribution" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :node_agent,
      controller_beam_name: "orchard_controller_a@10.0.0.10",
      node_beam_name: "orchard_node_agent_b@10.0.0.20",
      expires_at: now
    }

    assert {:ok, _pid} =
             DistributionExpiryGuard.start_link(
               manifest_path: "/protected/launch.json",
               launch_loader: fn "/protected/launch.json" -> {:ok, manifest} end,
               now: fn -> now end,
               cookie_setter: fn peer, replacement ->
                 send(test_pid, {:cookie_invalidated, peer, replacement})
                 true
               end,
               disconnect: fn peer -> send(test_pid, {:peer_disconnected, peer}) end,
               stop_distribution: fn ->
                 send(test_pid, :distribution_stopped)
                 :ok
               end,
               fail_closed: fn -> send(test_pid, :application_stopped) end
             )

    peer = :"orchard_controller_a@10.0.0.10"
    assert_receive {:cookie_invalidated, ^peer, replacement}
    assert is_atom(replacement)
    refute replacement == peer
    assert_receive {:peer_disconnected, ^peer}
    assert_receive :distribution_stopped
    refute_receive :application_stopped
  end

  test "SPEC.md §7.5.0 stops the application when expiry cleanup is incomplete" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :controller,
      controller_beam_name: "orchard_controller_a@10.0.0.10",
      node_beam_name: "orchard_node_agent_b@10.0.0.20",
      expires_at: now
    }

    assert {:ok, _pid} =
             DistributionExpiryGuard.start_link(
               name: :incomplete_expiry_guard,
               manifest_path: "/protected/launch.json",
               launch_loader: fn _path -> {:ok, manifest} end,
               now: fn -> now end,
               cookie_setter: fn _peer, _replacement -> false end,
               disconnect: fn peer -> send(test_pid, {:peer_disconnected, peer}) end,
               stop_distribution: fn -> {:error, :not_alive} end,
               fail_closed: fn -> send(test_pid, :application_stopped) end
             )

    assert_receive {:peer_disconnected, :"orchard_node_agent_b@10.0.0.20"}
    assert_receive :application_stopped
  end

  test "SPEC.md §7.5.0 repeated expired restarts reuse one bounded cleanup cookie" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :node_agent,
      controller_beam_name: "orchard_controller_a@10.0.0.10",
      node_beam_name: "orchard_node_agent_b@10.0.0.20",
      expires_at: now
    }

    replacements =
      for name <- [:expired_restart_guard_a, :expired_restart_guard_b, :expired_restart_guard_c] do
        assert {:ok, pid} =
                 DistributionExpiryGuard.start_link(
                   name: name,
                   manifest_path: "/protected/launch.json",
                   launch_loader: fn _path -> {:ok, manifest} end,
                   now: fn -> now end,
                   cookie_setter: fn _peer, replacement ->
                     send(test_pid, {:replacement_cookie, replacement})
                     true
                   end,
                   disconnect: fn _peer -> true end,
                   stop_distribution: fn -> :ok end,
                   fail_closed: fn -> :ok end
                 )

        assert_receive {:replacement_cookie, replacement}
        GenServer.stop(pid)
        replacement
      end

    assert Enum.uniq(replacements) == [:orchard_expired_peer_grant]
  end
end
