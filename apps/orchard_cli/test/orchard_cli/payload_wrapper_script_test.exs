defmodule OrchardCLI.PayloadWrapperScriptTest do
  @moduledoc """
  Behavioral regression tests for the staged payload wrapper scripts in
  `packaging/payload/bin/`. `scripts/build-payload.sh` copies these wrappers
  verbatim into the app payload, so their boot gates are the last check before a
  root-owned launchd service execs a BEAM release.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @controller_wrapper Path.join(@repo_root, "packaging/payload/bin/orchard-controller")
  @node_agent_wrapper Path.join(@repo_root, "packaging/payload/bin/orchard-node-agent")
  @managed_postgres_wrapper Path.join(
                              @repo_root,
                              "packaging/payload/bin/orchard-managed-postgres"
                            )

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

  test "controller wrapper clears inherited ERL_EPMD_ADDRESS for cluster distribution" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
        ORCHARD_BEAM_NODE_NAME=orchard_controller@10.0.0.10
        ORCHARD_BEAM_COOKIE_FILE="#{ctx.cookie_file}"
        ORCHARD_CONSOLE_ENABLED=false
        ERL_EPMD_ADDRESS=127.0.0.1
        """
      )

      for inherited <- [[], [{"ERL_AFLAGS", "-kernel inet_dist_listen_min 52300"}]] do
        assert {output, 0} =
                 run_controller_wrapper(
                   script,
                   ctx,
                   [
                     {"CONTROLLER_ENV_STAT_UID", "0"},
                     {"CONTROLLER_ENV_STAT_MODE", "600"}
                   ] ++ inherited
                 )

        assert output =~ "fake epmd address=\n"
        assert output =~ "inet_dist_use_interface {10,0,0,10}"
      end
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

  test "controller wrapper accepts a pre-existing loopback management EPMD listener" do
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
                 {"CONTROLLER_EPMD_LISTENER_MODE", "loopback"}
               ])

      assert output =~ "fake orchard_controller start"
      assert output =~ "fake release node=orchard_controller_management@127.0.0.1"
    end)
  end

  test "controller wrapper starts when EPMD inspection emits only benign advisories" do
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
                 {"CONTROLLER_EPMD_LISTENER_MODE", "none-with-advisory"}
               ])

      assert output =~ "fake orchard_controller start"
      refute output =~ "could not inspect the Controller management EPMD listener"
      refute output =~ "Output information may be incomplete"
    end)
  end

  test "controller wrapper ignores a hostile TMPDIR while inspecting the EPMD listener" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONSOLE_ENABLED=false
        TMPDIR="#{Path.join(ctx.root, "no-such-tmpdir")}"
        """
      )

      assert {output, 0} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"},
                 {"TMPDIR", "/nonexistent/orchard-hostile-tmpdir"}
               ])

      assert output =~ "fake orchard_controller start"
      refute output =~ "could not inspect the Controller management EPMD listener"
    end)
  end

  test "controller wrapper fails closed when management EPMD inspection errors" do
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
                 {"CONTROLLER_EPMD_LISTENER_MODE", "inspection-error"}
               ])

      assert output =~ "could not inspect the Controller management EPMD listener"
      refute output =~ "fake orchard_controller start"
    end)
  end

  test "controller wrapper fails closed when the management EPMD inspector is unavailable" do
    with_temp_controller_wrapper(fn %{script: script} = ctx ->
      File.write!(
        Path.join([ctx.root, "config", "controller.env"]),
        """
        ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
        ORCHARD_CONSOLE_ENABLED=false
        """
      )

      File.rm!(Path.join(ctx.fake_bin, "lsof"))

      assert {output, 78} =
               run_controller_wrapper(script, ctx, [
                 {"CONTROLLER_ENV_STAT_UID", "0"},
                 {"CONTROLLER_ENV_STAT_MODE", "600"}
               ])

      assert output =~ "could not inspect the Controller management EPMD listener"
      assert output =~ "is not executable"
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
    assert output =~ "packaging/README.md"
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
    warn=true
    for arg in "$@"; do
      case "$arg" in
        -w) warn=false ;;
        -iTCP:*) port=${arg#-iTCP:} ;;
      esac
    done

    case "${CONTROLLER_EPMD_LISTENER_MODE:-none}" in
      none) exit 1 ;;
      none-with-advisory)
        if [ "$warn" = true ]; then
          printf "lsof: WARNING: can't stat() smbfs file system /Volumes/share\\n" >&2
          printf '      Output information may be incomplete.\\n' >&2
        fi
        exit 1
        ;;
      loopback) listener="127.0.0.1" ;;
      wildcard) listener="*" ;;
      *) exit 2 ;;
    esac

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
end
