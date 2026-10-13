defmodule Orchard.BeamPeerConnectionLockTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.BeamPeerConnectionLock

  test "KAP-82 exact-peer cookie/connect and forced-disconnect transitions cannot interleave" do
    parent = self()
    peer = :orchard_node_agent_lock_test@host

    connect =
      Task.async(fn ->
        BeamPeerConnectionLock.transact(peer, fn ->
          send(parent, :grant_cookie_installed)

          receive do
            :continue_connect -> send(parent, :peer_connected)
          end
        end)
      end)

    assert_receive :grant_cookie_installed

    disconnect =
      Task.async(fn ->
        BeamPeerConnectionLock.transact(peer, fn ->
          send(parent, :revoked_cookie_installed)
          send(parent, :peer_disconnected)
        end)
      end)

    refute_receive :revoked_cookie_installed
    refute_receive :peer_disconnected

    send(connect.pid, :continue_connect)
    assert_receive :peer_connected
    assert Task.await(connect) == :peer_connected
    assert_receive :revoked_cookie_installed
    assert_receive :peer_disconnected
    assert Task.await(disconnect) == :peer_disconnected
  end
end
