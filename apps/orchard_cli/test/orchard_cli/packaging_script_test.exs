defmodule OrchardCLI.PackagingScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @controller_wrapper Path.join(@repo_root, "packaging/pkg/bin/orchard-controller")
  @node_agent_wrapper Path.join(@repo_root, "packaging/pkg/bin/orchard-node-agent")
  @managed_postgres_wrapper Path.join(@repo_root, "packaging/pkg/bin/orchard-managed-postgres")
  @postinstall Path.join(@repo_root, "packaging/pkg/scripts/postinstall")

  test "managed postgres wrapper fails operational invocations with external database guidance" do
    assert {output, 69} = run_managed_postgres_wrapper(["start"])

    assert output =~ "ERROR: managed Postgres is unavailable in this build"
    assert_managed_postgres_guidance(output)
  end

  test "managed postgres wrapper fails no-arg invocation with external database guidance" do
    assert {output, 69} = run_managed_postgres_wrapper()

    assert output =~ "ERROR: managed Postgres is unavailable in this build"
    assert_managed_postgres_guidance(output)
  end

  test "managed postgres wrapper help prints current supported path" do
    assert {output, 0} = run_managed_postgres_wrapper(["--help"])

    refute output =~ "ERROR:"
    assert_managed_postgres_guidance(output)
  end

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

  test "postinstall fresh default maps to local HTTP and skips managed TLS inspection" do
    for role <- ["controller", "all"] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
        node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
        marker_path = Path.join([ctx.root, "support", ".install-role"])
        complete_path = Path.join([ctx.root, "support", ".pkg-install-complete"])
        orchardctl_log = Path.join(ctx.root, "orchardctl.log")

        remove_managed_tls_files!(ctx)
        File.write!(request_path, role <> "\n")

        File.write!(Path.join([ctx.root, "share/bin", "orchardctl"]), """
        #!/bin/sh
        printf '%s\n' "$*" >> "#{orchardctl_log}"
        exit 42
        """)

        assert {output, 0} = run_script(script, ctx)

        assert output =~ "postinstall: tls_mode=transport_plain_http_localhost"
        assert output =~ "ORCHARD_TRANSPORT_MODE=plain_http_localhost"
        assert output =~ "skipping managed TLS inspection"
        refute output =~ "postinstall: managed TLS state=empty"
        refute output =~ "postinstall: managed TLS files are not installed"
        refute output =~ "generating managed TLS certificates"
        refute File.exists?(orchardctl_log)
        assert File.exists?(controller)
        assert File.exists?(node_agent) == (role == "all")
        assert File.read!(marker_path) == role <> "\n"
        assert File.exists?(complete_path)
        refute File.exists?(request_path)
      end)
    end
  end

  test "postinstall writes local HTTP endpoint sidecar with schema v1 and public permissions" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")
      remove_managed_tls_files!(ctx)
      File.chmod!(ctx.root, 0o700)

      assert {output, 0} = run_script(script, ctx)
      assert output =~ "postinstall: wrote endpoint metadata sidecar"

      endpoint_path = Path.join([ctx.root, "public", "endpoint.json"])
      assert File.regular?(endpoint_path)
      assert Bitwise.band(File.stat!(ctx.root).mode, 0o777) == 0o755
      assert Bitwise.band(File.stat!(Path.dirname(endpoint_path)).mode, 0o777) == 0o755
      assert Bitwise.band(File.stat!(endpoint_path).mode, 0o777) == 0o644

      decoded = Jason.decode!(File.read!(endpoint_path))

      assert Map.keys(decoded) |> Enum.sort() ==
               ~w(api_bind_ip api_https_port ca_certfile generated_by plain_http_port public_host schema_version transport_mode updated_at)

      assert decoded["schema_version"] == 1
      assert decoded["transport_mode"] == "plain_http_localhost"
      assert decoded["public_host"] == "localhost"
      assert decoded["plain_http_port"] == 4000
      assert decoded["api_https_port"] == nil
      assert decoded["ca_certfile"] == nil
      assert decoded["generated_by"] == "postinstall"
      refute File.read!(endpoint_path) =~ "controller.key"
      refute File.read!(endpoint_path) =~ "DATABASE_URL"
    end)
  end

  test "postinstall skips endpoint sidecar for explicitly empty endpoint metadata env fields" do
    for assignment <- [
          "ORCHARD_TRANSPORT_MODE=plain_http_localhost PORT=",
          "ORCHARD_TRANSPORT_MODE=direct_https ORCHARD_API_HTTPS_PORT=",
          "ORCHARD_TRANSPORT_MODE=reverse_proxy ORCHARD_PUBLIC_PORT=",
          "ORCHARD_TRANSPORT_MODE=plain_http_localhost ORCHARD_PUBLIC_HOST=",
          "ORCHARD_TRANSPORT_MODE=plain_http_localhost PHX_HOST="
        ] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        File.write!(request_path, "controller\n")
        remove_managed_tls_files!(ctx)

        assert {_output, 0} = run_script_with_endpoint_assignment(script, ctx, assignment)

        refute File.exists?(Path.join([ctx.root, "public", "endpoint.json"]))
      end)
    end
  end

  test "postinstall skips endpoint sidecar for invalid endpoint metadata fields" do
    for env <- [
          [{"ORCHARD_TRANSPORT_MODE", "plain_http_localhost"}, {"PORT", "not-a-port"}]
        ] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        File.write!(request_path, "controller\n")
        remove_managed_tls_files!(ctx)

        assert {output, 0} = run_script(script, ctx, env)

        assert output =~ "skipping endpoint metadata sidecar"
        refute File.exists?(Path.join([ctx.root, "public", "endpoint.json"]))
      end)
    end
  end

  test "postinstall writes direct HTTPS endpoint sidecar from non-secret env metadata" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "tls", ".orchard-tls-meta.json"]),
        ~s({"source":"generated_local_ca"})
      )

      File.write!(request_path, "controller\n")

      assert {output, 0} =
               run_script(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_PUBLIC_HOST", "orchard.example.internal"},
                 {"ORCHARD_API_HTTPS_PORT", "9443"},
                 {"ORCHARD_API_BIND_IP", "0.0.0.0"}
               ])

      assert output =~ "postinstall: wrote endpoint metadata sidecar"

      endpoint_path = Path.join([ctx.root, "public", "endpoint.json"])
      decoded = Jason.decode!(File.read!(endpoint_path))

      assert decoded["transport_mode"] == "direct_https"
      assert decoded["public_host"] == "orchard.example.internal"
      assert decoded["api_https_port"] == 9443
      assert decoded["plain_http_port"] == nil
      assert decoded["api_bind_ip"] == "0.0.0.0"
      assert decoded["ca_certfile"] == Path.join([ctx.root, "public", "ca.crt"])
      refute File.read!(endpoint_path) =~ "controller.key"
      assert File.regular?(decoded["ca_certfile"])
      assert Bitwise.band(File.stat!(decoded["ca_certfile"]).mode, 0o777) == 0o644
    end)
  end

  test "postinstall does not publish generated CA for malformed or nested TLS metadata" do
    for metadata <- ["not json", ~s({"nested":{"source":"generated_local_ca"}})] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        File.write!(Path.join([ctx.root, "config", "tls", ".orchard-tls-meta.json"]), metadata)
        File.write!(request_path, "controller\n")

        assert {output, 0} =
                 run_script(script, ctx, [
                   {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                   {"ORCHARD_PUBLIC_HOST", "orchard.example.internal"}
                 ])

        assert output =~ "postinstall: wrote endpoint metadata sidecar"
        endpoint_path = Path.join([ctx.root, "public", "endpoint.json"])
        decoded = Jason.decode!(File.read!(endpoint_path))
        assert decoded["transport_mode"] == "direct_https"
        assert decoded["ca_certfile"] == nil
        refute File.exists?(Path.join([ctx.root, "public", "ca.crt"]))
      end)
    end
  end

  test "postinstall external TLS sidecar omits operator PKI CA path" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      external_tls_dir = Path.join(ctx.root, "external-tls")
      File.mkdir_p!(external_tls_dir)
      certfile = Path.join(external_tls_dir, "orchard.crt")
      keyfile = Path.join(external_tls_dir, "orchard.key")
      cafile = Path.join(external_tls_dir, "operator-ca.crt")
      File.write!(certfile, "external cert\n")
      File.write!(keyfile, "external key\n")
      File.write!(cafile, "operator ca\n")
      File.write!(request_path, "controller\n")

      assert {output, 0} =
               run_script(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_PUBLIC_HOST", "orchard.example.internal"},
                 {"ORCHARD_TLS_CERTFILE", certfile},
                 {"ORCHARD_TLS_KEYFILE", keyfile},
                 {"ORCHARD_TLS_CACERTFILE", cafile}
               ])

      assert output =~ "postinstall: wrote endpoint metadata sidecar"

      endpoint_path = Path.join([ctx.root, "public", "endpoint.json"])
      decoded = Jason.decode!(File.read!(endpoint_path))

      assert decoded["transport_mode"] == "direct_https"
      assert decoded["ca_certfile"] == nil
      refute File.read!(endpoint_path) =~ cafile
      refute File.read!(endpoint_path) =~ keyfile
    end)
  end

  test "postinstall default local HTTP warns when managed TLS exists" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 0} = run_script(script, ctx)

      assert output =~ "ORCHARD_TRANSPORT_MODE=plain_http_localhost"
      assert output =~ "managed TLS files exist but default transport is plain_http_localhost"
      assert output =~ "set ORCHARD_TRANSPORT_MODE=direct_https to use them"
    end)
  end

  test "postinstall explicit transport warns about conflicting legacy TLS envs" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 0} =
               run_script(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "plain_http_localhost"},
                 {"ORCHARD_TLS_DISABLED", "false"},
                 {"ORCHARD_TLS_CERTFILE", "/missing/conflicting.crt"},
                 {"ORCHARD_TLS_KEYFILE", "/missing/conflicting.key"}
               ])

      assert output =~ "ORCHARD_TRANSPORT_MODE=plain_http_localhost is authoritative"
      assert output =~ "conflicting legacy TLS envs are deprecated and ignored"
    end)
  end

  test "postinstall final guidance prints first-run sequence and confirms services are not started" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")
      remove_managed_tls_files!(ctx)

      assert {output, 0} = run_script(script, ctx)

      assert output =~ "controller launchd service(s) were installed but not started."
      assert output =~ "Next steps for first-run setup:"

      assert output =~
               "1. Provide or verify the Orchard license using the supported license activation path."

      assert output =~ "2. Run: sudo orchardctl env init --service controller"

      assert output =~
               "3. Edit controller.env with external DATABASE_URL, SECRET_KEY_BASE, BEAM Runtime Endpoint targets, BEAM cookie path, and transport settings."

      assert output =~
               "Create the BEAM cookie as root-owned mode 0600, and copy the same cookie contents to every node-agent Mac."

      assert output =~ "4. Run: sudo orchardctl migrate"

      assert output =~
               "5. Run: sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json"

      assert output =~
               "6. Configure transport before start. For local generated HTTPS run: sudo orchardctl transport enable-local-https --host HOST; for reverse proxy or external certificates follow the package README."

      assert output =~ "7. Optional Console: sudo orchardctl console enable"
      assert output =~ "8. Run: sudo orchardctl start"
      assert output =~ "9. Verify: orchardctl status"
      refute output =~ "Run next: sudo orchardctl start"
      refute output =~ "Then run: sudo orchardctl start"
    end)
  end

  test "postinstall node-agent final guidance omits controller-only first-run steps" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "node-agent\n")

      assert {output, 0} = run_script(script, ctx)

      assert output =~ "node-agent launchd service(s) were installed but not started."
      assert output =~ "Next steps for first-run setup:"
      assert output =~ "2. Run: sudo orchardctl env init --service node-agent"

      assert output =~
               "3. Edit node-agent.env with ORCHARD_BEAM_NODE_NAME, ORCHARD_BEAM_COOKIE_FILE, EPMD/distribution ports, node display name, and worker settings."

      assert output =~
               "Create the BEAM cookie as root-owned mode 0600, and copy the same cookie contents to the controller Mac."

      assert output =~
               "Keep gRPC listener settings loopback unless intentionally using ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc compatibility fallback."

      assert output =~ "4. Run: sudo orchardctl start"
      assert output =~ "5. Verify: orchardctl status"
      refute output =~ "orchardctl migrate"
      refute output =~ "orchardctl cluster init"
      refute output =~ "transport enable-local-https"
      refute output =~ "console enable"
    end)
  end

  test "postinstall all-role guidance includes node-agent env review before start" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "all\n")

      assert {output, 0} = run_script(script, ctx)

      assert output =~
               "controller and node-agent launchd service(s) were installed but not started."

      assert output =~ "2. Run: sudo orchardctl env init --service all"

      assert output =~
               "3. Edit controller.env with external DATABASE_URL, SECRET_KEY_BASE, BEAM Runtime Endpoint targets, BEAM cookie path, and transport settings; review node-agent.env for matching BEAM node/cookie settings."

      assert output =~
               "Create the BEAM cookie as root-owned mode 0600, and copy the same cookie contents to every node-agent Mac."

      assert output =~ "4. Run: sudo orchardctl migrate"

      assert output =~
               "5. Run: sudo orchardctl cluster init --output /secure/path/bootstrap-admin.json"

      assert output =~ "8. Run: sudo orchardctl start"
      assert output =~ "9. Verify: orchardctl status"
    end)
  end

  test "postinstall transport mode skips managed TLS inspection for proxy and local HTTP modes" do
    for {mode, expected} <- [
          {"reverse_proxy", "ORCHARD_TRANSPORT_MODE=reverse_proxy"},
          {"plain_http_localhost", "ORCHARD_TRANSPORT_MODE=plain_http_localhost"}
        ] do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        tls_controller_crt = Path.join([ctx.root, "config", "tls", "controller.crt"])

        File.rm!(tls_controller_crt)
        File.write!(request_path, "controller\n")

        assert {output, 0} = run_script(script, ctx, [{"ORCHARD_TRANSPORT_MODE", mode}])

        assert output =~ expected
        assert output =~ "skipping managed TLS inspection"
        refute output =~ "partial managed TLS state"
        refute output =~ "Configure transport before starting controller services"
        assert output =~ "Next steps for first-run setup:"
        assert output =~ "Configure transport before start"
        assert output =~ "for reverse proxy or external certificates follow the package README"
        assert output =~ "8. Run: sudo orchardctl start"
      end)
    end
  end

  test "postinstall legacy TLS disabled false maps to managed default" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 0} = run_script(script, ctx, [{"ORCHARD_TLS_DISABLED", "false"}])

      assert output =~ "postinstall: tls_mode=managed_default"
      assert output =~ "existing managed TLS certificates found; preserving"
    end)
  end

  test "postinstall legacy TLS disabled false fails on partial managed TLS" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      tls_controller_crt = Path.join([ctx.root, "config", "tls", "controller.crt"])

      File.rm!(tls_controller_crt)
      File.write!(request_path, "controller\n")

      assert {output, 1} = run_script(script, ctx, [{"ORCHARD_TLS_DISABLED", "false"}])

      assert output =~ "postinstall: tls_mode=managed_default"
      assert output =~ "partial managed TLS state"
    end)
  end

  test "postinstall direct_https transport wins over legacy disabled" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 0} =
               run_script(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_DISABLED", "true"}
               ])

      assert output =~ "postinstall: tls_mode=managed_default"
      assert output =~ "existing managed TLS certificates found; preserving"
      refute output =~ "TLS is disabled"
    end)
  end

  test "postinstall explicit default cert paths are external overrides" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      certfile = Path.join([ctx.root, "config", "tls", "controller.crt"])
      keyfile = Path.join([ctx.root, "config", "tls", "controller.key"])
      ca_key = Path.join([ctx.root, "config", "tls", "ca.key"])
      ca_crt = Path.join([ctx.root, "config", "tls", "ca.crt"])

      File.rm!(ca_key)
      File.rm!(ca_crt)
      File.write!(request_path, "controller\n")

      assert {output, 0} =
               run_script(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CERTFILE", certfile},
                 {"ORCHARD_TLS_KEYFILE", keyfile}
               ])

      assert output =~ "postinstall: tls_mode=external_override"
      assert output =~ "postinstall: external TLS files validated"
      refute output =~ "partial managed TLS state"
    end)
  end

  test "postinstall rejects empty CA certificate override" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 1} = run_script_with_empty_ca(script, ctx)
      assert output =~ "ORCHARD_TLS_CACERTFILE must not be empty"
    end)
  end

  test "postinstall rejects invalid transport mode" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      File.write!(request_path, "controller\n")

      assert {output, 1} = run_script(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "https"}])

      assert output =~
               "ORCHARD_TRANSPORT_MODE must be reverse_proxy, direct_https, or plain_http_localhost"
    end)
  end

  test "postinstall disabled or external TLS modes do not print empty-managed start guidance" do
    scenarios = [
      {"disabled", [{"ORCHARD_TLS_DISABLED", "true"}]},
      {"external", []}
    ]

    for {scenario, env} <- scenarios do
      with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
        env =
          case scenario do
            "external" ->
              external_tls_dir = Path.join(ctx.root, "external-tls")
              File.mkdir_p!(external_tls_dir)
              certfile = Path.join(external_tls_dir, "orchard.crt")
              keyfile = Path.join(external_tls_dir, "orchard.key")
              File.write!(certfile, "external cert\n")
              File.write!(keyfile, "external key\n")

              [
                {"ORCHARD_TLS_CERTFILE", certfile},
                {"ORCHARD_TLS_KEYFILE", keyfile}
              ]

            "disabled" ->
              env
          end

        remove_managed_tls_files!(ctx)
        File.write!(request_path, "controller\n")

        assert {output, 0} = run_script(script, ctx, env)

        if scenario == "external" do
          assert output =~ "postinstall: tls_mode=external_override"
          assert output =~ "postinstall: external TLS files validated"
        end

        refute output =~ "Configure transport before starting controller services"
        assert output =~ "Next steps for first-run setup:"
        assert output =~ "8. Run: sudo orchardctl start"
      end)
    end
  end

  test "postinstall TLS failure removes unsupported postgres without mutating role plists" do
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

      assert {output, 1} = run_script(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])
      assert output =~ "partial managed TLS state"
      assert output =~ "removing unsupported managed Postgres LaunchDaemon"
      assert File.exists?(stale_controller)
      refute File.exists?(stale_postgres)
      refute File.exists?(node_agent)
      refute File.exists?(marker_path)
      assert File.exists?(request_path)

      launchctl_log =
        case File.read(ctx.launchctl_log) do
          {:ok, log} -> log
          {:error, _reason} -> ""
        end

      refute launchctl_log =~ "bootout system/com.orchard.controller"
      assert launchctl_log =~ "bootout system/com.orchard.postgres"
    end)
  end

  test "postinstall normalizes root-owned console.env mode without printing credentials" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      console_env = Path.join([ctx.root, "config", "console.env"])

      File.write!(request_path, "controller\n")

      File.write!(
        console_env,
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      File.chmod!(console_env, 0o400)

      assert {output, 0} =
               run_script(script, ctx, [
                 {"CONSOLE_ENV_STAT_UID", "0"},
                 {"CONSOLE_ENV_STAT_MODE", "400"}
               ])

      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o600
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "postinstall leaves root-owned insecure console.env untouched with non-secret warning" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      console_env = Path.join([ctx.root, "config", "console.env"])

      File.write!(request_path, "controller\n")

      File.write!(
        console_env,
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      File.chmod!(console_env, 0o644)

      assert {output, 0} =
               run_script(script, ctx, [
                 {"CONSOLE_ENV_STAT_UID", "0"},
                 {"CONSOLE_ENV_STAT_MODE", "644"}
               ])

      assert output =~ "WARNING: leaving untrusted console env file unchanged"
      assert output =~ "must not have group/world permission bits"
      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o644
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "postinstall leaves console.env untouched when stat inspection fails" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      console_env = Path.join([ctx.root, "config", "console.env"])

      File.write!(request_path, "controller\n")

      File.write!(
        console_env,
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      File.chmod!(console_env, 0o640)

      assert {output, 0} =
               run_script(script, ctx, [
                 {"CONSOLE_ENV_STAT_FAIL", "true"}
               ])

      assert output =~ "could not inspect"
      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o640
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "postinstall leaves non-root-owned console.env untouched with non-secret warning" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      console_env = Path.join([ctx.root, "config", "console.env"])

      File.write!(request_path, "controller\n")

      File.write!(
        console_env,
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      File.chmod!(console_env, 0o640)

      assert {output, 0} =
               run_script(script, ctx, [
                 {"CONSOLE_ENV_STAT_UID", "501"},
                 {"CONSOLE_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "WARNING: leaving untrusted console env file unchanged"
      assert output =~ "must be root-owned"
      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o640
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
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

  test "postinstall installs managed postgres guard without PATH symlink or launchd service" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      helper = Path.join([ctx.root, "bin", "orchard-managed-postgres"])
      helper_symlink = Path.join(ctx.local_bin, "orchard-managed-postgres")
      postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")

      File.write!(request_path, "controller\n")

      assert {_output, 0} = run_script(script, ctx)

      assert File.exists?(helper)
      refute File.exists?(helper_symlink)
      refute File.exists?(postgres)
      refute File.read!(ctx.launchctl_log) =~ "bootstrap system #{postgres}"
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

  test "controller wrapper sources valid console.env after controller.env without printing credentials" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        "ORCHARD_CONSOLE_ENABLED=false\n"
      )

      File.write!(
        Path.join([ctx.root, "config", "console.env"]),
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"CONSOLE_ENV_STAT_UID", "0"},
                 {"CONSOLE_ENV_STAT_MODE", "600"}
               ])

      assert output =~
               "orchard-controller: sourced #{Path.join([ctx.root, "config", "controller.env"])}"

      assert output =~
               "orchard-controller: sourced #{Path.join([ctx.root, "config", "console.env"])}"

      assert output =~ "fake console enabled=true"
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "controller wrapper configures BEAM release distribution by default" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_controller@10.0.0.10
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_BEAM_EPMD_PORT=43690
        ORCHARD_BEAM_DIST_PORT_MIN=52200
        ORCHARD_BEAM_DIST_PORT_MAX=52201
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "orchard-controller: Runtime Endpoint transport beam"
      assert output =~ "orchard-controller: BEAM node name orchard_controller@10.0.0.10"
      assert output =~ "orchard-controller: BEAM EPMD port 43690"
      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_controller@10.0.0.10"
      assert output =~ "fake release cookie=set"
      assert output =~ "fake epmd port=43690"
      assert output =~ "inet_dist_use_interface {10,0,0,10}"
      assert output =~ "inet_dist_listen_min 52200"
      assert output =~ "inet_dist_listen_max 52201"
      refute output =~ "fixture-cookie"
    end)
  end

  test "controller wrapper makes BEAM release identity authoritative over inherited env" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_controller@10.0.0.10
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"RELEASE_DISTRIBUTION", "none"},
                 {"RELEASE_NODE", "wrong@10.0.0.99"}
               ])

      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_controller@10.0.0.10"
      refute output =~ "wrong@10.0.0.99"
    end)
  end

  test "controller wrapper keeps loopback management distribution in gRPC compatibility mode" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "Runtime Endpoint transport grpc"
      assert output =~ "loopback Controller management distribution enabled"
      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_controller_management@127.0.0.1"
      assert output =~ "fake release cookie=set"
      assert output =~ "fake epmd port=4369"
      assert output =~ "fake epmd address=127.0.0.1"
      assert output =~ "inet_dist_use_interface {127,0,0,1}"
      assert output =~ "inet_dist_listen_min 52171"
    end)
  end

  test "controller wrapper rejects a pre-existing wildcard management EPMD listener" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"CONTROLLER_EPMD_LISTENER_MODE", "wildcard"}
               ])

      assert output =~
               "existing Controller management EPMD listener must bind exclusively to loopback"

      refute output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper makes gRPC management identity authoritative over inherited release env" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"RELEASE_DISTRIBUTION", "name"},
                 {"RELEASE_NODE", "wrong@10.0.0.99"},
                 {"RELEASE_COOKIE", "inherited-cookie"},
                 {"ERL_EPMD_PORT", "43699"},
                 {"ERL_AFLAGS", "-name wrong@10.0.0.99 -setcookie inherited-cookie"}
               ])

      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_controller_management@127.0.0.1"
      assert output =~ "fake release cookie=set"
      assert output =~ "fake epmd port=4369"
      assert output =~ "fake epmd address=127.0.0.1"
      assert output =~ "inet_dist_use_interface {127,0,0,1}"
      refute output =~ "wrong@10.0.0.99"
      refute output =~ "inherited-cookie"
    end)
  end

  test "controller wrapper rejects non-loopback gRPC management identity" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONTROLLER_MANAGEMENT_NODE_NAME=orchard_controller_management@10.0.0.10
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "ORCHARD_CONTROLLER_MANAGEMENT_NODE_NAME must use a loopback IPv4 address"
      refute output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper rejects non-root-owned BEAM cookie before release start" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_controller@10.0.0.10
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"COOKIE_STAT_UID", "501"}
               ])

      assert output =~ "ORCHARD_BEAM_COOKIE_FILE must be root-owned"
      refute output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper rejects group-readable BEAM cookie before release start" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_controller@10.0.0.10
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"COOKIE_STAT_MODE", "640"}
               ])

      assert output =~ "ORCHARD_BEAM_COOKIE_FILE must be owner-only"
      refute output =~ "fake orchard_controller start"
    end)
  end

  test "node-agent wrapper configures BEAM release distribution by default" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_node_agent@10.0.0.21
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_BEAM_EPMD_PORT=43690
        ORCHARD_BEAM_DIST_PORT_MIN=52210
        ORCHARD_BEAM_DIST_PORT_MAX=52210
        """
      )

      assert {output, 0} = run_node_agent_wrapper(script, ctx)

      assert output =~ "orchard-node-agent: Runtime Endpoint transport beam"
      assert output =~ "orchard-node-agent: BEAM node name orchard_node_agent@10.0.0.21"
      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_node_agent@10.0.0.21"
      assert output =~ "fake release cookie=set"
      assert output =~ "fake epmd port=43690"
      assert output =~ "inet_dist_use_interface {10,0,0,21}"
      assert output =~ "inet_dist_listen_min 52210"
      refute output =~ "fixture-cookie"
    end)
  end

  test "node-agent wrapper makes BEAM release identity authoritative over inherited env" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_node_agent@10.0.0.21
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        """
      )

      assert {output, 0} =
               run_node_agent_wrapper(script, ctx, [
                 {"RELEASE_DISTRIBUTION", "none"},
                 {"RELEASE_NODE", "wrong@10.0.0.99"}
               ])

      assert output =~ "fake release distribution=name"
      assert output =~ "fake release node=orchard_node_agent@10.0.0.21"
      refute output =~ "wrong@10.0.0.99"
    end)
  end

  test "node-agent wrapper makes gRPC fallback authoritative over inherited release env" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        """
      )

      assert {output, 0} =
               run_node_agent_wrapper(script, ctx, [
                 {"RELEASE_DISTRIBUTION", "name"},
                 {"RELEASE_NODE", "wrong@10.0.0.99"},
                 {"RELEASE_COOKIE", "inherited-cookie"},
                 {"ERL_EPMD_PORT", "43699"},
                 {"ERL_AFLAGS", "-name wrong@10.0.0.99 -setcookie inherited-cookie"}
               ])

      assert output =~ "Runtime Endpoint transport grpc"
      assert output =~ "compatibility fallback"
      assert output =~ "fake release distribution=none"
      assert output =~ "fake release node="
      assert output =~ "fake release cookie=unset"
      assert output =~ "fake epmd port="
      assert output =~ "fake erl aflags=\n"
      refute output =~ "wrong@10.0.0.99"
      refute output =~ "inherited-cookie"
    end)
  end

  test "node-agent wrapper rejects non-root-owned BEAM cookie before release start" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_node_agent@10.0.0.21
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        """
      )

      assert {output, 78} =
               run_node_agent_wrapper(script, ctx, [{"COOKIE_STAT_UID", "501"}])

      assert output =~ "ORCHARD_BEAM_COOKIE_FILE must be root-owned"
      refute output =~ "fake orchard_node_agent start"
    end)
  end

  test "node-agent wrapper rejects group-readable BEAM cookie before release start" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_node_agent@10.0.0.21
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        """
      )

      assert {output, 78} =
               run_node_agent_wrapper(script, ctx, [{"COOKIE_STAT_MODE", "640"}])

      assert output =~ "ORCHARD_BEAM_COOKIE_FILE must be owner-only"
      refute output =~ "fake orchard_node_agent start"
    end)
  end

  test "node-agent wrapper rejects missing BEAM cookie before release start" do
    with_temp_node_agent_wrapper(fn %{script: script} = ctx ->
      missing_cookie = Path.join([ctx.root, "config", "missing.cookie"])

      File.write!(
        Path.join([ctx.root, "config", "node-agent.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_node_agent@10.0.0.21
        ORCHARD_BEAM_COOKIE_FILE="#{missing_cookie}"
        """
      )

      assert {output, 78} = run_node_agent_wrapper(script, ctx)
      assert output =~ "ORCHARD_BEAM_COOKIE_FILE must point to an existing regular file"
      refute output =~ "fake orchard_node_agent start"
    end)
  end

  test "controller wrapper tolerates missing console.env" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        "ORCHARD_CONSOLE_ENABLED=false\n"
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "fake orchard_controller start"
      assert output =~ "fake console enabled=false"
      refute output =~ "console.env missing"
    end)
  end

  test "controller wrapper warns and skips non-root-owned console.env without printing credentials" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        "ORCHARD_CONSOLE_ENABLED=false\n"
      )

      File.write!(
        Path.join([ctx.root, "config", "console.env"]),
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"CONSOLE_ENV_STAT_UID", "501"},
                 {"CONSOLE_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "expected 0"
      assert output =~ "fake console enabled=false"
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "controller wrapper warns and skips console.env when stat inspection fails" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        "ORCHARD_CONSOLE_ENABLED=false\n"
      )

      File.write!(
        Path.join([ctx.root, "config", "console.env"]),
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"CONSOLE_ENV_STAT_FAIL", "true"}
               ])

      assert output =~ "could not inspect env file"
      assert output =~ "fake console enabled=false"
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "controller wrapper warns and skips insecure console.env without printing credentials" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        "ORCHARD_CONSOLE_ENABLED=false\n"
      )

      File.write!(
        Path.join([ctx.root, "config", "console.env"]),
        "ORCHARD_CONSOLE_ENABLED=true\nORCHARD_CONSOLE_USERNAME=operator\nORCHARD_CONSOLE_PASSWORD=super-secret-console-password\n"
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"CONSOLE_ENV_STAT_UID", "0"},
                 {"CONSOLE_ENV_STAT_MODE", "644"}
               ])

      assert output =~
               "WARNING: ignoring env file #{Path.join([ctx.root, "config", "console.env"])}"

      assert output =~ "group/world bits set"
      assert output =~ "fake console enabled=false"
      refute output =~ "operator"
      refute output =~ "super-secret-console-password"
    end)
  end

  test "controller wrapper rejects invalid ORCHARD_TRANSPORT_MODE with EX_CONFIG" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      assert {output, 78} =
               run_controller_wrapper(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "https"}])

      assert output =~ "ORCHARD_TRANSPORT_MODE has invalid value: https"
    end)
  end

  test "controller wrapper rejects partial cert/key overrides in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CERTFILE", "/tmp/controller.crt"}
               ])

      assert output =~
               "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must both be set or both unset"
    end)
  end

  test "controller wrapper rejects encrypted private keys in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join(ctx.root, "external-tls")
      certfile = Path.join(tls_dir, "operator.crt")
      keyfile = Path.join(tls_dir, "operator-encrypted.key")

      generate_self_signed_cert_with_encrypted_key!(certfile, keyfile)

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CERTFILE", certfile},
                 {"ORCHARD_TLS_KEYFILE", keyfile}
               ])

      assert output =~ "TLS private key is encrypted"
      refute output =~ "BEGIN ENCRYPTED PRIVATE KEY"
    end)
  end

  test "controller wrapper rejects mismatched cert/key overrides in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join(ctx.root, "external-tls")
      certfile = Path.join(tls_dir, "operator.crt")
      matching_keyfile = Path.join(tls_dir, "operator.key")
      mismatched_certfile = Path.join(tls_dir, "other.crt")
      mismatched_keyfile = Path.join(tls_dir, "other.key")

      generate_self_signed_cert!(certfile, matching_keyfile)
      generate_self_signed_cert!(mismatched_certfile, mismatched_keyfile)

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CERTFILE", certfile},
                 {"ORCHARD_TLS_KEYFILE", mismatched_keyfile}
               ])

      assert output =~ "TLS certificate and private key do not match"
      refute output =~ "BEGIN PRIVATE KEY"
    end)
  end

  test "controller wrapper allows default-path direct_https without generated-local metadata CA" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")

      generate_self_signed_cert!(certfile, keyfile)
      File.rm(cacertfile)

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])

      assert output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper ignores malformed or nested generated-local metadata" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")
      meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

      for metadata <- [
            "not-json",
            ~s({"source":"generated_local_ca",}),
            ~s({"nested":{"source":"generated_local_ca"}})
          ] do
        generate_self_signed_cert!(certfile, keyfile)
        File.rm(cacertfile)
        File.write!(meta_path, metadata)

        assert {output, 0} =
                 run_controller_wrapper(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])

        assert output =~ "fake orchard_controller start"
      end
    end)
  end

  test "controller wrapper rejects empty configured CA certificate path" do
    with_temp_controller_wrapper(fn %{script: script} ->
      assert {output, 78} =
               run_controller_wrapper_shell(
                 script,
                 "ORCHARD_TRANSPORT_MODE=direct_https ORCHARD_TLS_CACERTFILE= exec \"$1\" start"
               )

      assert output =~ "ORCHARD_TLS_CACERTFILE must not be empty"
    end)
  end

  test "controller wrapper allows generated-local default CA path override in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")

      generate_self_signed_cert!(certfile, keyfile)
      File.cp!(certfile, cacertfile)

      File.write!(
        Path.join(tls_dir, ".orchard-tls-meta.json"),
        ~s({"source":"generated_local_ca"})
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CACERTFILE", Path.join([tls_dir, "..", "tls", "ca.crt"])}
               ])

      assert output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper rejects generated-local CA override in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      external_tls_dir = Path.join(ctx.root, "external-tls")
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")
      operator_ca = Path.join(external_tls_dir, "operator-ca.crt")

      generate_self_signed_cert!(certfile, keyfile)
      File.cp!(certfile, cacertfile)
      File.mkdir_p!(external_tls_dir)
      File.cp!(certfile, operator_ca)

      File.write!(
        Path.join(tls_dir, ".orchard-tls-meta.json"),
        ~s({"source":"generated_local_ca"})
      )

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CACERTFILE", operator_ca}
               ])

      assert output =~ "ORCHARD_TLS_CACERTFILE cannot override generated-local CA publication"
    end)
  end

  test "controller wrapper rejects malformed generated-local CA in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")

      generate_self_signed_cert!(certfile, keyfile)

      File.write!(
        Path.join(tls_dir, ".orchard-tls-meta.json"),
        ~s({"source":"generated_local_ca"})
      )

      File.write!(cacertfile, "not a certificate\n")

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])

      assert output =~ "TLS CA certificate file is malformed"
    end)
  end

  test "controller wrapper rejects missing generated-local CA in direct_https" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join([ctx.root, "config", "tls"])
      certfile = Path.join(tls_dir, "controller.crt")
      keyfile = Path.join(tls_dir, "controller.key")
      cacertfile = Path.join(tls_dir, "ca.crt")

      generate_self_signed_cert!(certfile, keyfile)

      File.write!(
        Path.join(tls_dir, ".orchard-tls-meta.json"),
        ~s({"source":"generated_local_ca"})
      )

      File.rm(cacertfile)

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])

      assert output =~ "CA certificate not found"
      assert output =~ "Run: sudo orchardctl tls init --no-trust"
    end)
  end

  test "controller wrapper rejects certs that are not valid yet" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      tls_dir = Path.join(ctx.root, "external-tls")
      certfile = Path.join(tls_dir, "operator.crt")
      keyfile = Path.join(tls_dir, "operator.key")
      fake_bin = Path.join(ctx.root, "fake-bin")

      generate_self_signed_cert!(certfile, keyfile)
      File.mkdir_p!(fake_bin)
      fake_date = Path.join(fake_bin, "date")

      File.write!(fake_date, """
      #!/bin/sh
      if [ \"$1\" = \"-u\" ] && [ \"$2\" = \"+%s\" ]; then
        printf '0\\n'
        exit 0
      fi
      exec /bin/date \"$@\"
      """)

      File.chmod!(fake_date, 0o755)

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "direct_https"},
                 {"ORCHARD_TLS_CERTFILE", certfile},
                 {"ORCHARD_TLS_KEYFILE", keyfile},
                 {"PATH", fake_bin <> ":" <> ctx.fake_bin <> ":" <> System.get_env("PATH", "")}
               ])

      assert output =~ "TLS certificate is not valid yet"
    end)
  end

  test "controller wrapper maps legacy ORCHARD_TLS_DISABLED=false to direct_https preflight" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      assert {output, 78} =
               run_controller_wrapper(script, ctx, [{"ORCHARD_TLS_DISABLED", "false"}])

      assert output =~ "ORCHARD_TLS_DISABLED=false is deprecated"
      assert output =~ "TLS certificate not found"
      assert output =~ "Run: sudo orchardctl tls init --no-trust"
    end)
  end

  test "controller wrapper lets explicit plain_http_localhost win over legacy TLS envs" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"ORCHARD_TRANSPORT_MODE", "plain_http_localhost"},
                 {"ORCHARD_TLS_DISABLED", "false"},
                 {"ORCHARD_TLS_CERTFILE", "/missing/conflicting.crt"},
                 {"ORCHARD_TLS_KEYFILE", "/missing/conflicting.key"}
               ])

      assert output =~ "new transport mode wins"
      assert output =~ "fake orchard_controller start"
    end)
  end

  test "postinstall rejects group/world-writable request file after postgres cleanup" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      stale_postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])

      File.write!(request_path, "node-agent\n")
      File.write!(stale_controller, "stale controller plist\n")
      File.write!(stale_postgres, "stale postgres plist\n")

      assert {output, 1} = run_script(script, ctx, [{"REQUEST_STAT_MODE", "666"}])
      assert output =~ "must not be group/world writable"
      assert output =~ "removing unsupported managed Postgres LaunchDaemon"
      assert File.exists?(request_path)
      assert File.exists?(stale_controller)
      refute File.exists?(stale_postgres)
      refute File.exists?(node_agent)
      refute File.exists?(marker_path)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.postgres"
    end)
  end

  test "postinstall rejects request file with non-root owner after postgres cleanup" do
    with_temp_postinstall(fn %{script: script, request_path: request_path} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      stale_postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")

      File.write!(request_path, "node-agent\n")
      File.write!(stale_controller, "stale controller plist\n")
      File.write!(stale_postgres, "stale postgres plist\n")

      assert {output, 1} = run_script(script, ctx, [{"REQUEST_STAT_UID", "501"}])
      assert output =~ "must be root-owned"
      assert output =~ "removing unsupported managed Postgres LaunchDaemon"
      assert File.exists?(request_path)
      assert File.exists?(stale_controller)
      refute File.exists?(stale_postgres)
      refute File.exists?(node_agent)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.postgres"
    end)
  end

  test "postinstall rejects invalid existing role marker after postgres cleanup" do
    with_temp_postinstall(fn %{script: script} = ctx ->
      stale_controller = Path.join(ctx.launch_daemons, "com.orchard.controller.plist")
      node_agent = Path.join(ctx.launch_daemons, "com.orchard.node-agent.plist")
      stale_postgres = Path.join(ctx.launch_daemons, "com.orchard.postgres.plist")
      marker_path = Path.join([ctx.root, "support", ".install-role"])

      File.write!(marker_path, "invalid\n")
      File.write!(stale_controller, "stale controller plist\n")
      File.write!(stale_postgres, "stale postgres plist\n")

      assert {output, 1} = run_script(script, ctx)
      assert output =~ "invalid existing install role"
      assert output =~ "removing unsupported managed Postgres LaunchDaemon"
      assert File.exists?(marker_path)
      assert File.exists?(stale_controller)
      refute File.exists?(stale_postgres)
      refute File.exists?(node_agent)
      assert File.read!(ctx.launchctl_log) =~ "bootout system/com.orchard.postgres"
    end)
  end

  defp generate_self_signed_cert_with_encrypted_key!(certfile, keyfile) do
    openssl = openssl!()

    File.mkdir_p!(Path.dirname(certfile))
    File.mkdir_p!(Path.dirname(keyfile))

    {output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-keyout",
          keyfile,
          "-out",
          certfile,
          "-days",
          "365",
          "-subj",
          "/CN=localhost",
          "-passout",
          "pass:secret"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp generate_self_signed_cert!(certfile, keyfile) do
    openssl = openssl!()

    File.mkdir_p!(Path.dirname(certfile))
    File.mkdir_p!(Path.dirname(keyfile))

    {output, status} =
      System.cmd(
        openssl,
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          keyfile,
          "-out",
          certfile,
          "-days",
          "365",
          "-subj",
          "/CN=localhost"
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp openssl! do
    System.find_executable("openssl") || flunk("openssl is required for packaging script tests")
  end

  defp run_managed_postgres_wrapper(args \\ []) do
    System.cmd("sh", [@managed_postgres_wrapper | args], stderr_to_stdout: true)
  end

  defp assert_managed_postgres_guidance(output) do
    assert output =~ "managed Postgres is not available in this build"
    assert output =~ "external PostgreSQL"
    assert output =~ "does not install, bootstrap, or manage a local Postgres runtime"
    assert output =~ "sudo orchardctl env init"
    assert output =~ "DATABASE_URL"
    assert output =~ "sudo orchardctl migrate"
    assert output =~ "sudo orchardctl start"
    assert output =~ "packaging/pkg/README.md"
    assert output =~ "packaging/container/postgres/README.md"
    refute output =~ "M0 scaffold"
    refute output =~ "not implemented yet"
  end

  defp with_temp_controller_wrapper(fun) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-controller-wrapper-test-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp_dir, "Application Support/Orchard")
    script = Path.join(tmp_dir, "orchard-controller")
    fake_bin = Path.join(tmp_dir, "fake-bin")
    release_bin = Path.join([root, "releases", "orchard_controller", "bin"])
    cookie_file = Path.join([root, "config", "beam.cookie"])

    ctx = %{cookie_file: cookie_file, fake_bin: fake_bin, root: root, script: script}

    try do
      File.mkdir_p!(Path.join(root, "config"))
      File.mkdir_p!(Path.join(root, "config/tls"))
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(release_bin)
      File.write!(cookie_file, "fixture-cookie\n")
      File.chmod!(cookie_file, 0o600)

      release = Path.join(release_bin, "orchard_controller")

      File.write!(release, """
      #!/bin/sh
      printf 'fake orchard_controller %s\\n' "$*"
      printf 'fake console enabled=%s\\n' "${ORCHARD_CONSOLE_ENABLED:-}"
      printf 'fake release distribution=%s\\n' "${RELEASE_DISTRIBUTION:-}"
      printf 'fake release node=%s\\n' "${RELEASE_NODE:-}"
      if [ -n "${RELEASE_COOKIE:-}" ]; then
        printf 'fake release cookie=set\\n'
      else
        printf 'fake release cookie=unset\\n'
      fi
      printf 'fake epmd port=%s\\n' "${ERL_EPMD_PORT:-}"
      printf 'fake epmd address=%s\\n' "${ERL_EPMD_ADDRESS:-}"
      printf 'fake erl aflags=%s\\n' "${ERL_AFLAGS:-}"
      exit 0
      """)

      File.chmod!(release, 0o755)
      write_fake_controller_stat!(ctx)
      write_fake_controller_lsof!(ctx)
      write_test_controller_wrapper!(ctx)
      fun.(ctx)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp write_test_controller_wrapper!(ctx) do
    content =
      @controller_wrapper
      |> File.read!()
      |> String.replace(
        ~s(ORCHARD_ROOT="/Library/Application Support/Orchard"),
        ~s(ORCHARD_ROOT="#{ctx.root}")
      )
      |> String.replace("/usr/sbin/lsof", Path.join(ctx.fake_bin, "lsof"))

    File.write!(ctx.script, content)
    File.chmod!(ctx.script, 0o755)
  end

  defp write_fake_controller_stat!(ctx) do
    controller_env = Path.join([ctx.root, "config", "controller.env"])
    console_env = Path.join([ctx.root, "config", "console.env"])
    cookie_file = ctx.cookie_file

    File.write!(Path.join(ctx.fake_bin, "stat"), """
    #!/bin/sh
    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "#{controller_env}" ]; then
      printf '%s:%s\n' "${CONTROLLER_ENV_STAT_UID:-0}" "${CONTROLLER_ENV_STAT_MODE:-600}"
      exit 0
    fi

    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "#{console_env}" ]; then
      if [ "${CONSOLE_ENV_STAT_FAIL:-false}" = "true" ]; then
        exit 1
      fi
      printf '%s:%s\n' "${CONSOLE_ENV_STAT_UID:-0}" "${CONSOLE_ENV_STAT_MODE:-600}"
      exit 0
    fi

    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "#{cookie_file}" ]; then
      printf '%s:%s\n' "${COOKIE_STAT_UID:-0}" "${COOKIE_STAT_MODE:-600}"
      exit 0
    fi

    /usr/bin/stat "$@"
    """)

    File.chmod!(Path.join(ctx.fake_bin, "stat"), 0o755)
  end

  defp write_fake_controller_lsof!(ctx) do
    File.write!(Path.join(ctx.fake_bin, "lsof"), """
    #!/bin/sh
    case "${CONTROLLER_EPMD_LISTENER_MODE:-none}" in
      none) exit 1 ;;
      loopback) listener="127.0.0.1" ;;
      wildcard) listener="*" ;;
      *) exit 2 ;;
    esac
    port=${3#-iTCP:}
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\\n'
    printf 'epmd 123 root 0u IPv4 0 0t0 TCP %s:%s (LISTEN)\\n' "$listener" "$port"
    """)

    File.chmod!(Path.join(ctx.fake_bin, "lsof"), 0o755)
  end

  defp run_controller_wrapper(script, ctx, extra_env) do
    env = [{"PATH", ctx.fake_bin <> ":" <> System.get_env("PATH", "")}] ++ extra_env
    System.cmd("sh", [script, "start"], env: env, stderr_to_stdout: true)
  end

  defp run_controller_wrapper_shell(script, command) do
    fake_bin = Path.join(Path.dirname(script), "fake-bin")

    System.cmd("sh", ["-c", command, "sh", script],
      env: [{"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}],
      stderr_to_stdout: true
    )
  end

  defp with_temp_node_agent_wrapper(fun) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-node-agent-wrapper-test-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp_dir, "Application Support/Orchard")
    script = Path.join(tmp_dir, "orchard-node-agent")
    fake_bin = Path.join(tmp_dir, "fake-bin")
    release_bin = Path.join([root, "releases", "orchard_node_agent", "bin"])
    cookie_file = Path.join([root, "config", "beam.cookie"])

    ctx = %{cookie_file: cookie_file, fake_bin: fake_bin, root: root, script: script}

    try do
      File.mkdir_p!(Path.join(root, "config"))
      File.mkdir_p!(fake_bin)
      File.mkdir_p!(release_bin)
      File.write!(cookie_file, "fixture-cookie\n")
      File.chmod!(cookie_file, 0o600)

      release = Path.join(release_bin, "orchard_node_agent")

      File.write!(release, """
      #!/bin/sh
      printf 'fake orchard_node_agent %s\\n' "$*"
      printf 'fake release distribution=%s\\n' "${RELEASE_DISTRIBUTION:-}"
      printf 'fake release node=%s\\n' "${RELEASE_NODE:-}"
      if [ -n "${RELEASE_COOKIE:-}" ]; then
        printf 'fake release cookie=set\\n'
      else
        printf 'fake release cookie=unset\\n'
      fi
      printf 'fake epmd port=%s\\n' "${ERL_EPMD_PORT:-}"
      printf 'fake epmd address=%s\\n' "${ERL_EPMD_ADDRESS:-}"
      printf 'fake erl aflags=%s\\n' "${ERL_AFLAGS:-}"
      exit 0
      """)

      File.chmod!(release, 0o755)
      write_fake_node_agent_stat!(ctx)
      write_test_node_agent_wrapper!(ctx)
      fun.(ctx)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp write_test_node_agent_wrapper!(ctx) do
    content =
      @node_agent_wrapper
      |> File.read!()
      |> String.replace(
        ~s(ORCHARD_ROOT="/Library/Application Support/Orchard"),
        ~s(ORCHARD_ROOT="#{ctx.root}")
      )

    File.write!(ctx.script, content)
    File.chmod!(ctx.script, 0o755)
  end

  defp write_fake_node_agent_stat!(ctx) do
    node_agent_env = Path.join([ctx.root, "config", "node-agent.env"])
    cookie_file = ctx.cookie_file

    File.write!(Path.join(ctx.fake_bin, "stat"), """
    #!/bin/sh
    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "#{node_agent_env}" ]; then
      printf '%s:%s\n' "${NODE_AGENT_ENV_STAT_UID:-0}" "${NODE_AGENT_ENV_STAT_MODE:-600}"
      exit 0
    fi

    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ] && [ "$3" = "#{cookie_file}" ]; then
      printf '%s:%s\n' "${COOKIE_STAT_UID:-0}" "${COOKIE_STAT_MODE:-600}"
      exit 0
    fi

    /usr/bin/stat "$@"
    """)

    File.chmod!(Path.join(ctx.fake_bin, "stat"), 0o755)
  end

  defp run_node_agent_wrapper(script, ctx, extra_env \\ []) do
    env = [{"PATH", ctx.fake_bin <> ":" <> System.get_env("PATH", "")}] ++ extra_env
    System.cmd("sh", [script, "start"], env: env, stderr_to_stdout: true)
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

    for cmd <- [
          "orchard-controller",
          "orchard-node-agent",
          "orchardctl",
          "orchard-managed-postgres"
        ] do
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

    if [ "$1" = "-f" ] && [ "$2" = "%u:%Lp" ]; then
      case "$3" in
        */config/console.env)
          if [ "${CONSOLE_ENV_STAT_FAIL:-false}" = "true" ]; then
            exit 1
          fi
          printf '%s:%s\n' "${CONSOLE_ENV_STAT_UID:-0}" "${CONSOLE_ENV_STAT_MODE:-600}"
          exit 0
          ;;
      esac
    fi

    /usr/bin/stat "$@"
    """)

    for cmd <- ["chown", "launchctl", "stat"] do
      File.chmod!(Path.join(ctx.fake_bin, cmd), 0o755)
    end
  end

  defp remove_managed_tls_files!(ctx) do
    for file <- ["ca.key", "ca.crt", "controller.key", "controller.crt"] do
      File.rm!(Path.join([ctx.root, "config/tls", file]))
    end
  end

  defp install_managed_postgres_assets!(ctx) do
    managed_postgres = Path.join([ctx.root, "share/bin", "orchard-managed-postgres"])
    postgres_plist = Path.join([ctx.root, "share/launchd", "com.orchard.postgres.plist"])

    File.write!(managed_postgres, "#!/bin/sh\nexit 0\n")
    File.chmod!(managed_postgres, 0o755)
    File.write!(postgres_plist, "com.orchard.postgres\n")
  end

  defp run_script_with_empty_ca(script, ctx) do
    run_script_with_endpoint_assignment(script, ctx, "ORCHARD_TLS_CACERTFILE=")
  end

  defp run_script_with_endpoint_assignment(script, ctx, assignment) do
    path = ctx.fake_bin <> ":" <> System.get_env("PATH", "")

    command =
      "env LAUNCHCTL_LOG=\"$1\" PATH=\"$2\" REQUEST_STAT_PATH=\"$3\" #{assignment} \"$4\""

    System.cmd("sh", ["-c", command, "sh", ctx.launchctl_log, path, ctx.request_path, script],
      stderr_to_stdout: true
    )
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
