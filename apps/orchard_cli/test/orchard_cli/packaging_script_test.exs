defmodule OrchardCLI.PackagingScriptTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @controller_wrapper Path.join(@repo_root, "packaging/pkg/bin/orchard-controller")
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
        assert output =~ "Run next: sudo orchardctl start"
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
        assert output =~ "Run next: sudo orchardctl start"
      end)
    end
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

      assert {output, 1} = run_script(script, ctx, [{"ORCHARD_TRANSPORT_MODE", "direct_https"}])
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
                 {"PATH", fake_bin <> ":" <> System.get_env("PATH", "")}
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

  defp with_temp_controller_wrapper(fun) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "orchard-controller-wrapper-test-#{System.unique_integer([:positive])}"
      )

    root = Path.join(tmp_dir, "Application Support/Orchard")
    script = Path.join(tmp_dir, "orchard-controller")
    release_bin = Path.join([root, "releases", "orchard_controller", "bin"])

    ctx = %{root: root, script: script}

    try do
      File.mkdir_p!(Path.join(root, "config"))
      File.mkdir_p!(Path.join(root, "config/tls"))
      File.mkdir_p!(release_bin)

      release = Path.join(release_bin, "orchard_controller")

      File.write!(release, """
      #!/bin/sh
      printf 'fake orchard_controller %s\\n' "$*"
      exit 0
      """)

      File.chmod!(release, 0o755)
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

    File.write!(ctx.script, content)
    File.chmod!(ctx.script, 0o755)
  end

  defp run_controller_wrapper(script, _ctx, extra_env) do
    System.cmd("sh", [script, "start"], env: extra_env, stderr_to_stdout: true)
  end

  defp run_controller_wrapper_shell(script, command) do
    System.cmd("sh", ["-c", command, "sh", script], stderr_to_stdout: true)
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
