defmodule Orchard.UpgradeTest.UnreachableRelease do
  @moduledoc false

  def postgres_reachable?, do: false
  def migration_lockable?, do: {:error, :econnrefused}
  def migration_status, do: {:error, :econnrefused}
  def migrations_current?, do: false
end

defmodule Orchard.UpgradeTest.LockHeldRelease do
  @moduledoc false

  def postgres_reachable?, do: true
  def migration_lockable?, do: {:error, :locked_by_other}
  def migration_status, do: {:ok, :current}
  def migrations_current?, do: true
end

defmodule Orchard.UpgradeTest.PendingMigrationsRelease do
  @moduledoc false

  def postgres_reachable?, do: true
  def migration_lockable?, do: {:ok, :locked}
  def migration_status, do: {:ok, :pending}
  def migrations_current?, do: false
end

defmodule Orchard.UpgradeTest.ErrorMigrationStatusRelease do
  @moduledoc false

  def postgres_reachable?, do: true
  def migration_lockable?, do: {:ok, :locked}
  def migration_status, do: {:error, :schema_migrations_unavailable}
  def migrations_current?, do: false
end

defmodule Orchard.UpgradeTest.CountedReachabilityRelease do
  @moduledoc false

  def postgres_reachable? do
    calls = Process.get(:upgrade_reachability_calls, 0)
    Process.put(:upgrade_reachability_calls, calls + 1)
    true
  end

  def migration_lockable?, do: {:ok, :locked}
  def migration_status, do: {:ok, :pending}
  def migrations_current?, do: false
end

defmodule Orchard.UpgradeTest.ErrorRequests do
  @moduledoc false

  def summary, do: {:error, :repo_unavailable}
end

defmodule Orchard.UpgradeTest.ErrorNodes do
  @moduledoc false

  def list_nodes_for_upgrade!, do: {:error, :repo_unavailable}
end

defmodule Orchard.UpgradeTest.RaisingNodes do
  @moduledoc false

  def list_nodes_for_upgrade!, do: raise("node inventory unavailable")
end

