defmodule Orchard.Node.WorkerLaunchPolicyTest do
  # SPEC.md 7.5.3 and OpenSpec harden-stock-strict-prefix-checkpoints:
  # strict-prefix checkpoints are enabled per exact model_id@version.
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.WorkerLaunchPolicy

  @globals [
    backend: "mlx",
    prefix_cache_mode: "kv",
    prefix_cache_max_entries: 8,
    prefix_cache_max_bytes: 0,
    generation_mode: "batch",
    max_concurrent_generations: "auto",
    auto_max_concurrent_generations: 3,
    memory_budget_mode: "observe",
    memory_budget_utilization: 0.9,
    memory_budget_overhead_bytes: 1_073_741_824
  ]

  @strict_entry %{
    "model_id" => "org/qwen",
    "version" => "v1",
    "prefix_cache_mode" => "strict_prefix",
    "generation_mode" => "stream",
    "memory_budget_mode" => "observe",
    "strict_prefix" => %{"slots" => 1, "slot_bytes" => 1024, "budget_bytes" => 2048}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "launch-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write!(dir, document) do
    path = Path.join(dir, "overrides.json")
    File.write!(path, if(is_binary(document), do: document, else: encode(document)))
    path
  end

  defp encode(document), do: document |> :json.encode() |> IO.iodata_to_binary()

  defp load!(dir, models),
    do: WorkerLaunchPolicy.load(write!(dir, %{"version" => 1, "models" => models}))

  defp ref(model_id, version), do: %ModelRef{model_id: model_id, version: version}

  test "no file means no overrides" do
    assert WorkerLaunchPolicy.load(nil) == {:ok, %{}}
    assert WorkerLaunchPolicy.load("") == {:ok, %{}}
  end

  test "global settings the resolver does not own pass through unchanged" do
    # The Worker CLI, not the resolver, refuses a stub backend in batch mode,
    # as it did before per-model settings existed.
    globals = Keyword.merge(@globals, backend: "stub", generation_mode: "batch")

    assert {:ok, options} = WorkerLaunchPolicy.resolve(ref("org/any", "v1"), %{}, globals)
    assert Keyword.delete(options, :launch_policy_version) == globals
  end

  test "a model without an override keeps the global settings", %{dir: dir} do
    {:ok, overrides} = load!(dir, [@strict_entry])

    assert {:ok, options} =
             WorkerLaunchPolicy.resolve(ref("org/other", "v1"), overrides, @globals)

    assert Keyword.delete(options, :launch_policy_version) == @globals
    assert options[:launch_policy_version] == WorkerLaunchPolicy.policy_version()
  end

  test "the exact model_id@version gets its strict-prefix policy", %{dir: dir} do
    {:ok, overrides} = load!(dir, [@strict_entry])

    assert {:ok, options} = WorkerLaunchPolicy.resolve(ref("org/qwen", "v1"), overrides, @globals)
    assert options[:prefix_cache_mode] == "strict_prefix"
    assert options[:generation_mode] == "stream"
    assert options[:memory_budget_mode] == "observe"
    assert options[:strict_prefix_slots] == 1
    assert options[:strict_prefix_slot_bytes] == 1024
    assert options[:strict_prefix_budget_bytes] == 2048
    assert options[:prefix_cache_max_entries] == 8

    # A different version of the same model is not matched.
    assert {:ok, other} = WorkerLaunchPolicy.resolve(ref("org/qwen", "v2"), overrides, @globals)
    assert other[:prefix_cache_mode] == "kv"
  end

  test "strict-prefix settings never rewrite other settings to make a policy valid", %{dir: dir} do
    entry = Map.drop(@strict_entry, ["generation_mode"])
    {:ok, overrides} = load!(dir, [entry])

    assert {:error, message} =
             WorkerLaunchPolicy.resolve(ref("org/qwen", "v1"), overrides, @globals)

    assert message =~ "org/qwen@v1: strict_prefix requires generation_mode stream"
  end

  for {name, change, expected} <- [
        {"a non-mlx backend", {:global, :backend, "stub"}, "requires the mlx backend"},
        {"enforce memory mode", {:entry, "memory_budget_mode", "enforce"},
         "requires memory_budget_mode observe"},
        {"disabled memory mode", {:entry, "memory_budget_mode", "disabled"},
         "requires memory_budget_mode observe"},
        {"a budget that cannot hold the slots",
         {:entry, "strict_prefix", %{"slots" => 3, "slot_bytes" => 1024, "budget_bytes" => 2048}},
         "cannot hold 3 slots"},
        {"missing byte settings", {:entry, "strict_prefix", %{"slots" => 1}},
         "requires strict_prefix.slot_bytes"}
      ] do
    test "resolve refuses a strict-prefix policy with #{name}", %{dir: dir} do
      {entry, globals} =
        case unquote(Macro.escape(change)) do
          {:global, key, value} -> {@strict_entry, Keyword.put(@globals, key, value)}
          {:entry, key, value} -> {Map.put(@strict_entry, key, value), @globals}
        end

      {:ok, overrides} = load!(dir, [entry])

      assert {:error, message} =
               WorkerLaunchPolicy.resolve(ref("org/qwen", "v1"), overrides, globals)

      assert message =~ unquote(expected)
      assert WorkerLaunchPolicy.validate_all(overrides, globals) == {:error, message}
    end
  end

  test "strict-prefix settings need the strict_prefix mode", %{dir: dir} do
    entry = Map.put(@strict_entry, "prefix_cache_mode", "kv")
    {:ok, overrides} = load!(dir, [entry])

    assert {:error, message} =
             WorkerLaunchPolicy.resolve(ref("org/qwen", "v1"), overrides, @globals)

    assert message =~ "require prefix_cache_mode strict_prefix"
  end

  test "an override can change modes for a non-strict model", %{dir: dir} do
    entry = %{"model_id" => "org/small", "version" => "v1", "prefix_cache_mode" => "disabled"}
    {:ok, overrides} = load!(dir, [entry])

    assert {:ok, options} =
             WorkerLaunchPolicy.resolve(ref("org/small", "v1"), overrides, @globals)

    assert options[:prefix_cache_mode] == "disabled"
    assert WorkerLaunchPolicy.validate_all(overrides, @globals) == :ok
  end

  for {name, models_or_document, expected} <- [
        {"invalid JSON", "{not json", "not valid JSON"},
        {"a wrong file version", %{"version" => 2, "models" => []}, "unsupported file version 2"},
        {"unknown top-level keys", %{"version" => 1, "models" => [], "extra" => 1},
         ~s(unknown top-level keys ["extra"])},
        {"a missing model id", [%{"version" => "v1"}], "non-empty model_id and version"},
        {"unknown entry keys", [Map.put(@strict_entry, "executable", "/bin/sh")],
         ~s(unknown keys ["executable"])},
        {"unknown strict keys", [put_in(@strict_entry, ["strict_prefix", "slotz"], 1)],
         ~s(unknown keys ["slotz"])},
        {"a bad mode", [Map.put(@strict_entry, "generation_mode", "turbo")],
         "generation_mode must be one of stream|batch"},
        {"a non-integer size", [put_in(@strict_entry, ["strict_prefix", "slot_bytes"], "1GiB")],
         "strict_prefix.slot_bytes must be an integer"},
        {"too many slots", [put_in(@strict_entry, ["strict_prefix", "slots"], 9)],
         "strict_prefix.slots must be between 1 and 8"},
        {"an empty reply marker", [put_in(@strict_entry, ["strict_prefix", "reply_marker"], "")],
         "reply_marker must be a non-empty string"},
        {"a duplicate model", [@strict_entry, @strict_entry], "duplicate entry for org/qwen@v1"}
      ] do
    test "load refuses #{name}", %{dir: dir} do
      document =
        case unquote(Macro.escape(models_or_document)) do
          models when is_list(models) -> %{"version" => 1, "models" => models}
          other -> other
        end

      assert {:error, message} = WorkerLaunchPolicy.load(write!(dir, document))
      assert message =~ unquote(expected)
    end
  end

  test "load reports an unreadable file", %{dir: dir} do
    assert {:error, message} = WorkerLaunchPolicy.load(Path.join(dir, "missing.json"))
    assert message =~ "cannot read"
  end
end
