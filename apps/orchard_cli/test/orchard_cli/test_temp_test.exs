defmodule OrchardCLI.TestTempTest do
  use ExUnit.Case, async: true

  @test_temp_support Path.expand("../support/test_temp.ex", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "orchard-cli-test-temp-#{Ecto.UUID.generate()}")
    File.mkdir!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base}
  end

  test "a stale interrupted run cannot collide with or be cleaned by a later run", %{base: base} do
    interrupted_root = run_in_fresh_beam!(base, "interrupted", "leave")
    stale_marker = Path.join(interrupted_root, "owner-marker")
    current_root = run_in_fresh_beam!(base, "current", "cleanup")

    refute current_root == interrupted_root
    assert File.dir?(interrupted_root)
    refute File.exists?(current_root)
    assert File.read!(stale_marker) == "interrupted"
  end

  test "concurrent runs cannot clean each other's owned artifacts", %{base: base} do
    first = start_held_run!(base, "first-run")

    try do
      second = start_held_run!(base, "second-run")

      try do
        refute first.root == second.root
        assert Task.yield(second.task, 0) == nil

        release_and_await!(first)

        refute File.exists?(first.root)
        assert Task.yield(second.task, 0) == nil
        assert File.read!(Path.join(second.root, "owner-marker")) == "second-run"
      after
        release_and_await!(second)
      end
    after
      release_and_await!(first)
    end
  end

  test "an abandoned held run bounds its wait and cleans up only its owned root", %{base: base} do
    label = "abandoned-run"
    ready = Path.join(base, "#{label}.ready")
    release = Path.join(base, "#{label}.release")

    task =
      Task.async(fn ->
        run_fresh_beam(["hold", base, label, ready, release], [
          {"ORCHARD_TEST_TEMP_HOLD_TIMEOUT_MS", "100"}
        ])
      end)

    root = await_ready!(task, ready, System.monotonic_time(:millisecond) + 5_000)
    assert File.dir?(root)

    {output, status} = Task.await(task, 5_000)

    assert status == 0, "abandoned held run failed (status #{status}):\n#{output}"
    refute File.exists?(release)
    refute File.exists?(root)
  end

  defp run_in_fresh_beam!(base, label, cleanup) do
    {output, status} = run_fresh_beam(["run", base, label, cleanup])

    assert status == 0, "fresh BEAM test-temp run failed (status #{status}):\n#{output}"
    String.trim(output)
  end

  defp start_held_run!(base, label) do
    ready = Path.join(base, "#{label}.ready")
    release = Path.join(base, "#{label}.release")

    task =
      Task.async(fn ->
        run_fresh_beam(["hold", base, label, ready, release])
      end)

    root = await_ready!(task, ready, System.monotonic_time(:millisecond) + 5_000)
    %{release: release, root: root, task: task}
  end

  defp await_ready!(task, ready, deadline) do
    cond do
      File.regular?(ready) ->
        File.read!(ready)

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("fresh BEAM did not publish its owned test-temp root")

      true ->
        case Task.yield(task, 0) do
          {:ok, {output, status}} ->
            flunk("fresh BEAM exited before publishing its root (status #{status}):\n#{output}")

          nil ->
            Process.sleep(10)
            await_ready!(task, ready, deadline)
        end
    end
  end

  defp release_and_await!(run) do
    if Process.alive?(run.task.pid) do
      OrchardCLI.TestTemp.atomic_write!(run.release, "cleanup")
      {output, status} = Task.await(run.task, 5_000)
      assert status == 0, "fresh BEAM cleanup failed (status #{status}):\n#{output}"
    end

    :ok
  end

  defp run_fresh_beam(args, env \\ []) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    System.cmd(
      elixir,
      [
        "-r",
        @test_temp_support,
        "-e",
        "OrchardCLI.TestTempProcess.main(System.argv())",
        "--" | args
      ],
      env: env,
      stderr_to_stdout: true
    )
  end
end
