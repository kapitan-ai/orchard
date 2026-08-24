defmodule OrchardCLI.PackagingWrapperTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @orchardctl Path.join(@repo_root, "packaging/payload/bin/orchardctl")

  test "payload orchardctl wrapper securely sources controller.env for DB-backed commands" do
    content = File.read!(@orchardctl)

    assert content =~ "ORCHARD_ROOT=\"/Library/Application Support/Orchard\""
    assert content =~ "ENV_FILE=\"$ORCHARD_ROOT/config/controller.env\""
    assert content =~ "stat -f '%u:%Lp' \"$ENV_FILE\""
    assert content =~ "expected 0"
    assert content =~ "group/world bits set"
    assert content =~ "not readable by this user"
    assert content =~ "set -a"
    assert content =~ ". \"$ENV_FILE\""
    assert content =~ "set +a"
    assert content =~ "ORCHARD_CLI_FOREGROUND_SUPERVISOR_PID=$$"
    assert content =~ "\"$ORCHARD_CLI\" eval \"OrchardCLI.main([$args])\" <&3 3<&- &"
    assert content =~ "_cli_pid=$!"
    assert content =~ "wait \"$_cli_pid\""
  end

  test "payload orchardctl wrapper propagates DATABASE_URL from secure controller.env" do
    with_temp_wrapper(fn wrapper, root ->
      env_path = Path.join([root, "config", "controller.env"])
      File.write!(env_path, "DATABASE_URL=ecto://user:pass@localhost/orchard_controller\n")
      File.chmod!(env_path, 0o600)

      assert {output, 0} = System.cmd(wrapper, ["upgrade", "plan"], stderr_to_stdout: true)
      assert output =~ "DATABASE_URL=ecto://user:pass@localhost/orchard_controller"
      assert output =~ "ARGS=eval OrchardCLI.main([\"upgrade\", \"plan\"])"
    end)
  end

  test "payload orchardctl wrapper skips insecure controller.env without blocking dispatch" do
    with_temp_wrapper(fn wrapper, root ->
      env_path = Path.join([root, "config", "controller.env"])
      File.write!(env_path, "DATABASE_URL=ecto://user:pass@localhost/orchard_controller\n")
      File.chmod!(env_path, 0o644)

      assert {output, 0} = System.cmd(wrapper, ["upgrade", "plan"], stderr_to_stdout: true)
      assert output =~ "group/world bits set"
      assert output =~ "DATABASE_URL="
      refute output =~ "DATABASE_URL=ecto://user:pass@localhost/orchard_controller"
    end)
  end

  test "payload orchardctl wrapper forwards piped stdin to the supervised CLI" do
    with_temp_wrapper(fn wrapper, _root ->
      assert {output, 0} =
               System.cmd(
                 "sh",
                 [
                   "-c",
                   ~s(printf 'diagnostic-input\\n' | "$1" status),
                   "orchardctl-stdin-regression",
                   wrapper
                 ],
                 stderr_to_stdout: true
               )

      assert output =~ "STDIN=diagnostic-input"
    end)
  end

  test "payload orchardctl wrapper tolerates a closed standard input" do
    with_temp_wrapper(fn wrapper, _root ->
      assert {output, 0} =
               System.cmd(
                 "sh",
                 [
                   "-c",
                   ~s("$1" status 0<&-),
                   "orchardctl-closed-stdin-regression",
                   wrapper
                 ],
                 stderr_to_stdout: true
               )

      assert output =~ "STDIN=<eof>"
    end)
  end

  test "payload orchardctl wrapper runs the CLI in the invocation directory" do
    with_temp_wrapper(fn wrapper, _root ->
      workdir = Path.join(Path.dirname(wrapper), "operator-cwd")
      File.mkdir_p!(workdir)
      File.write!(Path.join(workdir, "cwd-marker"), "relative-path-resolution\n")

      assert {output, 0} =
               System.cmd(
                 "sh",
                 [
                   "-c",
                   ~s(cd "$2" && "$1" upgrade plan),
                   "orchardctl-cwd-regression",
                   wrapper,
                   workdir
                 ],
                 stderr_to_stdout: true
               )

      assert output =~ "CWD_MARKER=relative-path-resolution"
    end)
  end

  test "payload orchardctl wrapper remains valid POSIX shell" do
    assert {"", 0} = System.cmd("sh", ["-n", @orchardctl], stderr_to_stdout: true)
  end

  defp with_temp_wrapper(fun) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchardctl-wrapper-test-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp_dir, "Application Support/Orchard")
    wrapper = Path.join(tmp_dir, "orchardctl")

    try do
      File.mkdir_p!(Path.join(root, "config"))
      install_fake_release_cli!(root)
      write_test_wrapper!(wrapper, root)
      fun.(wrapper, root)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp install_fake_release_cli!(root) do
    cli_path = Path.join([root, "releases", "orchard_cli", "bin", "orchard_cli"])
    File.mkdir_p!(Path.dirname(cli_path))

    File.write!(cli_path, """
    #!/bin/sh
    printf 'DATABASE_URL=%s\n' "${DATABASE_URL:-}"
    printf 'ARGS=%s\n' "$*"
    if [ -f ./cwd-marker ]; then
      IFS= read -r _marker < ./cwd-marker
      printf 'CWD_MARKER=%s\n' "$_marker"
    fi
    case "$*" in
      *status*)
        if IFS= read -r _line; then
          printf 'STDIN=%s\n' "$_line"
        else
          printf 'STDIN=<eof>\n'
        fi
        ;;
    esac
    """)

    File.chmod!(cli_path, 0o755)
  end

  defp write_test_wrapper!(wrapper, root) do
    uid = current_uid!()

    production_root = ~s(ORCHARD_ROOT="/Library/Application Support/Orchard")
    test_root = ~s(ORCHARD_ROOT="#{root}")
    production_owner_check = ~s([ "$_env_uid" != "0" ])
    test_owner_check = ~s([ "$_env_uid" != "#{uid}" ])

    content =
      @orchardctl
      |> File.read!()
      |> String.replace(production_root, test_root)
      |> String.replace(production_owner_check, test_owner_check)

    File.write!(wrapper, content)
    File.chmod!(wrapper, 0o755)
  end

  defp current_uid! do
    {uid, 0} = System.cmd("id", ["-u"])
    String.trim(uid)
  end
end
