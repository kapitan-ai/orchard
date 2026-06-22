defmodule Orchard.Node.RuntimeEnvValidationTest do
  use ExUnit.Case, async: false

  @tracked_env_vars [
    "RELEASE_NAME",
    "MIX_RELEASE_NAME",
    "ORCHARD_SUPPORT_ROOT",
    "ORCHARD_WORKER_BACKEND",
    "ORCHARD_WORKER_GENERATION_MODE",
    "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL",
    "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL",
    "ORCHARD_WORKER_MEMORY_BUDGET_MODE",
    "ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION",
    "ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES"
  ]

  setup do
    snapshot = Map.new(@tracked_env_vars, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_GENERATION_MODE in prod" do
    assert_raise RuntimeError, ~r/ORCHARD_WORKER_GENERATION_MODE must be stream\|batch/, fn ->
      read_runtime_config!(%{"ORCHARD_WORKER_GENERATION_MODE" => "invalid"})
    end
  end

  test "runtime.exs rejects unsupported ORCHARD_WORKER_MEMORY_BUDGET_MODE=enforce in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_WORKER_MEMORY_BUDGET_MODE must be disabled\|observe \(enforce not yet supported\)/,
                 fn ->
                   read_runtime_config!(%{"ORCHARD_WORKER_MEMORY_BUDGET_MODE" => "enforce"})
                 end
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL=0 in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL must be auto or >= 1/,
                 fn ->
                   read_runtime_config!(%{
                     "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL" => "0"
                   })
                 end
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL=0 in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL must be >= 1/,
                 fn ->
                   read_runtime_config!(%{
                     "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL" => "0"
                   })
                 end
  end

  test "runtime.exs rejects out-of-range ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION must be > 0.0 and <= 1.0/,
                 fn ->
                   read_runtime_config!(%{"ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION" => "1.5"})
                 end
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES=-1 in prod" do
    assert_raise RuntimeError,
                 ~r/environment variable ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES must be an integer >= 0/,
                 fn ->
                   read_runtime_config!(%{"ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES" => "-1"})
                 end
  end

  test "runtime.exs no-override prod read keeps release-safe worker defaults" do
    runtime =
      read_runtime_config!(%{})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_generation_mode] == "batch"
    assert runtime[:worker_max_concurrent_requests_per_model] == "auto"
    assert runtime[:worker_auto_max_concurrent_requests_per_model] == 3
    assert runtime[:worker_memory_budget_mode] == "observe"
    assert runtime[:worker_memory_budget_utilization] == 0.90
    assert runtime[:worker_memory_budget_overhead_bytes] == 1_073_741_824
  end

  test "runtime.exs defaults stub backend generation to stream in prod" do
    runtime =
      read_runtime_config!(%{"ORCHARD_WORKER_BACKEND" => "stub"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_generation_mode] == "stream"
  end

  test "runtime.exs explicit generation mode overrides stub backend default in prod" do
    runtime =
      read_runtime_config!(%{
        "ORCHARD_WORKER_BACKEND" => "stub",
        "ORCHARD_WORKER_GENERATION_MODE" => "batch"
      })
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_generation_mode] == "batch"
  end

  test "dev.exs defaults stub backend generation to stream" do
    runtime =
      read_dev_config!(%{"ORCHARD_WORKER_BACKEND" => "stub"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_generation_mode] == "stream"
  end

  test "dev.exs explicit generation mode overrides stub backend default" do
    runtime =
      read_dev_config!(%{
        "ORCHARD_WORKER_BACKEND" => "stub",
        "ORCHARD_WORKER_GENERATION_MODE" => "batch"
      })
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_generation_mode] == "batch"
  end

  test "runtime.exs accepts valid worker generation and memory settings in prod" do
    config =
      read_runtime_config!(%{
        "ORCHARD_WORKER_GENERATION_MODE" => "batch",
        "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL" => "2",
        "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL" => "4",
        "ORCHARD_WORKER_MEMORY_BUDGET_MODE" => "observe",
        "ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION" => "0.75",
        "ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES" => "268435456"
      })

    runtime =
      config
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_generation_mode] == "batch"
    assert runtime[:worker_max_concurrent_requests_per_model] == 2
    assert runtime[:worker_auto_max_concurrent_requests_per_model] == 4
    assert runtime[:worker_memory_budget_mode] == "observe"
    assert runtime[:worker_memory_budget_utilization] == 0.75
    assert runtime[:worker_memory_budget_overhead_bytes] == 268_435_456
  end

  defp read_runtime_config!(overrides) do
    support_root = Path.join(System.tmp_dir!(), "orchard-runtime-env-validation")

    base = %{
      "RELEASE_NAME" => "orchard_node_agent",
      "MIX_RELEASE_NAME" => nil,
      "ORCHARD_SUPPORT_ROOT" => support_root
    }

    base
    |> Map.merge(overrides)
    |> put_config_env!()

    Config.Reader.read!(runtime_config_path(), env: :prod)
  end

  defp read_dev_config!(overrides) do
    put_config_env!(overrides)

    Config.Reader.read!(dev_config_path(), env: :dev)
  end

  defp put_config_env!(env) do
    Enum.each(@tracked_env_vars, &System.delete_env/1)

    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp runtime_config_path do
    Path.expand("../../../../../config/runtime.exs", __DIR__)
  end

  defp dev_config_path do
    Path.expand("../../../../../config/dev.exs", __DIR__)
  end
end
