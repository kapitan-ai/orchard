defmodule Orchard.Node.RuntimeEnvValidationTest do
  use ExUnit.Case, async: false

  @config_env_vars [
    "DATABASE_URL",
    "ECTO_IPV6",
    "HF_TOKEN",
    "MIX_RELEASE_NAME",
    "PGDATABASE",
    "PGHOST",
    "PGPASSWORD",
    "PGPORT",
    "PGUSER",
    "PHX_HOST",
    "POOL_SIZE",
    "PORT",
    "RELEASE_NAME",
    "SECRET_KEY_BASE"
  ]

  setup do
    snapshot =
      System.get_env()
      |> Enum.filter(fn {key, _value} -> config_env_key?(key) end)
      |> Map.new()

    on_exit(fn -> restore_config_env!(snapshot) end)

    :ok
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_GENERATION_MODE in prod" do
    assert_raise RuntimeError, ~r/ORCHARD_WORKER_GENERATION_MODE must be stream\|batch/, fn ->
      read_runtime_config!(%{"ORCHARD_WORKER_GENERATION_MODE" => "invalid"})
    end
  end

  test "runtime.exs accepts ORCHARD_WORKER_MEMORY_BUDGET_MODE=enforce in prod" do
    runtime =
      read_runtime_config!(%{"ORCHARD_WORKER_MEMORY_BUDGET_MODE" => "enforce"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_memory_budget_mode] == "enforce"
  end

  test "runtime.exs enables forced full model verification in prod" do
    runtime =
      read_runtime_config!(%{"ORCHARD_FORCE_FULL_MODEL_VERIFICATION" => "true"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:force_full_model_verification]
  end

  test "runtime.exs rejects an invalid forced-verification boolean in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_FORCE_FULL_MODEL_VERIFICATION must be a boolean/,
                 fn ->
                   read_runtime_config!(%{"ORCHARD_FORCE_FULL_MODEL_VERIFICATION" => "sometimes"})
                 end
  end

  test "runtime.exs rejects invalid ORCHARD_WORKER_MEMORY_BUDGET_MODE in prod" do
    assert_raise RuntimeError,
                 ~r/ORCHARD_WORKER_MEMORY_BUDGET_MODE must be disabled\|observe\|enforce/,
                 fn ->
                   read_runtime_config!(%{"ORCHARD_WORKER_MEMORY_BUDGET_MODE" => "aggressive"})
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
    refute runtime[:force_full_model_verification]
  end

  test "runtime.exs preserves packaged BEAM default without requiring gRPC identity" do
    runtime =
      read_runtime_config!(%{})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:grpc_security] == :plaintext_compatibility
  end

  test "runtime.exs rejects plaintext gRPC bound to a non-loopback listen host" do
    assert_raise RuntimeError, ~r/exposes an unauthenticated plaintext gRPC/, fn ->
      read_runtime_config!(%{"ORCHARD_NODE_AGENT_LISTEN_HOST" => "0.0.0.0"})
    end
  end

  test "runtime.exs allows a non-loopback listen host under gRPC mutual TLS" do
    runtime =
      read_runtime_config!(%{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "grpc",
        "ORCHARD_NODE_AGENT_LISTEN_HOST" => "0.0.0.0"
      })
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:grpc_security] == :mutual_tls
    assert runtime[:listen_address][:host] == "0.0.0.0"
  end

  test "runtime.exs requires enrolled mTLS for packaged gRPC compatibility mode" do
    identity_root = Path.join(System.tmp_dir!(), "orchard-runtime-node-identity")

    runtime =
      read_runtime_config!(%{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "grpc",
        "ORCHARD_NODE_IDENTITY_ROOT" => identity_root
      })
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:grpc_security] == :mutual_tls
    assert runtime[:node_identity_root] == identity_root
  end

  test "runtime.exs enables production grant bootstrap only with an explicit descriptor" do
    identity_root = Path.join(System.tmp_dir!(), "orchard-runtime-node-identity")
    descriptor_path = Path.join(identity_root, "peer-grant-descriptor.json")
    manifest_path = Path.join(identity_root, "launch.json")
    node_name = "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20"

    node_agent =
      read_runtime_config!(%{
        "ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR" => descriptor_path,
        "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST" => manifest_path,
        "ORCHARD_BEAM_NODE_NAME" => node_name,
        "ORCHARD_NODE_IDENTITY_ROOT" => identity_root
      })
      |> Keyword.fetch!(:orchard_node_agent)

    assert node_agent[:beam_peer_grants] == [
             enabled: true,
             identity_root: identity_root,
             descriptor_path: descriptor_path,
             node_beam_name: node_name,
             manifest_path: manifest_path
           ]

    disabled =
      read_runtime_config!(%{})
      |> Keyword.fetch!(:orchard_node_agent)

    assert disabled[:beam_peer_grants] == [enabled: false]
  end

  test "SPEC.md §7.5.0 production grant bootstrap requires its preflight launch manifest" do
    identity_root = Path.join(System.tmp_dir!(), "orchard-runtime-node-identity")
    descriptor_path = Path.join(identity_root, "peer-grant-descriptor.json")

    assert_raise RuntimeError,
                 ~r/ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST is required/,
                 fn ->
                   read_runtime_config!(%{
                     "ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR" => descriptor_path,
                     "ORCHARD_BEAM_NODE_NAME" =>
                       "orchard_node_agent_cccccccccccc4ccc8ccccccccccccccc@10.0.0.20",
                     "ORCHARD_NODE_IDENTITY_ROOT" => identity_root
                   })
                 end
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

  test "dev.exs enables forced full model verification" do
    runtime =
      read_dev_config!(%{"ORCHARD_FORCE_FULL_MODEL_VERIFICATION" => "true"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:force_full_model_verification]
  end

  test "dev.exs keeps worker sockets under a short worktree-specific root" do
    runtime =
      read_dev_config!(%{})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert String.starts_with?(runtime[:worker_socket_dir], "/tmp/od-")
    assert String.ends_with?(runtime[:worker_socket_dir], "/ws")
  end

  test "dev.exs parses ORCHARD_WORKER_SOCKET_DIR" do
    runtime =
      read_dev_config!(%{"ORCHARD_WORKER_SOCKET_DIR" => "/tmp/orchard-worker-sockets"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_socket_dir] == "/tmp/orchard-worker-sockets"
  end

  test "dev.exs treats an empty worker socket override as unset" do
    runtime =
      read_dev_config!(%{"ORCHARD_WORKER_SOCKET_DIR" => ""})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert String.starts_with?(runtime[:worker_socket_dir], "/tmp/od-")
  end

  test "dev.exs resolves relative worker paths from the repository root" do
    runtime =
      read_dev_config!(%{
        "ORCHARD_WORKER_SOCKET_DIR" => "tmp/worker-sockets",
        "ORCHARD_WORKER_EXECUTABLE" => "native/worker"
      })
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    repo_root = Path.expand("../../../../..", __DIR__)
    assert runtime[:worker_socket_dir] == Path.join(repo_root, "tmp/worker-sockets")
    assert runtime[:worker_executable] == Path.join(repo_root, "native/worker")
  end

  test "dev.exs rejects worker paths containing whitespace" do
    assert_raise RuntimeError, ~r/must not contain whitespace or control characters/, fn ->
      read_dev_config!(%{"ORCHARD_WORKER_SOCKET_DIR" => "/tmp/worker sockets"})
    end
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

  test "dev.exs evaluation ignores ambient config env outside overrides" do
    System.put_env("PORT", "not-a-port")
    System.put_env("ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES", "0")

    runtime =
      read_dev_config!(%{"ORCHARD_WORKER_BACKEND" => "stub"})
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_generation_mode] == "stream"
  end

  test "dev.exs node-agent-only evaluation ignores invalid PGPORT" do
    config =
      read_dev_config!(%{
        "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT" => "grpc",
        "ORCHARD_SOURCE_DEV_ROLE" => "node_agent",
        "PGPORT" => "+5432"
      })

    runtime =
      config
      |> Keyword.fetch!(:orchard_node_agent)
      |> Keyword.fetch!(:runtime)

    repo =
      config
      |> Keyword.fetch!(:orchard_controller)
      |> Keyword.fetch!(Orchard.Repo)

    assert runtime[:listen_address][:port] == 50_071
    assert repo[:port] == 5432
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
    clear_config_env!()

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

  defp restore_config_env!(snapshot) do
    clear_config_env!()
    Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
  end

  defp clear_config_env! do
    System.get_env()
    |> Map.keys()
    |> Enum.filter(&config_env_key?/1)
    |> Enum.each(&System.delete_env/1)
  end

  defp config_env_key?(key) do
    key in @config_env_vars or String.starts_with?(key, "ORCHARD_")
  end
end
