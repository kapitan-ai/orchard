defmodule OrchardCLI.MLXSmokeScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @budget_helper Path.join(@repo_root, "scripts/support/mlx-smoke-budget.sh")
  @smoke_script Path.join(@repo_root, "scripts/smoke-mlx.sh")
  @custom_budget_env [
    {"MLX_SMOKE_SOURCE_HASH_TIMEOUT_MS", "11"},
    {"MLX_SMOKE_ACQUISITION_TIMEOUT_MS", "17"},
    {"MLX_SMOKE_WORKER_READY_TIMEOUT_MS", "13"},
    {"MLX_SMOKE_WORKER_LOAD_TIMEOUT_MS", "19"},
    {"MLX_SMOKE_RPC_HEADROOM_MS", "23"},
    {"MLX_SMOKE_INFERENCE_TIMEOUT_MS", "29"},
    {"MLX_SMOKE_CLEANUP_HEADROOM_MS", "31"}
  ]

  test "MLX smoke derives and passes its ExUnit timeout without running a model" do
    assert {"143\n", 0} =
             System.cmd(
               "bash",
               [
                 "-c",
                 "source \"$1\"; mlx_smoke_exunit_timeout_ms 11 17 13 19 23 29 31",
                 "bash",
                 @budget_helper
               ],
               stderr_to_stdout: true
             )

    with_smoke_fixture(fn fixture ->
      assert {output, 0} =
               System.cmd("bash", [@smoke_script],
                 cd: @repo_root,
                 env:
                   [
                     {"ORCHARD_MLX_SMOKE_MODEL_PATH", fixture.bundle},
                     {"ORCHARD_MLX_SMOKE_TEST_LOG", fixture.log},
                     {"PATH", fixture.bin <> ":" <> System.get_env("PATH", "")}
                   ] ++ @custom_budget_env,
                 stderr_to_stdout: true
               )

      assert output =~
               "mise exec -- mix test --only mlx_smoke --timeout 143"

      assert File.read!(fixture.log) =~
               nul_record([
                 "exec",
                 "--",
                 "mix",
                 "test",
                 "apps/orchard_node_agent/test/orchard_node_agent_test.exs",
                 "--only",
                 "mlx_smoke",
                 "--timeout",
                 "143"
               ])
    end)
  end

  test "MLX smoke reports Python failure and stops before Elixir" do
    with_smoke_fixture(fn fixture ->
      assert {output, 1} = run_smoke(fixture, "python")

      assert output =~ "Python smoke:  FAIL (exit 23)"
      assert output =~ "Elixir smoke:  NOT RUN"
      assert output =~ "Reason:        Python smoke tests failed"
      refute File.read!(fixture.log) =~ nul_record(["exec", "--", "mix", "test"])
    end)
  end

  test "MLX smoke reports Elixir failure" do
    with_smoke_fixture(fn fixture ->
      assert {output, 1} = run_smoke(fixture, "elixir")

      assert output =~ "Python smoke:  PASS"
      assert output =~ "Elixir smoke:  FAIL (exit 42)"
      assert output =~ "Reason:        Elixir smoke tests failed"
    end)
  end

  defp run_smoke(fixture, fail_phase) do
    System.cmd("bash", [@smoke_script],
      cd: @repo_root,
      env: [
        {"ORCHARD_MLX_SMOKE_MODEL_PATH", fixture.bundle},
        {"ORCHARD_MLX_SMOKE_TEST_LOG", fixture.log},
        {"ORCHARD_MLX_SMOKE_TEST_FAIL_PHASE", fail_phase},
        {"PATH", fixture.bin <> ":" <> System.get_env("PATH", "")}
      ],
      stderr_to_stdout: true
    )
  end

  defp nul_record(arguments), do: Enum.join(["CALL" | arguments] ++ ["END", ""], <<0>>)

  defp with_smoke_fixture(fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-mlx-smoke-script-test-#{System.unique_integer([:positive])}"
      )

    fixture = %{
      bin: Path.join(root, "bin"),
      bundle: Path.join(root, "bundle"),
      log: Path.join(root, "mise.log")
    }

    try do
      File.mkdir_p!(fixture.bin)
      File.mkdir_p!(fixture.bundle)
      File.write!(Path.join(fixture.bundle, "manifest.json"), "{}\n")
      write_fake_uname!(fixture.bin)
      write_fake_mise!(fixture.bin)
      fun.(fixture)
    after
      File.rm_rf(root)
    end
  end

  defp write_fake_uname!(bin) do
    path = Path.join(bin, "uname")

    File.write!(path, """
    #!/bin/sh
    case "$1" in
      -s) printf 'Darwin\n' ;;
      -m) printf 'arm64\n' ;;
      *) exec /usr/bin/uname "$@" ;;
    esac
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_mise!(bin) do
    path = Path.join(bin, "mise")

    File.write!(path, """
    #!/bin/sh
    {
      printf 'CALL\\0'
      printf '%s\\0' "$@"
      printf 'END\\0'
    } >> "$ORCHARD_MLX_SMOKE_TEST_LOG"

    case "${ORCHARD_MLX_SMOKE_TEST_FAIL_PHASE:-}" in
      python)
        case " $* " in
          *" pytest "*) exit 23 ;;
        esac
        ;;
      elixir)
        if [ "$1" = "exec" ] && [ "$2" = "--" ] && [ "$3" = "mix" ] && [ "$4" = "test" ]; then
          exit 42
        fi
        ;;
    esac

    exit 0
    """)

    File.chmod!(path, 0o755)
  end
end
