defmodule Orchard.RuntimeEndpoint.ConnectionIncarnationTest do
  use ExUnit.Case, async: true

  alias Orchard.RuntimeEndpoint.ConnectionIncarnation

  test "KAP-82 issues one 128-bit incarnation per current connection and replaces it on reconnect" do
    {:ok, connection_id_agent} = Agent.start_link(fn -> 41 end)
    {:ok, random_agent} = Agent.start_link(fn -> 0 end)
    provider = fn :peer@host -> Agent.get(connection_id_agent, & &1) end
    random_bytes = fn 16 -> Agent.get_and_update(random_agent, &{<<&1::128>>, &1 + 1}) end

    registry =
      start_supervised!(
        {ConnectionIncarnation,
         name: nil,
         role: :node_agent,
         monitor: fn _enabled, _opts -> :ok end,
         connection_id_provider: provider,
         random_bytes: random_bytes}
      )

    assert {:ok, first} = ConnectionIncarnation.issue(:peer@host, registry)
    assert first.connection_id == 41
    assert Base.url_decode64!(first.incarnation, padding: false) == <<0::128>>
    assert {:ok, ^first} = ConnectionIncarnation.issue(:peer@host, registry)

    Agent.update(connection_id_agent, fn _old -> 42 end)
    send(registry, {:nodeup, :peer@host, %{connection_id: 42}})

    assert {:ok, successor} = ConnectionIncarnation.issue(:peer@host, registry)
    assert successor.connection_id == 42
    refute successor.incarnation == first.incarnation
  end

  test "KAP-82 Node Agent registry restart replaces the transport before reissuing" do
    {:ok, connection_id_agent} = Agent.start_link(fn -> 9 end)
    provider = fn :peer@host -> Agent.get(connection_id_agent, & &1) end
    {:ok, random_agent} = Agent.start_link(fn -> 3 end)
    random_bytes = fn 16 -> Agent.get_and_update(random_agent, &{<<&1::128>>, &1 + 1}) end

    options = [
      name: nil,
      role: :node_agent,
      monitor: fn _enabled, _opts -> :ok end,
      connected_peers: fn -> [:peer@host] end,
      connection_id_provider: provider,
      disconnect: fn :peer@host ->
        Agent.update(connection_id_agent, &(&1 + 1))
        true
      end,
      random_bytes: random_bytes
    ]

    {:ok, first_registry} = ConnectionIncarnation.start_link(options)
    assert {:ok, first} = ConnectionIncarnation.issue(:peer@host, first_registry)
    GenServer.stop(first_registry)

    {:ok, restarted_registry} = ConnectionIncarnation.start_link(options)
    assert {:ok, restarted} = ConnectionIncarnation.issue(:peer@host, restarted_registry)

    refute restarted.connection_id == first.connection_id
    refute restarted.incarnation == first.incarnation
  end

  test "KAP-82 Controller rejects malformed, replaced, invalidated, and restarted bindings" do
    {:ok, connection_id_agent} = Agent.start_link(fn -> 7 end)
    provider = fn :peer@host -> Agent.get(connection_id_agent, & &1) end

    {:ok, registry} =
      ConnectionIncarnation.start_link(
        name: nil,
        role: :controller,
        monitor: fn _enabled, _opts -> :ok end,
        connection_id_provider: provider
      )

    incarnation = Base.url_encode64(<<2::128>>, padding: false)

    assert {:error, :connection_incarnation_not_current} =
             ConnectionIncarnation.bind(:peer@host, 7, "invalid", registry)

    assert :ok = ConnectionIncarnation.bind(:peer@host, 7, incarnation, registry)
    assert ConnectionIncarnation.current?(:peer@host, 7, incarnation, registry)

    conflicting = Base.url_encode64(<<3::128>>, padding: false)

    assert {:error, :connection_incarnation_not_current} =
             ConnectionIncarnation.bind(:peer@host, 7, conflicting, registry)

    refute ConnectionIncarnation.current?(:peer@host, 7, incarnation, registry)

    assert {:error, :connection_incarnation_not_current} =
             ConnectionIncarnation.bind(:peer@host, 7, incarnation, registry)

    refute ConnectionIncarnation.current?(:peer@host, 6, incarnation, registry)

    assert {:error, :connection_incarnation_not_current} =
             ConnectionIncarnation.bind(:peer@host, 7, incarnation, registry)

    Agent.update(connection_id_agent, fn _old -> 8 end)
    refute ConnectionIncarnation.current?(:peer@host, 7, incarnation, registry)

    assert :ok = ConnectionIncarnation.bind(:peer@host, 8, incarnation, registry)
    assert :ok = ConnectionIncarnation.invalidate(:peer@host, 8, registry)
    refute ConnectionIncarnation.current?(:peer@host, 8, incarnation, registry)

    GenServer.stop(registry)

    {:ok, restarted} =
      ConnectionIncarnation.start_link(
        name: nil,
        role: :controller,
        monitor: fn _enabled, _opts -> :ok end,
        connection_id_provider: provider
      )

    refute ConnectionIncarnation.current?(:peer@host, 8, incarnation, restarted)
  end

  test "KAP-82 fence serializes invalidation until the durable callback completes" do
    provider = fn :peer@host -> 12 end

    {:ok, registry} =
      ConnectionIncarnation.start_link(
        name: nil,
        role: :controller,
        monitor: fn _enabled, _opts -> :ok end,
        connection_id_provider: provider
      )

    incarnation = Base.url_encode64(<<5::128>>, padding: false)
    assert :ok = ConnectionIncarnation.bind(:peer@host, 12, incarnation, registry)
    parent = self()

    task =
      Task.async(fn ->
        ConnectionIncarnation.fence(
          :peer@host,
          12,
          incarnation,
          fn ->
            send(parent, {:fence_acquired, self()})
            assert_receive :finish_commit
            :committed
          end,
          registry
        )
      end)

    assert_receive {:fence_acquired, worker}
    send(registry, {:nodedown, :peer@host, %{connection_id: 12}})
    send(worker, :finish_commit)
    assert Task.await(task) == :committed
    refute ConnectionIncarnation.current?(:peer@host, 12, incarnation, registry)
  end

  test "KAP-82 registry loss terminates an acquired fence before durable commit" do
    Process.flag(:trap_exit, true)
    provider = fn :peer@host -> 13 end

    {:ok, registry} =
      ConnectionIncarnation.start_link(
        name: nil,
        role: :controller,
        monitor: fn _enabled, _opts -> :ok end,
        connection_id_provider: provider
      )

    incarnation = Base.url_encode64(<<6::128>>, padding: false)
    assert :ok = ConnectionIncarnation.bind(:peer@host, 13, incarnation, registry)
    parent = self()

    caller =
      spawn_link(fn ->
        ConnectionIncarnation.fence(
          :peer@host,
          13,
          incarnation,
          fn ->
            send(parent, :commit_paused)
            Process.sleep(:infinity)
          end,
          registry
        )

        send(parent, :commit_survived)
      end)

    assert_receive :commit_paused
    Process.exit(registry, :shutdown)
    assert_receive {:EXIT, ^caller, _reason}
    refute_receive :commit_survived
  end

  test "KAP-82 failed fenced callback leaves the registry available" do
    Process.flag(:trap_exit, true)
    provider = fn :peer@host -> 14 end

    {:ok, registry} =
      ConnectionIncarnation.start_link(
        name: nil,
        role: :controller,
        monitor: fn _enabled, _opts -> :ok end,
        connection_id_provider: provider
      )

    incarnation = Base.url_encode64(<<7::128>>, padding: false)
    assert :ok = ConnectionIncarnation.bind(:peer@host, 14, incarnation, registry)

    caller =
      spawn_link(fn ->
        ConnectionIncarnation.fence(
          :peer@host,
          14,
          incarnation,
          fn -> raise "durable callback failed" end,
          registry
        )
      end)

    assert_receive {:EXIT, ^caller, _reason}
    assert Process.alive?(registry)
    assert ConnectionIncarnation.current?(:peer@host, 14, incarnation, registry)
  end
end
