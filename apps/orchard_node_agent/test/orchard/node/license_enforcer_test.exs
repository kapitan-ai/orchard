defmodule Orchard.Node.LicenseEnforcerTest.LicensingSpy do
  @moduledoc false

  def inspect_local do
    send(self(), :licensing_inspected)

    Process.get(
      :license_status,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json"
      }
    )
  end
end

defmodule Orchard.Node.LicenseEnforcerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.Config.M1RuntimeDefaults
  alias Orchard.Node.LicenseEnforcer

  setup do
    previous_runtime = Application.get_env(:orchard_node_agent, :runtime, [])

    on_exit(fn ->
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      Process.delete(:license_status)
    end)

    %{previous_runtime: previous_runtime}
  end

  test "runtime defaults keep packaged warn and test env override off" do
    defaults = M1RuntimeDefaults.node_runtime("/tmp/orchard")

    assert defaults[:license_enforcement] == :warn
    assert defaults[:worker_generation_mode] == "batch"
    assert defaults[:worker_max_concurrent_requests_per_model] == "auto"
    assert defaults[:worker_auto_max_concurrent_requests_per_model] == 3
    assert defaults[:worker_memory_budget_mode] == "observe"
    assert defaults[:worker_memory_budget_utilization] == 0.90
    assert defaults[:worker_memory_budget_overhead_bytes] == 1_073_741_824

    assert Application.fetch_env!(:orchard_node_agent, :runtime)[:license_enforcement] == :off
  end

  test ":off skips licensing checks entirely", %{previous_runtime: previous_runtime} do
    put_runtime(previous_runtime, license_enforcement: :off)

    assert :ok = LicenseEnforcer.enforce_startup!()
    refute_received :licensing_inspected
  end

  test ":warn logs and continues for non-valid states", %{previous_runtime: previous_runtime} do
    Process.put(
      :license_status,
      %Orchard.Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: "/tmp/current.json"
      }
    )

    put_runtime(previous_runtime, license_enforcement: :warn)

    log =
      capture_log([level: :warning], fn ->
        assert :ok = LicenseEnforcer.enforce_startup!()
      end)

    assert_received :licensing_inspected
    assert log =~ "Node-agent startup license warning"
    assert log =~ "No local license bundle is installed."
  end

  test ":hard aborts startup for non-valid states", %{previous_runtime: previous_runtime} do
    Process.put(
      :license_status,
      %Orchard.Licensing{
        state: :expired,
        message: "License bundle has expired.",
        bundle_path: "/tmp/current.json"
      }
    )

    put_runtime(previous_runtime, license_enforcement: :hard)

    assert_raise RuntimeError,
                 ~r/Node-agent startup blocked by licensing: License bundle has expired\./,
                 fn ->
                   LicenseEnforcer.enforce_startup!()
                 end

    assert_received :licensing_inspected
  end

  test "valid status allows startup in hard mode without warning", %{
    previous_runtime: previous_runtime
  } do
    Process.put(
      :license_status,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json"
      }
    )

    put_runtime(previous_runtime, license_enforcement: :hard)

    log =
      capture_log([level: :warning], fn ->
        assert :ok = LicenseEnforcer.enforce_startup!()
      end)

    assert_received :licensing_inspected
    assert log == ""
  end

  test "invalid enforcement values fail fast before license inspection", %{
    previous_runtime: previous_runtime
  } do
    put_runtime(previous_runtime, license_enforcement: :sometimes)

    assert_raise RuntimeError, ~r/Invalid license enforcement mode: :sometimes/, fn ->
      LicenseEnforcer.enforce_startup!()
    end

    refute_received :licensing_inspected
  end

  defp put_runtime(previous_runtime, overrides) do
    runtime =
      previous_runtime
      |> Keyword.merge(overrides)
      |> Keyword.put(:licensing_impl, Orchard.Node.LicenseEnforcerTest.LicensingSpy)

    Application.put_env(:orchard_node_agent, :runtime, runtime)
  end
end