defmodule Orchard.UpgradeTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures, only: [create_request!: 1]

  alias Orchard.Nodes.Node
  alias Orchard.Upgrade

  @check_order [
    "backup_manifest",
    "database_reachable",
    "database_lockable",
    "migrations_current",
    "request_activity",
    "draining_nodes",
    "decommissioning_nodes",
    "node_agent_versions"
  ]

  setup do
    previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
    previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)
    previous_upgrade_preflight = Application.get_env(:orchard_controller, :upgrade_preflight, [])

    Application.put_env(:orchard_controller, :enable_db_checks, true)
    Application.put_env(:orchard_controller, :start_repo, true)
    Application.put_env(:orchard_controller, :upgrade_preflight, [])

    manifest_dir =
      Path.join(System.tmp_dir!(), "orchard-upgrade-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(manifest_dir)
    manifest_path = Path.join(manifest_dir, "upgrade-backup.json")

    on_exit(fn ->
      Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
      Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
      Application.put_env(:orchard_controller, :upgrade_preflight, previous_upgrade_preflight)
      File.rm_rf(manifest_dir)
    end)

    {:ok, manifest_path: manifest_path}
  end

  test "SPEC 13.7 safe plan returns fixed JSON-safe shape", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "safe"
    assert plan.exit_code == 0
    assert Enum.map(plan.checks, & &1.id) == @check_order
    assert plan.summary == %{ok: 8, warning: 0, blocked: 0, config_error: 0, unreachable: 0}
    assert plan.policy.backup_manifest_path == manifest_path
    assert plan.policy.queue_tolerance == 0
    assert plan.controller.version == Orchard.version()
    assert is_binary(plan.checked_at)
    assert Jason.encode!(plan)
  end

  test "SPEC 13.7 backup_manifest missing blocks upgrade", %{manifest_path: manifest_path} do
    insert_node!(%{agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "backup_manifest").status == "blocked"
  end

  test "SPEC 13.7 malformed backup manifest is config_error", %{manifest_path: manifest_path} do
    File.write!(manifest_path, "not-json")
    insert_node!(%{agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "backup_manifest").status == "config_error"
  end

  test "SPEC 13.7 backup manifest JSON must have manifest fields", %{manifest_path: manifest_path} do
    File.write!(manifest_path, Jason.encode!([]))
    insert_node!(%{agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "backup_manifest").status == "config_error"
  end

  test "SPEC 13.7 database_reachable disabled checks is config_error", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "database_reachable").status == "config_error"
  end

  test "SPEC 13.7 DB-backed request and node checks disabled are config_error", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    Application.put_env(:orchard_controller, :enable_db_checks, false)

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "request_activity").status == "config_error"
    assert check(plan, "draining_nodes").status == "config_error"
    assert check(plan, "decommissioning_nodes").status == "config_error"
    assert check(plan, "node_agent_versions").status == "config_error"
  end

  test "SPEC 13.7 DB-backed request and node errors are unreachable", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        requests_impl: Orchard.UpgradeTest.ErrorRequests,
        nodes_impl: Orchard.UpgradeTest.ErrorNodes
      )

    assert plan.status == "unreachable"
    assert plan.exit_code == 3
    assert check(plan, "request_activity").status == "unreachable"
    assert check(plan, "request_activity").data.reason == "repo_unavailable"
    assert check(plan, "draining_nodes").status == "unreachable"
    assert check(plan, "decommissioning_nodes").status == "unreachable"
    assert check(plan, "node_agent_versions").status == "unreachable"
  end

  test "SPEC 13.7 invalid queue tolerance is config_error", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path, queue_tolerance: "bad")

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "request_activity").status == "config_error"
  end

  test "SPEC 13.7 JSON-safe preflight data preserves nil, boolean, and atom primitives" do
    cases = [
      {nil, nil},
      {false, false},
      {true, true},
      {:missing_manifest, "missing_manifest"}
    ]

    for {input, expected} <- cases do
      plan = Upgrade.plan(backup_manifest_path: input)

      assert plan.status == "config_error"
      assert check(plan, "backup_manifest").status == "config_error"
      assert check(plan, "backup_manifest").data.path == expected

      decoded = plan |> Jason.encode!() |> Jason.decode!()

      assert get_in(decoded, ["checks", Access.at(0), "data", "path"]) == expected
    end
  end

  test "SPEC 13.7 status precedence prefers config_error over unreachable", %{
    manifest_path: manifest_path
  } do
    File.write!(manifest_path, "not-json")
    insert_node!(%{agent_version: Orchard.version()})

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.UnreachableRelease
      )

    assert plan.status == "config_error"
    assert plan.exit_code == 2
    assert check(plan, "backup_manifest").status == "config_error"
    assert check(plan, "database_reachable").status == "unreachable"
  end

  test "SPEC 13.7 database_reachable unreachable maps to exit 3", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.UnreachableRelease
      )

    assert plan.status == "unreachable"
    assert plan.exit_code == 3
    assert check(plan, "database_reachable").status == "unreachable"
  end

  test "SPEC 13.7 database_lockable held lock blocks upgrade", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.LockHeldRelease
      )

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "database_lockable").status == "blocked"
  end

  test "SPEC 13.7 migrations_current pending blocks upgrade", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.PendingMigrationsRelease
      )

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "migrations_current").status == "blocked"
  end

  test "SPEC 13.7 migrations_current status errors are unreachable", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.ErrorMigrationStatusRelease
      )

    assert plan.status == "unreachable"
    assert plan.exit_code == 3
    assert check(plan, "migrations_current").status == "unreachable"
    assert check(plan, "migrations_current").data.reason == "schema_migrations_unavailable"
  end

  test "SPEC 13.7 migrations_current uses one stable reachability result", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})
    Process.delete(:upgrade_reachability_calls)

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        release_impl: Orchard.UpgradeTest.CountedReachabilityRelease
      )

    assert check(plan, "migrations_current").status == "blocked"
    assert Process.get(:upgrade_reachability_calls) == 1
  end

  test "SPEC 13.7 request_activity blocks active non-queued work", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})
    create_request!(%{state: :running})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "request_activity").status == "blocked"
    assert check(plan, "request_activity").data.active_nonqueued == 1
  end

  test "SPEC 13.7 request_activity allows queued work within tolerance", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})
    create_request!(%{state: :queued})

    plan = Upgrade.plan(backup_manifest_path: manifest_path, queue_tolerance: 1)

    assert plan.status == "safe"
    assert check(plan, "request_activity").status == "ok"
    assert check(plan, "request_activity").data.queued == 1
  end

  test "SPEC 13.7 runtime upgrade_preflight config supplies default policy", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: Orchard.version()})
    create_request!(%{state: :queued})

    Application.put_env(:orchard_controller, :upgrade_preflight,
      backup_manifest_path: manifest_path,
      queue_tolerance: 1
    )

    plan = Upgrade.plan()

    assert plan.status == "safe"
    assert plan.policy.backup_manifest_path == manifest_path
    assert plan.policy.queue_tolerance == 1
    assert check(plan, "request_activity").status == "ok"
  end

  test "SPEC 13.7 node inventory failures are unreachable", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)

    plan =
      Upgrade.plan(
        backup_manifest_path: manifest_path,
        nodes_impl: Orchard.UpgradeTest.RaisingNodes
      )

    assert plan.status == "unreachable"
    assert plan.exit_code == 3
    assert check(plan, "draining_nodes").status == "unreachable"
    assert check(plan, "decommissioning_nodes").status == "unreachable"
    assert check(plan, "node_agent_versions").status == "unreachable"
  end

  test "SPEC 13.7 draining_nodes blocks active drain operations", %{manifest_path: manifest_path} do
    write_manifest!(manifest_path)
    insert_node!(%{state: :draining, agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "draining_nodes").status == "blocked"
  end

  test "SPEC 13.7 decommissioning_nodes blocks decommissioning nodes", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{state: :decommissioning, agent_version: Orchard.version()})

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "decommissioning_nodes").status == "blocked"
  end

  test "SPEC 13.7 node_agent_versions blocks incompatible versions", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: "0.3.0"})

    plan = Upgrade.plan(backup_manifest_path: manifest_path, controller_version: "0.5.0-dev")

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "node_agent_versions").status == "blocked"
  end

  test "SPEC 13.7 node_agent_versions accepts controller minor N and N-1", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: "0.5.9"})
    insert_node!(%{agent_version: "0.4.0"})

    plan = Upgrade.plan(backup_manifest_path: manifest_path, controller_version: "0.5.0-dev")

    assert plan.status == "safe"
    assert check(plan, "node_agent_versions").status == "ok"
  end

  test "SPEC 13.7 node_agent_versions handles non-semver fallback versions", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)
    insert_node!(%{agent_version: "0.5.0"})

    plan = Upgrade.plan(backup_manifest_path: manifest_path, controller_version: "dev")

    assert plan.status == "unsafe"
    assert plan.exit_code == 1
    assert check(plan, "node_agent_versions").status == "blocked"
  end

  test "SPEC 13.7 node_agent_versions warns when no nodes are registered", %{
    manifest_path: manifest_path
  } do
    write_manifest!(manifest_path)

    plan = Upgrade.plan(backup_manifest_path: manifest_path)

    assert plan.status == "safe"
    assert plan.exit_code == 0
    assert check(plan, "node_agent_versions").status == "warning"
  end

  defp write_manifest!(path) do
    File.write!(path, Jason.encode!(%{schema_version: 1, created_at: "2026-04-18T12:00:00Z"}))
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hostname: "upgrade-node-#{unique}.local",
          display_name: "upgrade-node-#{unique}",
          advertise_addr: "10.250.#{rem(unique, 255)}.#{rem(unique + 1, 255)}",
          rpc_port: 9_444,
          state: :active,
          health: :healthy,
          capabilities: %{},
          tool_readiness: %{},
          agent_version: "0.5.0",
          last_heartbeat_at: DateTime.utc_now()
        },
        overrides
      )

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp check(plan, id) do
    Enum.find(plan.checks, &(&1.id == id))
  end
end
