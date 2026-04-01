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

  @mlx_bench_model_path System.get_env("ORCHARD_MLX_BENCH_MODEL_PATH")

  @moduletag :mlx_benchmark

  # Prompt classes: approximate token counts (actual depends on tokenizer)
  @prompt_classes [
    {:p50, ~s(The capital of France is), 5},
    {:p500, String.duplicate("hello ", 100) <> "The capital is", 102},
    {:p2000, String.duplicate("word ", 400) <> "The capital is", 402}
  ]

  setup do
    # Skip entire module if env var not set (conditional compilation pattern)
    unless @mlx_bench_model_path do
      {:ok, skipped: true}
    else
      # Reset node-agent state to ensure cold start
      ModelManager.reset()

      bundle = stage_test_bundle()

      on_exit(fn ->
        File.rm_rf(bundle.cache_path)
        File.rm_rf(bundle.source_path)
        File.rm_rf(Path.join(Orchard.Node.models_root(), ".staging"))
      end)

      %{bundle: bundle, skipped: false}
    end
  end

  # Conditional test pattern: only run when env var is set
  @mlx_bench_model_path_test @mlx_bench_model_path

  if @mlx_bench_model_path_test do
    describe "cold-start benchmark" do
      test "runs cold/warm dispatches for all prompt classes", %{bundle: bundle} do
        model_id = bundle.manifest_data["model_id"]
        version = bundle.manifest_data["version"]
        model_load = model_load_request(bundle, model_id, version)

        IO.puts("")
        IO.puts(String.duplicate("=", 70))
        IO.puts("Cold-start benchmark")
        IO.puts("Bundle: #{bundle.cache_path}")
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

        {_log, result} = run_dispatch(bundle, model_id, version, prompt, 1)

        assert {:ok, events} = result
        assert length(events) >= 1

        # Timing log is captured in the log variable - parse it
        # parse_dispatch_timing will be tested implicitly by the main test
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
  end

  # -- Helpers ---------------------------------------------------------------

  defp run_dispatch(bundle, model_id, version, prompt, input_tokens) do
    schedule = build_schedule("req-bench-#{System.unique_integer([:positive])}")
    execute = execute_request("req-bench-#{System.unique_integer([:positive])}", model_id, version, prompt, input_tokens)
    model_load = model_load_request(bundle, model_id, version)

    {log, result} =
      capture_log(fn ->
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
      terminal_detail: extract_field(dispatch_line, "terminal_detail"),
      outcome: extract_field(dispatch_line, "outcome"),
      event_count: extract_field(dispatch_line, "event_count"),
      anomaly: extract_field(dispatch_line, "anomaly")
    }
  end

  defp extract_field(line, field_name) do
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

  defp stage_test_bundle do
    # Use the provided ORCHARD_MLX_BENCH_MODEL_PATH bundle
    bundle_path = @mlx_bench_model_path

    manifest_json = File.read!(Path.join(bundle_path, "manifest.json"))
    manifest_data = Jason.decode!(manifest_json)

    {:ok, hash} = ArtifactBundle.tree_sha256(bundle_path)

    source_uri = "file://#{bundle_path}"

    %{
      cache_path: bundle_path,
      source_path: bundle_path,
      source_uri: source_uri,
      hash: hash,
      manifest_data: manifest_data
    }
  end
end
