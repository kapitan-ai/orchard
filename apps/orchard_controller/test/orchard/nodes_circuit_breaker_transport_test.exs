defmodule Orchard.NodesCircuitBreakerTransportTest do
  use Orchard.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.CircuitBreakers
  alias Orchard.Nodes
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.Target

  test "SPEC.md §5.10 actually-run transport failure updates health and contributes once" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = insert_node!(occurred_at)
    target = target(node)

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: node.id,
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    assert {:ok, %{node: marked, breaker: recorded}} =
             Nodes.record_dispatch_transport_failure(target, :node_timeout, failure)

    assert marked.health == :degraded
    assert marked.last_transport_failure_at == occurred_at
    assert recorded.delivery == :recorded
    assert recorded.contribution_count == 1

    assert {:ok, %{node: duplicate_node, breaker: duplicate}} =
             Nodes.record_dispatch_transport_failure(target, :node_timeout, failure)

    assert duplicate_node.health == :degraded
    assert duplicate_node.last_transport_failure_at == occurred_at
    assert duplicate_node.updated_at == marked.updated_at
    assert duplicate.delivery == :duplicate
    assert duplicate.contribution_count == 1

    assert {:ok, evaluated} =
             CircuitBreakers.evaluate({:node, node.id},
               now: DateTime.add(occurred_at, 1, :second)
             )

    assert evaluated.contribution_count == 1
  end

  test "activation and discovery transport failures remain health-only" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = insert_node!(occurred_at)

    assert {:ok, marked} =
             Nodes.record_transport_failure(target(node), :node_timeout, occurred_at)

    assert marked.health == :degraded
    assert marked.last_transport_failure_at == occurred_at

    assert {:ok, evaluated} =
             CircuitBreakers.evaluate({:node, node.id},
               now: DateTime.add(occurred_at, 1, :second)
             )

    assert evaluated.state == :closed
    assert evaluated.contribution_count == 0
  end

  test "concurrent duplicate delivery locks canonical Node health and contributes once" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = insert_node!(occurred_at)
    target = target(node)
    owner = self()

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: node.id,
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    results =
      1..2
      |> Task.async_stream(
        fn _delivery ->
          Sandbox.allow(Repo, owner, self())
          Nodes.record_dispatch_transport_failure(target, :node_timeout, failure)
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{node: %Node{health: :degraded}}}, &1))

    assert results
           |> Enum.map(fn {:ok, %{breaker: breaker}} -> breaker.delivery end)
           |> Enum.sort() == [:duplicate, :recorded]

    persisted = Repo.get!(Node, node.id)
    assert persisted.health == :degraded
    assert persisted.last_transport_failure_at == occurred_at

    assert {:ok, evaluated} =
             CircuitBreakers.evaluate({:node, node.id},
               now: DateTime.add(occurred_at, 1, :second)
             )

    assert evaluated.contribution_count == 1
  end

  test "combined recording shares target-before-Node lock order with direct delivery" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = begin_unboxed_node!(occurred_at)
    target = target(node)
    owner = self()
    release_ref = make_ref()

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: node.id,
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    direct =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          CircuitBreakers.record_failure(failure,
            test_lock_observer: fn
              :target ->
                send(owner, {:direct_target_locked, self()})

                receive do
                  {:release_target, ^release_ref} -> :ok
                end

              _lock ->
                :ok
            end
          )
        end)
      end)

    assert_receive {:direct_target_locked, direct_pid}, 1_000

    combined =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Nodes.record_dispatch_transport_failure(target, :node_timeout, failure)
        end)
      end)

    assert Task.yield(combined, 50) == nil
    send(direct_pid, {:release_target, release_ref})

    assert {:ok, %{delivery: :recorded}} = Task.await(direct, 5_000)

    assert {:ok, %{node: %Node{health: :degraded}, breaker: %{delivery: :duplicate}}} =
             Task.await(combined, 5_000)

    assert {:ok, evaluated} =
             Sandbox.unboxed_run(Repo, fn ->
               CircuitBreakers.evaluate({:node, node.id},
                 now: DateTime.add(occurred_at, 1, :second)
               )
             end)

    assert evaluated.contribution_count == 1
  end

  test "canonical target mismatch fails before health or breaker mutation" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = insert_node!(occurred_at)

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: Ecto.UUID.generate(),
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    assert {:error, :transport_failure_target_mismatch} =
             Nodes.record_dispatch_transport_failure(target(node), :node_timeout, failure)

    unchanged = Repo.get!(Node, node.id)
    assert unchanged.health == :healthy
    assert unchanged.last_transport_failure_at == nil

    assert {:ok, evaluated} = CircuitBreakers.evaluate({:node, node.id}, now: occurred_at)
    assert evaluated.contribution_count == 0
  end

  test "outer transaction checkout failure returns a stable error without mutation" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = begin_unboxed_node!(occurred_at)

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: node.id,
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    assert {:error, :circuit_breaker_unavailable} =
             Nodes.record_dispatch_transport_failure(target(node), :node_timeout, failure)

    unchanged = Sandbox.unboxed_run(Repo, fn -> Repo.get!(Node, node.id) end)
    assert unchanged.health == :healthy
    assert unchanged.last_transport_failure_at == nil

    assert {:ok, evaluated} =
             Sandbox.unboxed_run(Repo, fn ->
               CircuitBreakers.evaluate({:node, node.id}, now: occurred_at)
             end)

    assert evaluated.contribution_count == 0
  end

  test "operator clear does not change transport health or lifecycle" do
    occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    node = insert_node!(occurred_at)

    failure = %{
      failure_id: Ecto.UUID.generate(),
      node_id: node.id,
      failure_class: "worker_or_node_loss",
      occurred_at: occurred_at
    }

    assert {:ok, %{node: marked}} =
             Nodes.record_dispatch_transport_failure(target(node), :node_timeout, failure)

    assert {:ok, _cleared} =
             CircuitBreakers.clear({:node, node.id},
               now: DateTime.add(occurred_at, 1, :second)
             )

    unchanged = Repo.get!(Node, node.id)
    assert unchanged.state == marked.state
    assert unchanged.health == marked.health
    assert unchanged.last_transport_failure_at == marked.last_transport_failure_at
  end

  defp insert_node!(occurred_at) do
    node_id = Ecto.UUID.generate()

    %Node{}
    |> Node.changeset(%{
      id: node_id,
      hostname: "transport-breaker-#{node_id}.local",
      display_name: "transport-breaker-#{node_id}",
      advertise_addr: "10.252.0.1",
      rpc_port: 9444,
      state: :active,
      health: :healthy,
      last_heartbeat_at: DateTime.add(occurred_at, -1, :second),
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp begin_unboxed_node!(occurred_at) do
    :ok = Sandbox.checkin(Repo)
    node = Sandbox.unboxed_run(Repo, fn -> insert_node!(occurred_at) end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("DELETE FROM circuit_breaker_failures WHERE node_id = $1", [
          Ecto.UUID.dump!(node.id)
        ])

        Repo.query!("DELETE FROM circuit_breakers WHERE node_id = $1", [
          Ecto.UUID.dump!(node.id)
        ])

        Repo.delete_all(from(candidate in Node, where: candidate.id == ^node.id))
      end)
    end)

    node
  end

  defp target(node) do
    Target.grpc_compat(
      host: node.advertise_addr,
      port: node.rpc_port,
      source: :node_inventory,
      trusted: true
    )
  end
end
