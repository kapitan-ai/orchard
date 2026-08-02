defmodule Orchard.RuntimeEndpoint.ActivationProbeTest do
  use Orchard.DataCase, async: false

  alias Orchard.Inference
  alias Orchard.Nodes
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.ActivationProbe
  alias Orchard.RuntimeEndpoint.Target

  defmodule FailingClient do
    def connect(_target), do: {:error, :authenticated_transport_failed}
    def disconnect(_connection), do: :ok
    def status(_connection, _opts), do: {:error, :authenticated_transport_failed}
  end

  defmodule RejectingClient do
    def connect(target), do: {:ok, %{target: target}}
    def disconnect(_connection), do: :ok

    def status(_connection, _opts), do: {:error, :authenticated_observation_rejected}
  end

  defmodule IdleClient do
    def connect(target), do: {:ok, %{target: target}}
    def disconnect(_connection), do: :ok
    def status(_connection, _opts), do: {:ok, %{}}
  end

  setup do
    previous = Application.get_env(:orchard_controller, :activation_probe, [])

    Application.put_env(
      :orchard_controller,
      :activation_probe,
      Keyword.merge(previous,
        allowed_clients: [FailingClient, RejectingClient, IdleClient],
        interval_ms: 5_000
      )
    )

    on_exit(fn ->
      if previous == [] do
        Application.delete_env(:orchard_controller, :activation_probe)
      else
        Application.put_env(:orchard_controller, :activation_probe, previous)
      end
    end)

    :ok
  end

  test "SPEC.md §4.5 probe interval is strictly below freshness and unreachable thresholds" do
    assert ActivationProbe.interval_ms() == 5_000
    assert :ok = ActivationProbe.assert_interval_contract!(5_000)

    assert_raise ArgumentError, ~r/unreachable/, fn ->
      ActivationProbe.assert_interval_contract!(15_000)
    end

    previous = Application.get_env(:orchard_controller, :inference, [])

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous || [],
        node_unreachable_threshold_ms: 40_000,
        node_freshness_threshold_ms: 30_000
      )
    )

    on_exit(fn ->
      if previous in [nil, []] do
        Application.delete_env(:orchard_controller, :inference)
      else
        Application.put_env(:orchard_controller, :inference, previous)
      end
    end)

    assert_raise ArgumentError, ~r/freshness/, fn ->
      ActivationProbe.assert_interval_contract!(30_000)
    end
  end

  test "SPEC.md §4.5 misconfigured interval clamps at init instead of blocking Controller boot" do
    assert {:ok, pid} = start_supervised({ActivationProbe, interval: 60_000})

    assert %{interval: interval} = :sys.get_state(pid)
    assert interval < Inference.node_unreachable_threshold_ms()
    assert interval < Inference.node_freshness_threshold_ms()
    assert :ok = ActivationProbe.assert_interval_contract!(interval)
  end

  test "SPEC.md §4.5 transport failure during probe demotes active node" do
    hb_time = DateTime.utc_now()

    node =
      insert_active_node!(%{
        advertise_addr: "10.0.1.10",
        rpc_port: 9444,
        connect_host: "10.0.1.10",
        connect_port: 9444,
        last_heartbeat_at: hb_time,
        health: :healthy
      })

    target =
      Target.grpc_compat(
        host: "10.0.1.10",
        port: 9444,
        node_id: node.id,
        metadata: %{authorization: :inference_dispatch, source: :trusted_node_inventory}
      )

    observed_at = DateTime.add(hb_time, 5, :second)

    assert {:ok, []} =
             ActivationProbe.run_once(
               client: FailingClient,
               timeout: 50,
               observed_at: observed_at,
               targets: [target]
             )

    assert Repo.get!(Node, node.id).health == :degraded
  end

  test "SPEC.md §4.5 seam rejection during probe does not demote" do
    hb_time = DateTime.utc_now()

    node =
      insert_active_node!(%{
        advertise_addr: "10.0.1.11",
        rpc_port: 9444,
        connect_host: "10.0.1.11",
        connect_port: 9444,
        last_heartbeat_at: hb_time,
        health: :healthy
      })

    target =
      Target.grpc_compat(
        host: "10.0.1.11",
        port: 9444,
        node_id: node.id,
        metadata: %{authorization: :inference_dispatch, source: :trusted_node_inventory}
      )

    assert {:ok, []} =
             ActivationProbe.run_once(
               client: RejectingClient,
               timeout: 50,
               observed_at: DateTime.add(hb_time, 5, :second),
               targets: [target]
             )

    reloaded = Repo.get!(Node, node.id)
    assert reloaded.health == :healthy
  end

  test "SPEC.md §4.5 standby controller run_once writes nothing" do
    previous = Application.get_env(:orchard_controller, :control_plane, [])

    Application.put_env(
      :orchard_controller,
      :control_plane,
      Keyword.put(previous || [], :role, :standby)
    )

    on_exit(fn ->
      if previous in [nil, []] do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous)
      end
    end)

    assert {:error, :controller_standby} =
             ActivationProbe.run_once(client: IdleClient, timeout: 50)

    assert Nodes.sweep_stale_node_heartbeats() == :noop
  end

  defp insert_active_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "probe-host-#{unique}.local",
          display_name: "probe-node-#{unique}",
          advertise_addr: "10.20.#{rem(unique, 200)}.#{rem(unique, 200) + 1}",
          rpc_port: 9444,
          state: :active,
          health: :healthy,
          capabilities: %{},
          tool_readiness: %{}
        },
        overrides
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end
end
