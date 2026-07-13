defmodule Orchard.RuntimeEndpoint.DistributionExpiryGuardTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.DistributionExpiryGuard

  @controller_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @controller_name "orchard_controller_bbbbbbbbbbbb4bbb8bbbbbbbbbbbbbbb@10.0.0.10"
  @node_id "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @node_name "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"

  test "SPEC.md §7.5.0 expires an active exact peer and stops Distribution" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :node_agent,
      controller_id: @controller_id,
      node_id: @node_id,
      controller_beam_name: @controller_name,
      node_beam_name: @node_name,
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

    peer = String.to_atom(@controller_name)
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
      controller_id: @controller_id,
      node_id: @node_id,
      controller_beam_name: @controller_name,
      node_beam_name: @node_name,
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
               fail_closed: fn -> send(test_pid, :application_stopped) end,
               shutdown_grace_ms: 60_000,
               hard_stop: fn -> :ok end
             )

    assert_receive {:peer_disconnected, peer}
    assert Atom.to_string(peer) == @node_name
    assert_receive :application_stopped
  end

  test "SPEC.md §7.5.0 hard-stops when graceful expiry shutdown fails" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :controller,
      controller_id: @controller_id,
      node_id: @node_id,
      controller_beam_name: @controller_name,
      node_beam_name: @node_name,
      expires_at: now
    }

    assert {:ok, pid} =
             DistributionExpiryGuard.start_link(
               name: :failed_shutdown_expiry_guard,
               manifest_path: "/protected/launch.json",
               launch_loader: fn _path -> {:ok, manifest} end,
               now: fn -> now end,
               cookie_setter: fn _peer, _replacement -> false end,
               disconnect: fn _peer -> false end,
               stop_distribution: fn -> {:error, :not_alive} end,
               fail_closed: fn -> raise "shutdown failed" end,
               shutdown_grace_ms: 0,
               hard_stop: fn -> send(test_pid, :hard_stopped) end
             )

    assert_receive :hard_stopped
    GenServer.stop(pid)
  end

  test "SPEC.md §7.5.0 repeated expired restarts reuse one bounded cleanup cookie" do
    test_pid = self()
    now = ~U[2026-07-13 08:00:00.000000Z]

    manifest = %{
      role: :node_agent,
      controller_id: @controller_id,
      node_id: @node_id,
      controller_beam_name: @controller_name,
      node_beam_name: @node_name,
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

  test "SPEC.md §7.5.0 malformed manifest peers fail without creating atoms" do
    Process.flag(:trap_exit, true)
    controller_id = Ecto.UUID.generate()
    node_id = Ecto.UUID.generate()
    compact_controller_id = String.replace(controller_id, "-", "")
    compact_node_id = String.replace(node_id, "-", "")
    malformed_peer = "orchard_node_agent_#{compact_node_id}@10.1"

    manifest = %{
      role: :controller,
      controller_id: controller_id,
      node_id: node_id,
      controller_beam_name: "orchard_controller_#{compact_controller_id}@10.0.0.10",
      node_beam_name: malformed_peer,
      expires_at: ~U[2026-07-13 08:00:00.000000Z]
    }

    assert_raise ArgumentError, fn -> String.to_existing_atom(malformed_peer) end

    assert {:error, :beam_target_unknown} =
             DistributionExpiryGuard.start_link(
               name: :malformed_peer_expiry_guard,
               manifest_path: "/protected/launch.json",
               launch_loader: fn _path -> {:ok, manifest} end
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(malformed_peer) end
  end
end
