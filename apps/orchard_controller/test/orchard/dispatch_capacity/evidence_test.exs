defmodule Orchard.DispatchCapacity.EvidenceTest do
  use Orchard.DataCase, async: false

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Nodes.Node

  test "SPEC.md §4.6.2 newer aggregate evidence replaces current evidence and stale evidence cannot" do
    node = insert_node!()
    first = ~U[2026-07-16 01:00:00.000000Z]
    newer = ~U[2026-07-16 01:01:00.000000Z]

    assert {:ok, evidence} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               "runtime_concurrency_limit" => 2,
               active_request_count: 1,
               validity: :valid,
               observed_at: first
             })

    assert evidence.runtime_concurrency_limit == 2

    assert {:ok, evidence} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               runtime_concurrency_limit: 4,
               active_request_count: 3,
               validity: :valid,
               observed_at: newer
             })

    assert evidence.runtime_concurrency_limit == 4
    assert evidence.active_request_count == 3

    assert {:ok, current} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               runtime_concurrency_limit: 9,
               active_request_count: 8,
               validity: :valid,
               observed_at: first
             })

    assert current.runtime_concurrency_limit == 4
    assert current.active_request_count == 3
    assert current.observed_at == newer
    assert Repo.get(Policy, node.id) == nil
  end

  test "SPEC.md §4.6.2 missing evidence remains distinct from malformed evidence" do
    node = insert_node!()
    observed_at = ~U[2026-07-16 01:00:00.000000Z]

    assert {:ok, missing} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               runtime_concurrency_limit: 2,
               active_request_count: nil,
               validity: :missing,
               observed_at: observed_at
             })

    assert missing.validity == :missing
    assert missing.runtime_concurrency_limit == 2
    assert missing.active_request_count == nil

    assert {:error, changeset} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               runtime_concurrency_limit: 0,
               active_request_count: 0,
               validity: :valid,
               observed_at: DateTime.add(observed_at, 1, :second)
             })

    assert "must be greater than 0" in errors_on(changeset).runtime_concurrency_limit
  end

  defp insert_node! do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "capacity-evidence-#{unique}.local",
      display_name: "capacity-evidence-#{unique}",
      advertise_addr: "127.0.0.1",
      rpc_port: 50_071,
      state: :admitted,
      health: :healthy,
      capabilities: %{},
      agent_version: "0.5.0-dev"
    })
    |> Repo.insert!()
  end
end
