defmodule OrchardCLI.PackagingScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @postinstall Path.join(@repo_root, "packaging/pkg/scripts/postinstall")

  test "postinstall filters launchd plists for requested node-agent role" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      marker_path = Path.join([ctx.root, "support", ".install-role"])
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")

      File.write!(request_path, "node-agent\n")
      File.chmod!(request_path, 0o644)
      File.write!(stale_controller, "stale controller plist\n")

      assert {output, 0} = run_script(script, ctx, [{"REQUEST_STAT_MODE", "644"}])

      assert output =~ "postinstall: install_role=node-agent source=request"
      assert output =~ "Selected install role: node-agent."
      refute File.exists?(stale_controller)
      assert File.exists?(node_agent)
      assert File.read!(marker_path) == "node-agent\n"
      refute File.exists?(request_path)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.controller"
    end)
  end

  test "postinstall TLS failure for controller role does not mutate role or postgres plists" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      stale_postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])
      tls_controller_crt = Path.join([ctx.root, "config", "tls", "controller.crt"])

      File.write!(request_path, "controller\n")
      File.write!(stale_controller, "stale controller plist\n")
      File.write!(stale_postgres, "stale postgres plist\n")
      File.rm!(tls_controller_crt)

      assert {output, 1} = run_script(script, ctx)
      assert output =~ "partial managed TLS state"
      assert File.exists?(stale_controller)
      assert File.exists?(stale_postgres)
      refute File.exists?(node_agent)
      refute File.exists?(marker_path)
      assert File.exists?(request_path)

      launchctl_log =
        case File.read(ctx.launchctl_log) do
          {:ok, log} -> log
          {:error, _reason} -> ""
        end

      refute launchctl_log =~ "bootout system/com.orchard.controller"
      refute launchctl_log =~ "bootout system/com.orchard.postgres"
    end)
  end

  test "postinstall node-agent role skips partial controller TLS state" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])
      tls_controller_crt = Path.join([ctx.root, "config", "tls", "controller.crt"])

      File.write!(request_path, "node-agent\n")
      File.write!(stale_controller, "stale controller plist\n")
      File.rm!(tls_controller_crt)

      assert {output, 0} = run_script(script, ctx)
      assert output =~ "node-agent role selected; skipping controller TLS setup"
      refute output =~ "partial managed TLS state"
      refute File.exists?(stale_controller)
      assert File.exists?(node_agent)
      assert File.read!(marker_path) == "node-agent\n"
      refute File.exists?(request_path)
    end)
  end

  test "postinstall boots out out-of-role service even when plist is absent" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")

      File.write!(request_path, "node-agent\n")

      assert {output, 0} = run_script(script, ctx)
      assert output =~ "postinstall: install_role=node-agent source=request"
      refute File.exists?(controller)
      assert File.exists?(node_agent)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.controller"
    end)
  end

  test "postinstall removes stale postgres plist for node-agent role" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      install_managed_postgres_assets!(ctx)

      postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])

      File.write!(request_path, "node-agent\n")
      File.write!(postgres, "stale postgres plist\n")

      assert {output, 0} = run_script(script, ctx)

      assert output =~ "postinstall: install_role=node-agent source=request"
      refute File.exists?(postgres)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.postgres"
      refute File.read!(ctx.launchctl_log) =~ "bootstrap system #{postgres}"
      assert File.read!(marker_path) == "node-agent\n"
    end)
  end

  test "postinstall does not install or bootstrap postgres for all and controller roles" do
    for role <- ["all", "controller"] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        install_managed_postgres_assets!(ctx)

        postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")
        marker_path = Path.join([ctx.root, "support", ".install-role"])

        File.write!(request_path, role <> "\n")
        File.write!(postgres, "stale postgres plist\n")

        assert {_output, 0} = run_script(script, ctx)

        refute File.exists?(postgres)
        assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.postgres"
        refute File.read!(ctx.launchctl_log) =~ "bootstrap system #{postgres}"
        assert File.read!(marker_path) == role <> "\n"
      end)
    end
  end

  test "postinstall rejects group/world-writable request file" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])

      File.write!(request_path, "node-agent\n")
      File.write!(stale_controller, "stale controller plist\n")

      assert {output, 1} = run_script(script, ctx, [{"REQUEST_STAT_MODE", "666"}])
      assert output =~ "must not be group/world writable"
      assert File.exists?(request_path)
      assert File.exists?(stale_controller)
      refute File.exists?(node_agent)
      refute File.exists?(marker_path)
    end)
  end

  test "postinstall rejects request file with non-root owner" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")

      File.write!(request_path, "node-agent\n")
      File.write!(stale_controller, "stale controller plist\n")

      assert {output, 1} = run_script(script, ctx, [{"REQUEST_STAT_UID", "501"}])
      assert output =~ "must be root-owned"
      assert File.exists?(request_path)
      assert File.exists?(stale_controller)
      refute File.exists?(node_agent)
    end)
  end

  defp with_temp_postinstall(fun) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-postinstall-test-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp_dir, "Application Support/Orchard")
    launch_daemons = Path.join(tmp_dir, "LaunchDaemons")
    launch_agents = Path.join(tmp_dir, "LaunchAgents")
    local_bin = Path.join(tmp_dir, "local-bin")
    fake_bin = Path.join(tmp_dir, "fake-bin")
    script = Path.join(tmp_dir, "postinstall")
    launchctl_log = Path.join(tmp_dir, "launchctl.log")
    request_path = Path.join([root, "support", ".install-role.request"])

    ctx = %{
      fake_bin: fake_bin,
      launch_agents: launch_agents,
      launch_daemons: launch_daemons,
      launchctl_log: launchctl_log,
      local_bin: local_bin,
      request_path: request_path,
      root: root,
      script: script
    }

    try do
      prepare_install_root!(ctx)
      write_test_script!(ctx)
      write_fake_commands!(ctx)
      fun.(ctx)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp prepare_install_root!(ctx) do
    for dir <- [
          ctx.launch_agents,
          ctx.launch_daemons,
          ctx.local_bin,
          Path.join(ctx.root, "bin"),
          Path.join(ctx.root, "config/tls"),
          Path.join(ctx.root, "logs"),
          Path.join(ctx.root, "support"),
          Path.join(ctx.root, "share/bin"),
          Path.join(ctx.root, "share/launchd")
        ] do
      File.mkdir_p!(dir)
    end

    for file <- ["ca.key", "ca.crt", "controller.key", "controller.crt"] do
      File.write!(Path.join([ctx.root, "config/tls", file]), "tls\n")
    end

    for cmd <- ["orchard-controller", "orchard-node-agent", "orchardctl"] do
      path = Path.join([ctx.root, "share/bin", cmd])
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    for svc <- ["com.orchard.controller", "com.orchard.node-agent"] do
      File.write!(Path.join([ctx.root, "share/launchd", "#{svc}.plist"]), "#{svc}\n")
    end
  end

  defp write_test_script!(ctx) do
    content =
      @postinstall
      |> File.read!()
      |> String.replace(
        ~s(ORCHARD_ROOT="/Library/Application Support/Orchard"),
        ~s(ORCHARD_ROOT="#{ctx.root}")
      )
      |> String.replace("/Library/LaunchDaemons", ctx.launch_daemons)
      |> String.replace("/Library/LaunchAgents", ctx.launch_agents)
      |> String.replace("/usr/local/bin", ctx.local_bin)

    File.write!(ctx.script, content)
    File.chmod!(ctx.script, 0o755)
  end

  defp write_fake_commands!(ctx) do
    File.mkdir_p!(ctx.fake_bin)

    File.write!(Path.join(ctx.fake_bin, "chown"), "#!/bin/sh\nexit 0\n")

    File.write!(Path.join(ctx.fake_bin, "launchctl"), """
    #!/bin/sh
    printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"

    if [ "$1" = "bootstrap" ] && [ -n "${POSTGRES_BOOTSTRAP_EXIT:-}" ]; then
      case "$*" in
        *com.orchard.postgres.plist*)
          printf '%s\n' "${POSTGRES_BOOTSTRAP_OUTPUT:-simulated postgres bootstrap failure}" >&2
          exit "$POSTGRES_BOOTSTRAP_EXIT"
          ;;
      esac
    fi

    exit 0
    """)

    File.write!(Path.join(ctx.fake_bin, "stat"), """
    #!/bin/sh
    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "$REQUEST_STAT_PATH" ]; then
      printf '%s:%s\n' "${REQUEST_STAT_UID:-0}" "${REQUEST_STAT_MODE:-600}"
      exit 0
    fi

    /usr/bin/stat "$@"
    """)

    for cmd <- ["chown", "launchctl", "stat"] do
      File.chmod!(Path.join(ctx.fake_bin, cmd), 0o755)
    end
  end

  defp install_managed_postgres_assets!(ctx) do
    managed_postgres = Path.join([ctx.root, "share/bin", "orchard-managed-postgres"])
    postgres_plist = Path.join([ctx.root, "share/launchd", "com.orchard.postgres.plist"])

    File.write!(managed_postgres, "#!/bin/sh\nexit 0\n")
    File.chmod!(managed_postgres, 0o755)
    File.write!(postgres_plist, "com.orchard.postgres\n")
  end

  defp run_script(script, ctx, extra_env \\ []) do
    path = ctx.fake_bin <> ":" <> System.get_env("PATH", "")

    env =
      [
        {"LAUNCHCTL_LOG", ctx.launchctl_log},
        {"PATH", path},
        {"REQUEST_STAT_PATH", ctx.request_path}
      ] ++ extra_env

    System.cmd("sh", [script], env: env, stderr_to_stdout: true)
  end
end
