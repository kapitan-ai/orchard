defmodule Orchard.Dispatch.ColdStartBenchmarkTest do
  @moduledoc """
  Manual benchmark for cold-start latency measurement.

  Measures first-request latency with real controller→node-agent dispatch.
  Runs three prompt classes (p50/p500/p2000) and captures timing log output.

  This test is excluded from CI and must be run explicitly:
      ORCHARD_MLX_BENCH_MODEL_PATH=/path/to/bundle mix test --only mlx_benchmark

  The test asserts operational invariants only (no latency thresholds).
  Timing data is printed to stdout for manual analysis.

  Based on smoke-mlx.sh patterns and dispatch_test.exs patterns.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.Node.ModelManager

  # Runtime gating: always compile, skip at runtime if env var missing
  # This avoids compile-time fragility with MIX_ENV=benchmark

  # Prompt classes: approximate token counts (actual depends on tokenizer)
  @prompt_classes [
    {:p50, ~s(The capital of France is), 5},
    {:p500, String.duplicate("hello ", 100) <> "The capital is", 102},
    {:p2000, String.duplicate("word ", 400) <> "The capital is", 402}
  ]

  setup_all do
    case System.get_env("ORCHARD_MLX_BENCH_MODEL_PATH") do
      nil ->
        {:skip, "Set ORCHARD_MLX_BENCH_MODEL_PATH to run MLX cold-start benchmark"}

      path ->
        # Reset node-agent state to ensure cold start
        ModelManager.reset()

        bundle = stage_test_bundle(path)

        on_exit(fn ->
          # Only delete Orchard-owned transient paths
          # NEVER delete the user's bundle (source_bundle_path)
          # Guard against path aliasing: skip any cleanup path that equals or contains source
          source_real = Path.expand(bundle.source_bundle_path)

          for path <- bundle.cleanup_paths do
            cleanup_real = Path.expand(path)

            # Skip if cleanup path equals source, or if source is inside cleanup path
            unless cleanup_real == source_real or
                     String.starts_with?(source_real, cleanup_real <> "/") do
              File.rm_rf(path)
            end
          end
        end)

        {:ok, bundle: bundle}
    end
  end

  describe "cold-start benchmark" do
    @tag :mlx_benchmark
    @tag timeout: :infinity
    test "runs cold/warm dispatches for all prompt classes", %{bundle: bundle} do
      model_id = bundle.manifest_data["model_id"]
      version = bundle.manifest_data["version"]
      model_load = model_load_request(bundle, model_id, version)

      IO.puts("")
      IO.puts(String.duplicate("=", 70))
      IO.puts("Cold-start benchmark")
      IO.puts("Bundle: #{bundle.source_bundle_path}")
      IO.puts("Model: #{model_id}@#{version}")
      IO.puts(String.duplicate("=", 70))
      IO.puts("")

      IO.puts(
        String.pad_trailing("Class", 8) <>
          String.pad_trailing("Cold(ms)", 12) <>
          String.pad_trailing("Warm(ms)", 12) <>
          String.pad_trailing("Loaded", 10) <>
          "Outcome"
      )

      IO.puts(String.duplicate("-", 60))

      for {class_name, prompt, input_tokens} <- @prompt_classes do
        # COLD RUN: reset model manager to force fresh load
        ModelManager.reset()

        {cold_log, cold_result} = run_dispatch(bundle, model_id, version, prompt, input_tokens)

        # Parse timing log for cold run
        cold_timing = parse_dispatch_timing(cold_log)
        assert cold_timing.outcome == "ok", "cold run should succeed"
        assert cold_timing.model_already_loaded == "false", "cold run should load model"

        # WARM RUN: model already loaded from cold run
        {warm_log, warm_result} = run_dispatch(bundle, model_id, version, prompt, input_tokens)

        # Parse timing log for warm run
        warm_timing = parse_dispatch_timing(warm_log)
        assert warm_timing.outcome == "ok", "warm run should succeed"
        assert warm_timing.model_already_loaded == "true", "warm run should reuse model"

        # Print summary row
        IO.puts(
          String.pad_trailing("#{class_name}", 8) <>
            String.pad_trailing("#{cold_timing.accepted_to_first_delta_ms}", 12) <>
            String.pad_trailing("#{warm_timing.accepted_to_first_delta_ms}", 12) <>
            String.pad_trailing("#{cold_timing.ensure_model_loaded_ms}", 10) <>
            "#{cold_timing.outcome}"
        )

        # Verify both dispatches returned success
        assert {:ok, _events} = cold_result
        assert {:ok, _events} = warm_result
      end

      IO.puts(String.duplicate("=", 70))
      IO.puts("")

      # Verify timing logs were emitted for all runs
      assert true, "benchmark completed successfully"
    end

    test "dispatch_timing log format is parseable", %{bundle: bundle} do
      ModelManager.reset()

      model_id = bundle.manifest_data["model_id"]
      version = bundle.manifest_data["version"]
      prompt = "hello"

      {log, result} = run_dispatch(bundle, model_id, version, prompt, 1)

      assert {:ok, events} = result
      assert length(events) >= 1

      # Actually parse the log and verify required fields are present
      timing = parse_dispatch_timing(log)
      assert timing.request_id != "missing", "request_id should be present"
      assert timing.model_id != "missing", "model_id should be present"
      assert timing.input_tokens != "missing", "input_tokens should be present"
      assert timing.model_already_loaded in ["true", "false", "unknown"]
      assert timing.outcome == "ok", "dispatch should succeed"
      refute timing.anomaly == "delta_before_accepted", "timing anomaly detected"
    end

    test "cold start has model_already_loaded=false on first dispatch", %{bundle: bundle} do
      ModelManager.reset()

      model_id = bundle.manifest_data["model_id"]
      version = bundle.manifest_data["version"]
      prompt = "test"

      {log, _result} = run_dispatch(bundle, model_id, version, prompt, 1)

      timing = parse_dispatch_timing(log)
      assert timing.model_already_loaded == "false", "first dispatch should be cold"
      assert timing.ensure_model_loaded_ms != "na", "ensure_load should have duration"
    end

    test "warm start has model_already_loaded=true on second dispatch", %{bundle: bundle} do
      ModelManager.reset()

      model_id = bundle.manifest_data["model_id"]
      version = bundle.manifest_data["version"]
      prompt = "test"

      # First dispatch (cold)
      {_log1, _result1} = run_dispatch(bundle, model_id, version, prompt, 1)

      # Second dispatch (warm)
      {log2, _result2} = run_dispatch(bundle, model_id, version, prompt, 1)

      timing = parse_dispatch_timing(log2)
      assert timing.model_already_loaded == "true", "second dispatch should be warm"
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp run_dispatch(bundle, model_id, version, prompt, input_tokens) do
    # Generate ONE request_id for both schedule and execute - must match for event routing
    request_id = "req-bench-#{System.unique_integer([:positive])}"
    schedule = build_schedule(request_id)
    execute = execute_request(request_id, model_id, version, prompt, input_tokens)
    model_load = model_load_request(bundle, model_id, version)

    # Use with_log/2 to capture both result and log output at info level
    # Returns {result, log} so we swap to match our {log, result} contract
    {result, log} =
      with_log([level: :info], fn ->
        RequestDispatcher.dispatch(schedule, execute, model_load)
      end)

    {log, result}
  end

  defp parse_dispatch_timing(log_text) do
    # Parse dispatch_timing log line like:
    # dispatch_timing request_id=X model_id=X version=X input_tokens=N model_already_loaded=true/false ...
    dispatch_line =
      log_text
      |> String.split("\n")
      |> Enum.find(&String.contains?(&1, "dispatch_timing"))

    unless dispatch_line do
      flunk("No dispatch_timing log line found in captured output:\n#{log_text}")
    end

    # Extract key=value pairs
    # Note: terminal_detail may contain spaces (from inspect/1), so we skip parsing it
    %{
      request_id: extract_field(dispatch_line, "request_id"),
      model_id: extract_field(dispatch_line, "model_id"),
      version: extract_field(dispatch_line, "version"),
      input_tokens: extract_field(dispatch_line, "input_tokens"),
      model_already_loaded: extract_field(dispatch_line, "model_already_loaded"),
      ensure_model_loaded_ms: extract_field(dispatch_line, "ensure_model_loaded_ms"),
      accepted_to_first_delta_ms: extract_field(dispatch_line, "accepted_to_first_delta_ms"),
      accepted_to_terminal_ms: extract_field(dispatch_line, "accepted_to_terminal_ms"),
      terminal_kind: extract_field(dispatch_line, "terminal_kind"),
      terminal_source: extract_field(dispatch_line, "terminal_source"),
      outcome: extract_field(dispatch_line, "outcome"),
      event_count: extract_field(dispatch_line, "event_count"),
      anomaly: extract_field(dispatch_line, "anomaly"),
      # terminal_detail may contain spaces from inspect/1, skip it for benchmark parsing
      terminal_detail: "na"
    }
  end

  defp extract_field(line, field_name) do
    # Parse fields without spaces (all dispatch_timing fields except terminal_detail)
    case Regex.run(~r/#{field_name}=([^\s]+)/, line) do
      [_, value] -> value
      nil -> "missing"
    end
  end

  defp build_schedule(request_id) do
    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 30_000,
      model_load_timeout_ms: 120_000
    }
  end

  defp execute_request(request_id, model_id, version, prompt, input_tokens) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "bench-session",
      model_id: model_id,
      version: version,
      rendered_prompt_utf8: prompt,
      input_tokens: input_tokens
    }
  end

  defp model_load_request(bundle, model_id, version) do
    %EnsureModelLoadedRequest{
      node_id: "local",
      model_id: model_id,
      version: version,
      artifact_sha256: bundle.hash,
      artifact_source_uri: bundle.source_uri,
      deadline_unix_ms: System.system_time(:millisecond) + 120_000
    }
  end

  defp stage_test_bundle(path) do
    # User-provided bundle path - NEVER delete this
    source_bundle_path = Path.expand(path)

    manifest_json = File.read!(Path.join(source_bundle_path, "manifest.json"))
    manifest_data = Jason.decode!(manifest_json)

    # Extract required fields for deriving Orchard-owned paths
    model_id = manifest_data["model_id"] || raise "manifest.json missing model_id"
    version = manifest_data["version"] || raise "manifest.json missing version"

    {:ok, hash} = ArtifactBundle.tree_sha256(source_bundle_path)

    source_uri = "file://#{source_bundle_path}"

    # Orchard-owned cleanup paths only - model-specific cache only
    # Note: .staging is too broad (deletes entire tree), skip it
    cache_path = Path.join([Orchard.Node.models_root(), model_id, version])

    %{
      # External input (read-only, never deleted)
      source_bundle_path: source_bundle_path,
      source_uri: source_uri,
      hash: hash,
      manifest_data: manifest_data,

      # Orchard-owned paths (safe to delete - model-specific only)
      cache_path: cache_path,
      cleanup_paths: [cache_path]
    }
  end
end
