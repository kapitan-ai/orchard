defmodule Orchard.Config.SourceTensorFoldConfigTest do
  # SPEC.md §7.2.9: the default-off TensorFold source experiment is configured
  # through documented source-dev variables and profile files.
  use ExUnit.Case, async: false

  @dev_config Path.expand("../../../../../config/dev.exs", __DIR__)
  @repo_root Path.expand("../../../../..", __DIR__)

  setup do
    snapshot = System.get_env() |> Enum.filter(&config_env?/1) |> Map.new()
    root = Path.join(System.tmp_dir!(), "orchard-tf-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      clear_config_env!()
      Enum.each(snapshot, fn {key, value} -> System.put_env(key, value) end)
    end)

    controller = write_json!(root, "controller.json", %{"profile_id" => "p", "x" => nil})
    node = write_json!(root, "node.json", %{"profile_id" => "p", "offer_timeout_ms" => 1000})

    worker =
      write_json!(root, "worker.json", %{"profile" => %{}, "bounds" => %{}, "native" => %{}})

    %{root: root, controller: controller, node: node, worker: worker}
  end

  test "the experiment is off and ordinary Worker defaults are unchanged by default" do
    config = read_config!("all_in_one", %{})
    runtime = config |> get_in([:orchard_node_agent, :runtime])

    assert get_in(config, [:orchard_controller, :tensorfold_experiment_profile]) == nil
    assert get_in(config, [:orchard_node_agent, :tensorfold_experiment_profile]) == nil
    assert runtime[:worker_backend] == "mlx"
    assert runtime[:worker_executable] =~ "orchard_worker_mlx/bin/orchard-worker-mlx"

    assert Keyword.take(runtime, [
             :worker_prefix_cache_mode,
             :worker_prefix_cache_max_entries,
             :worker_prefix_cache_max_bytes,
             :worker_memory_budget_mode,
             :worker_memory_budget_utilization,
             :worker_memory_budget_overhead_bytes
           ]) == [
             worker_prefix_cache_mode: "kv",
             worker_prefix_cache_max_entries: 8,
             worker_prefix_cache_max_bytes: 0,
             worker_memory_budget_mode: "observe",
             worker_memory_budget_utilization: 0.9,
             worker_memory_budget_overhead_bytes: 1_073_741_824
           ]
  end

  test "the tensorfold backend derives the only Worker settings the bridge accepts", ctx do
    config = read_config!("node_agent", tensorfold_node_env(ctx))
    runtime = get_in(config, [:orchard_node_agent, :runtime])

    assert runtime[:worker_backend] == "tensorfold"

    assert runtime[:worker_executable] ==
             Path.join(@repo_root, "native/orchard_tensorfold_http/bin/orchard-worker-tensorfold")

    assert Keyword.take(runtime, [
             :worker_prefix_cache_mode,
             :worker_prefix_cache_max_entries,
             :worker_prefix_cache_max_bytes,
             :worker_generation_mode,
             :worker_max_concurrent_requests_per_model,
             :worker_auto_max_concurrent_requests_per_model,
             :worker_memory_budget_mode,
             :worker_memory_budget_utilization,
             :worker_memory_budget_overhead_bytes
           ]) == [
             worker_prefix_cache_mode: "disabled",
             worker_prefix_cache_max_entries: 8,
             worker_prefix_cache_max_bytes: 0,
             worker_generation_mode: "stream",
             worker_max_concurrent_requests_per_model: 1,
             worker_auto_max_concurrent_requests_per_model: 1,
             worker_memory_budget_mode: "disabled",
             worker_memory_budget_utilization: 0.9,
             worker_memory_budget_overhead_bytes: 0
           ]

    assert get_in(config, [:orchard_node_agent, :tensorfold_experiment_profile]) == %{
             "profile_id" => "p",
             "offer_timeout_ms" => 1000
           }
  end

  test "explicit compatible settings are accepted and incompatible ones fail", ctx do
    env = tensorfold_node_env(ctx)

    assert read_config!("node_agent", Map.put(env, "ORCHARD_WORKER_GENERATION_MODE", "stream"))

    for {var, value} <- [
          {"ORCHARD_WORKER_PREFIX_CACHE_MODE", "kv"},
          {"ORCHARD_WORKER_PREFIX_CACHE_MAX_BYTES", "1"},
          {"ORCHARD_WORKER_GENERATION_MODE", "batch"},
          {"ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", "auto"},
          {"ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", "2"},
          {"ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL", "3"},
          {"ORCHARD_WORKER_MEMORY_BUDGET_MODE", "observe"},
          {"ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION", "0.8"},
          {"ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES", "1"}
        ] do
      assert_raise RuntimeError,
                   ~r/#{var} must be .* when ORCHARD_WORKER_BACKEND=tensorfold/,
                   fn ->
                     read_config!("node_agent", Map.put(env, var, value))
                   end
    end
  end

  test "each role reads only its own profile files", ctx do
    missing = Path.join(ctx.root, "missing.json")

    controller =
      read_config!("controller", %{
        "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE" => ctx.controller,
        "ORCHARD_TENSORFOLD_NODE_PROFILE_FILE" => missing,
        "ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE" => missing
      })

    assert get_in(controller, [:orchard_controller, :tensorfold_experiment_profile]) ==
             %{"profile_id" => "p", "x" => nil}

    assert get_in(controller, [:orchard_node_agent, :tensorfold_experiment_profile]) == nil

    node =
      read_config!(
        "node_agent",
        Map.put(tensorfold_node_env(ctx), "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE", missing)
      )

    assert get_in(node, [:orchard_controller, :tensorfold_experiment_profile]) == nil

    all_in_one =
      read_config!(
        "all_in_one",
        Map.put(
          tensorfold_node_env(ctx),
          "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE",
          ctx.controller
        )
      )

    assert get_in(all_in_one, [:orchard_controller, :tensorfold_experiment_profile])
    assert get_in(all_in_one, [:orchard_node_agent, :tensorfold_experiment_profile])
  end

  test "the Node and Worker profiles may share the Controller file", ctx do
    shared =
      write_json!(ctx.root, "shared.json", %{"profile_id" => "p", "authorized_node_ids" => ["n"]})

    config =
      read_config!(
        "all_in_one",
        tensorfold_node_env(ctx)
        |> Map.put("ORCHARD_TENSORFOLD_NODE_PROFILE_FILE", shared)
        |> Map.put("ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE", shared)
      )

    assert get_in(config, [:orchard_controller, :tensorfold_experiment_profile]) ==
             get_in(config, [:orchard_node_agent, :tensorfold_experiment_profile])
  end

  test "the tensorfold backend requires the Node and Worker profiles", ctx do
    env = tensorfold_node_env(ctx)

    for var <- ~w(ORCHARD_TENSORFOLD_NODE_PROFILE_FILE ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE) do
      assert_raise RuntimeError,
                   ~r/#{var} is required when ORCHARD_WORKER_BACKEND=tensorfold/,
                   fn ->
                     read_config!("node_agent", Map.delete(env, var))
                   end
    end
  end

  test "Node or Worker profiles without the tensorfold backend fail", ctx do
    for var <- ~w(ORCHARD_TENSORFOLD_NODE_PROFILE_FILE ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE) do
      assert_raise RuntimeError, ~r/#{var} requires ORCHARD_WORKER_BACKEND=tensorfold/, fn ->
        read_config!("node_agent", %{var => ctx.node})
      end
    end
  end

  test "unreadable, malformed and oversized profiles fail before startup", ctx do
    var = "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE"
    write = fn name, bytes -> Path.join(ctx.root, name) |> tap(&File.write!(&1, bytes)) end

    cases = [
      {Path.join(ctx.root, "missing.json"), ~r/#{var} must name a readable JSON file/},
      {ctx.root, ~r/#{var} must name a readable JSON file/},
      {write.("empty.json", ""), ~r/#{var} contains invalid JSON/},
      {write.("bad.json", "{"), ~r/#{var} contains invalid JSON/},
      {write.("trailing.json", "{} {}"), ~r/#{var} contains invalid JSON/},
      {write.("array.json", "[1]"), ~r/#{var} must contain a JSON object/},
      {write.("big.json", "{}" <> String.duplicate(" ", 65_535)), ~r/#{var} exceeds 65536 bytes/}
    ]

    for {path, message} <- cases do
      assert_raise RuntimeError, message, fn ->
        read_config!("controller", %{var => path})
      end
    end

    limit = write.("limit.json", "{}" <> String.duplicate(" ", 65_534))
    assert read_config!("controller", %{var => limit})
  end

  test "the Worker profile must hold exactly the profile, bounds and native objects", ctx do
    for body <- [
          %{"profile" => %{}, "bounds" => %{}},
          %{"profile" => %{}, "bounds" => %{}, "native" => 1}
        ] do
      worker = write_json!(ctx.root, "w#{System.unique_integer([:positive])}.json", body)

      assert_raise RuntimeError, ~r/exactly the profile, bounds and native objects/, fn ->
        read_config!(
          "node_agent",
          Map.put(tensorfold_node_env(ctx), "ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE", worker)
        )
      end
    end
  end

  test "a Controller profile requires compatible inference settings", ctx do
    limited =
      write_json!(ctx.root, "limited.json", %{"profile_id" => "p", "max_request_seconds" => 90})

    env = %{
      "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE" => limited,
      "ORCHARD_REQUEST_TIMEOUT_MS" => "90000",
      "ORCHARD_MAX_REQUEST_DEADLINE_MS" => "90000"
    }

    assert read_config!("controller", env)

    for {overrides, message} <- [
          {%{"ORCHARD_TOKENIZER_SAFE_MODE" => "on"}, ~r/ORCHARD_TOKENIZER_SAFE_MODE must be off/},
          {%{"ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED" => "true"},
           ~r/LIVE_FINGERPRINT_MATCH_ENABLED must be false/},
          {%{"ORCHARD_MAX_REQUEST_DEADLINE_MS" => "90001"},
           ~r/ORCHARD_MAX_REQUEST_DEADLINE_MS \(90001\) must be <= the profile/}
        ] do
      assert_raise RuntimeError, message, fn ->
        read_config!("controller", Map.merge(env, overrides))
      end
    end

    invalid = write_json!(ctx.root, "invalid.json", %{"max_request_seconds" => "90"})

    assert_raise RuntimeError, ~r/max_request_seconds must be a positive number/, fn ->
      read_config!("controller", %{env | "ORCHARD_TENSORFOLD_CONTROLLER_PROFILE_FILE" => invalid})
    end
  end

  defp tensorfold_node_env(ctx) do
    %{
      "ORCHARD_WORKER_BACKEND" => "tensorfold",
      "ORCHARD_TENSORFOLD_NODE_PROFILE_FILE" => ctx.node,
      "ORCHARD_TENSORFOLD_WORKER_PROFILE_FILE" => ctx.worker
    }
  end

  defp write_json!(root, name, map) do
    path = Path.join(root, name)
    File.write!(path, Jason.encode!(map))
    path
  end

  defp read_config!(role, overrides) do
    clear_config_env!()

    overrides
    |> Map.put("ORCHARD_SOURCE_DEV_ROLE", role)
    |> Map.put("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT", "grpc")
    |> Enum.each(fn {key, value} -> System.put_env(key, value) end)

    Config.Reader.read!(@dev_config, env: :dev)
  end

  defp clear_config_env! do
    System.get_env()
    |> Enum.filter(&config_env?/1)
    |> Enum.each(fn {key, _} -> System.delete_env(key) end)
  end

  defp config_env?({key, _value}) do
    String.starts_with?(key, ["ORCHARD_", "PG"]) or
      key in ~w(DATABASE_URL MIX_RELEASE_NAME PORT RELEASE_NAME SECRET_KEY_BASE)
  end
end
