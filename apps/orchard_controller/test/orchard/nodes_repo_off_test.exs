defmodule Orchard.NodesRepoOffTest do
  @moduledoc """
  Isolated test for Orchard.Nodes repo-off semantics.

  Simulates repo unavailability by temporarily unregistering the Repo process
  name, which makes `Process.whereis(Orchard.Repo)` return nil. This avoids
  actually stopping the Repo (which would break Ecto's internal registry
  for subsequent test modules).
  """

  use ExUnit.Case, async: false

  alias Orchard.Nodes
  import Orchard.TestSupport.RepoHelpers

  test "graceful degradation when repo name is unregistered" do
    with_repo_unregistered(fn ->
      refute is_pid(Process.whereis(Orchard.Repo))

      assert Nodes.list_nodes() == []

      summary = Nodes.summary()
      assert summary.total == 0
      assert summary.by_state.active == 0
      assert summary.by_health.healthy == 0

      assert Nodes.lookup_by_target(host: "10.0.0.1", port: 9444) == nil

      status = %{node_metadata: %{node_id: Ecto.UUID.generate()}, runtime_health: nil}

      assert :noop =
               Nodes.observe_status(
                 [host: "10.0.0.1", port: 9444],
                 status,
                 DateTime.utc_now()
               )

      assert :noop =
               Nodes.mark_target_unreachable(
                 [host: "10.0.0.1", port: 9444],
                 DateTime.utc_now()
               )

      assert :noop =
               Nodes.record_transport_failure(
                 [host: "10.0.0.1", port: 9444],
                 :node_timeout,
                 DateTime.utc_now()
               )

      assert Nodes.schedulable_nodes() == []
    end)
  end
end
