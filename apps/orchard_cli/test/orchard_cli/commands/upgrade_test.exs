defmodule OrchardCLI.Commands.UpgradeTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Upgrade

  @check_ids [
    "backup_manifest",
    "database_reachable",
    "database_lockable",
    "migrations_current",
    "request_activity",
    "draining_nodes",
    "decommissioning_nodes",
    "node_agent_versions"
  ]

  test "group help displays upgrade subcommands" do
    assert {:ok, output} = Upgrade.run([], runtime(plan_result("safe", 0)))
    assert output =~ "orchardctl upgrade"
    assert output =~ "orchardctl upgrade plan [--json]"
  end

  test "plan help displays JSON option without running preflight" do
    parent = self()

    runtime = %{
      plan: fn _opts -> send(parent, :plan_called) end,
      encode_json: &Jason.encode!/1
    }

    assert {:ok, output} = Upgrade.run(["plan", "--help"], runtime)
    assert output =~ "orchardctl upgrade plan [--json]"
    assert output =~ "--json"
    refute_received :plan_called
  end

  test "unknown upgrade subcommand exits 2" do
    assert {:error, message, 2} = Upgrade.run(["apply"], runtime(plan_result("safe", 0)))
    assert message =~ "Unknown upgrade subcommand: apply"
    assert message =~ "orchardctl upgrade"
  end

  test "unknown upgrade option exits 2" do
    assert {:error, message, 2} = Upgrade.run(["--json"], runtime(plan_result("safe", 0)))
    assert message =~ "Unknown option: --json"
    assert message =~ "orchardctl upgrade"
  end

  test "unknown plan option exits 2" do
    assert {:error, message, 2} =
             Upgrade.run(["plan", "--bogus"], runtime(plan_result("safe", 0)))

    assert message =~ "Unknown option: --bogus"
    assert message =~ "orchardctl upgrade plan"
  end

  test "plan rejects boolean negation for json as unknown option" do
    parent = self()

    runtime = %{
      plan: fn _opts -> send(parent, :plan_called) end,
      encode_json: &Jason.encode!/1
    }

    assert {:error, message, 2} = Upgrade.run(["plan", "--no-json"], runtime)
    assert message =~ "Unknown option: --no-json"
    assert message =~ "orchardctl upgrade plan"
    refute_received :plan_called
  end

  test "plan rejects boolean negation for help as unknown option" do
    parent = self()

    runtime = %{
      plan: fn _opts -> send(parent, :plan_called) end,
      encode_json: &Jason.encode!/1
    }

    assert {:error, message, 2} = Upgrade.run(["plan", "--no-help"], runtime)
    assert message =~ "Unknown option: --no-help"
    assert message =~ "orchardctl upgrade plan"
    refute_received :plan_called
  end

  test "unexpected plan argument exits 2" do
    assert {:error, message, 2} = Upgrade.run(["plan", "extra"], runtime(plan_result("safe", 0)))
    assert message =~ "Unexpected argument for upgrade plan: extra"
    assert message =~ "orchardctl upgrade plan"
  end

  test "SPEC 13.7 safe text output returns ok command result" do
    assert {:ok, output} = Upgrade.run(["plan"], runtime(plan_result("safe", 0)))
    assert output =~ "Status: safe"
    assert output =~ "Exit code: 0"
    assert output =~ "[ok] backup_manifest"
    refute output =~ "Remediation:"
  end

  test "SPEC 13.7 unsafe text output maps exit code 1" do
    remediation = "Wait for active requests to finish."
    checks = replace_check("request_activity", "blocked", remediation)

    assert {:error, output, 1} =
             Upgrade.run(["plan"], runtime(plan_result("unsafe", 1, checks: checks)))

    assert output =~ "Status: unsafe"
    assert output =~ "[blocked] request_activity"
    assert output =~ remediation
  end

  test "SPEC 13.7 config_error text output maps exit code 2" do
    checks = replace_check("backup_manifest", "config_error", "Regenerate the backup manifest.")

    assert {:error, output, 2} =
             Upgrade.run(["plan"], runtime(plan_result("config_error", 2, checks: checks)))

    assert output =~ "Status: config_error"
    assert output =~ "[config_error] backup_manifest"
  end

  test "SPEC 13.7 unreachable text output maps exit code 3" do
    checks = replace_check("database_reachable", "unreachable", "Start Postgres and retry.")

    assert {:error, output, 3} =
             Upgrade.run(["plan"], runtime(plan_result("unreachable", 3, checks: checks)))

    assert output =~ "Status: unreachable"
    assert output =~ "[unreachable] database_reachable"
  end

  test "text output deduplicates remediation section" do
    remediation = "Drain traffic before upgrading."

    checks =
      @check_ids
      |> Enum.map(&check(&1, "ok"))
      |> List.replace_at(4, check("request_activity", "blocked", remediation))
      |> List.replace_at(5, check("draining_nodes", "blocked", remediation))

    assert {:error, output, 1} =
             Upgrade.run(["plan"], runtime(plan_result("unsafe", 1, checks: checks)))

    assert count_occurrences(output, remediation) == 1
  end

  test "SPEC 13.7 JSON safe output returns ok and directly encodes plan map" do
    parent = self()
    plan = plan_result("safe", 0)

    runtime = %{
      plan: fn opts ->
        send(parent, {:plan_opts, opts})
        plan
      end,
      encode_json: fn value ->
        send(parent, {:encoded_value, value})
        Jason.encode!(value)
      end
    }

    assert {:ok, output} = Upgrade.run(["plan", "--json"], runtime)
    assert Jason.decode!(output)["status"] == "safe"
    assert_received {:plan_opts, []}
    assert_received {:encoded_value, ^plan}
  end

  test "SPEC 13.7 JSON unsafe output maps exit code 1 to stderr contract" do
    checks = replace_check("request_activity", "blocked", "Drain traffic before upgrading.")
    plan = plan_result("unsafe", 1, checks: checks)

    assert {:error, output, 1} = Upgrade.run(["plan", "--json"], runtime(plan))
    assert Jason.decode!(output)["status"] == "unsafe"
  end

  test "SPEC 13.7 JSON config_error output maps exit code 2" do
    checks = replace_check("backup_manifest", "config_error", "Regenerate the backup manifest.")
    plan = plan_result("config_error", 2, checks: checks)

    assert {:error, output, 2} = Upgrade.run(["plan", "--json"], runtime(plan))
    assert Jason.decode!(output)["status"] == "config_error"
  end

  test "SPEC 13.7 JSON unreachable output maps exit code 3" do
    checks = replace_check("database_reachable", "unreachable", "Start Postgres and retry.")
    plan = plan_result("unreachable", 3, checks: checks)

    assert {:error, output, 3} = Upgrade.run(["plan", "--json"], runtime(plan))
    assert Jason.decode!(output)["status"] == "unreachable"
  end

  defp runtime(plan) do
    %{
      plan: fn _opts -> plan end,
      encode_json: &Jason.encode!/1
    }
  end

  defp plan_result(status, exit_code, opts \\ []) do
    checks = Keyword.get_lazy(opts, :checks, fn -> Enum.map(@check_ids, &check(&1, "ok")) end)

    %{
      status: status,
      exit_code: exit_code,
      checked_at: "2026-04-19T00:00:00Z",
      controller: %{version: "0.5.0-dev", build_ref: "abc123", build_date: "2026-04-19"},
      policy: %{backup_manifest_path: "/tmp/upgrade-backup.json", queue_tolerance: 0},
      summary: summarize(checks),
      checks: checks
    }
  end

  defp replace_check(id, status, remediation) do
    Enum.map(@check_ids, fn
      ^id -> check(id, status, remediation)
      other -> check(other, "ok")
    end)
  end

  defp check(id, status, remediation \\ nil) do
    %{
      id: id,
      status: status,
      summary: "#{id} #{status}",
      detail: "#{id} detail",
      remediation: remediation,
      data: %{}
    }
  end

  defp summarize(checks) do
    %{
      ok: count_status(checks, "ok"),
      warning: count_status(checks, "warning"),
      blocked: count_status(checks, "blocked"),
      config_error: count_status(checks, "config_error"),
      unreachable: count_status(checks, "unreachable")
    }
  end

  defp count_status(checks, status), do: Enum.count(checks, &(&1.status == status))

  defp count_occurrences(output, value) do
    output
    |> String.split(value)
    |> length()
    |> Kernel.-(1)
  end
end
