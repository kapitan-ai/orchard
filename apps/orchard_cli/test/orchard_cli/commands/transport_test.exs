defmodule OrchardCLI.Commands.TransportTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Transport
  alias OrchardCLI.ShellEnv

  defp current_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _other -> 0
    end
  end

  defp tmp_support_root do
    System.tmp_dir!()
    |> Path.join("orchard-transport-test-#{System.unique_integer([:positive])}")
  end

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        owner_uid: current_uid(),
        read_install_role: fn -> {:ok, "all"} end,
        tls_init: fn host, _support_root -> {:ok, "tls initialized for #{host}"} end,
        now: fn -> ~U[2026-05-18 02:03:04Z] end,
        cmd: fn
          "launchctl", ["print", "system/com.orchard.controller"], _opts ->
            {"Could not find service", 113}

          _program, _args, _opts ->
            flunk("unexpected command invocation")
        end
      },
      overrides
    )
  end

  defp write_controller_env(support_root, contents) do
    config_dir = Path.join(support_root, "config")
    File.mkdir_p!(config_dir)
    path = Path.join(config_dir, "controller.env")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  defp write_generated_ca(support_root) do
    tls_dir = Path.join([support_root, "config", "tls"])
    File.mkdir_p!(tls_dir)
    File.write!(Path.join(tls_dir, "ca.crt"), "public ca cert")
    File.write!(Path.join(tls_dir, "controller.crt"), "public server cert")
    File.write!(Path.join(tls_dir, "controller.key"), "private server key")

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{
        "source" => "generated_local_ca",
        "san_dns" => ["localhost", "mawarduri", "mawarduri.local", "newhost"],
        "san_ip" => []
      })
    )

    :ok
  end

  test "help returns usage" do
    assert {:ok, message} = Transport.run(["enable-local-https", "--help"], base_runtime())
    assert message =~ "orchardctl transport enable-local-https --host HOST [--port PORT]"
    assert message =~ "8443"
  end

  test "group usage is returned for missing or unknown subcommands" do
    assert {:error, message, 1} = Transport.run([], base_runtime())
    assert message =~ "orchardctl transport <command>"

    assert {:error, message, 1} = Transport.run(["bogus"], base_runtime())
    assert message =~ "enable-local-https"
  end

  test "requires --host and rejects unexpected arguments" do
    assert {:error, message, 1} = Transport.run(["enable-local-https"], base_runtime())
    assert message =~ "--host is required"

    assert {:error, message, 1} =
             Transport.run(["enable-local-https", "--host", "mawarduri", "extra"], base_runtime())

    assert message =~ "unexpected argument"
  end

  test "rejects invalid host before invoking TLS or writing files" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _support_root ->
          send(parent, :tls_called)
          {:ok, ""}
        end
      })

    try do
      for host <- ["", "bad host", "https://mawarduri", "bad,host", "bad\nhost"] do
        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", host], runtime)

        assert message =~ "invalid --host"
      end

      refute_received :tls_called
      refute File.exists?(Path.join([support_root, "config", "controller.env"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "rejects invalid port before invoking TLS or writing files" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _support_root ->
          send(parent, :tls_called)
          {:ok, ""}
        end
      })

    try do
      for port <- ["0", "65536", "not-a-port"] do
        assert {:error, message, 1} =
                 Transport.run(
                   ["enable-local-https", "--host", "mawarduri", "--port", port],
                   runtime
                 )

        assert message =~ "invalid --port"
      end

      refute_received :tls_called
      refute File.exists?(Path.join([support_root, "config", "controller.env"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "requires root for controller-bearing roles" do
    runtime = base_runtime(%{uid: fn -> 501 end})

    assert {:error, message, 1} =
             Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

    assert message =~ "root privileges required"
    assert message =~ "sudo orchardctl transport enable-local-https --host HOST"
  end

  test "node-agent role is not applicable and does not require root" do
    runtime =
      base_runtime(%{
        uid: fn -> 501 end,
        read_install_role: fn -> {:ok, "node-agent"} end,
        tls_init: fn _host, _support_root -> flunk("node-agent role must not initialize TLS") end
      })

    assert {:ok, message} = Transport.run(["enable-local-https", "--host", "worker"], runtime)
    assert message =~ "not applicable for node-agent role"
    refute message =~ "root privileges required"
  end

  test "missing controller env fails before TLS or sidecar writes" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root ->
          send(parent, :tls_called)
          {:ok, ""}
        end
      })

    try do
      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "controller.env not found"
      assert message =~ "sudo orchardctl env init"
      refute_received :tls_called
      refute File.exists?(Path.join([support_root, "public", "endpoint.json"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "default port upserts controller env, publishes CA, writes sidecar, and prints start guidance" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn host, root ->
          send(parent, {:tls_init, host, root})
          write_generated_ca(root)
          {:ok, "tls initialized"}
        end
      })

    try do
      write_controller_env(support_root, "# existing\nDATABASE_URL=\"ecto://local\"\n")

      assert {:ok, message} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert_received {:tls_init, "mawarduri", ^support_root}

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      assert controller_env =~ ~s(DATABASE_URL="ecto://local")
      assert controller_env =~ ~r/^ORCHARD_TRANSPORT_MODE="direct_https"$/m
      assert controller_env =~ ~r/^ORCHARD_PUBLIC_HOST="mawarduri"$/m
      assert controller_env =~ ~r/^ORCHARD_API_HTTPS_PORT="8443"$/m
      refute controller_env =~ ~r/^ORCHARD_TLS_CERTFILE=/m
      refute controller_env =~ ~r/^ORCHARD_TLS_KEYFILE=/m
      refute controller_env =~ ~r/^ORCHARD_TLS_CACERTFILE=/m

      public_ca = Path.join([support_root, "public", "ca.crt"])
      assert File.read!(public_ca) == "public ca cert"
      assert Bitwise.band(File.stat!(support_root).mode, 0o777) == 0o711
      assert Bitwise.band(File.stat!(Path.dirname(public_ca)).mode, 0o777) == 0o755
      assert Bitwise.band(File.stat!(public_ca).mode, 0o777) == 0o644

      assert {:ok, endpoint} =
               OrchardCLI.EndpointMetadata.read(
                 path: Path.join([support_root, "public", "endpoint.json"])
               )

      assert endpoint.transport_mode == "direct_https"
      assert endpoint.public_host == "mawarduri"
      assert endpoint.api_https_port == 8443
      assert endpoint.plain_http_port == nil
      assert endpoint.ca_certfile == public_ca
      assert endpoint.generated_by == "orchardctl transport enable-local-https"
      assert endpoint.updated_at == "2026-05-18T02:03:04Z"

      assert message =~ "Direct HTTPS transport enabled"
      assert message =~ "https://mawarduri:8443"
      assert message =~ "CA certificate: #{public_ca}"
      assert message =~ "Run: sudo orchardctl start"
    after
      File.rm_rf(support_root)
    end
  end

  test "unsafe public directory stops before controller env mutation" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end
      })

    try do
      original = "SECRET_KEY_BASE=\"secret\"\n"
      write_controller_env(support_root, original)
      File.mkdir_p!(Path.join(support_root, "public"))
      File.chmod!(Path.join(support_root, "public"), 0o777)

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "group/world writable"
      assert File.read!(Path.join([support_root, "config", "controller.env"])) == original
    after
      File.rm_rf(support_root)
    end
  end

  test "endpoint sidecar failure stops before controller env mutation" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        copy_public_ca: fn _source, _target -> {:error, "permission denied"} end
      })

    try do
      original = "SECRET_KEY_BASE=\"secret\"\n"
      write_controller_env(support_root, original)
      File.write!(Path.join(support_root, "public"), "not a directory")

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "enotdir"
      assert File.read!(Path.join([support_root, "config", "controller.env"])) == original
    after
      File.rm_rf(support_root)
    end
  end

  test "controller env upsert failure restores previous endpoint metadata" do
    support_root = tmp_support_root()
    endpoint_path = Path.join([support_root, "public", "endpoint.json"])

    old_endpoint =
      ~s({"schema_version":1,"transport_mode":"plain_http_localhost","public_host":"oldhost","api_https_port":null,"plain_http_port":4000,"api_bind_ip":"127.0.0.1","ca_certfile":null,"updated_at":"2026-05-18T00:00:00Z","generated_by":"test"}\n)

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        shell_env_upsert: fn _path, _assignments -> {:error, "disk full"} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
      File.mkdir_p!(Path.dirname(endpoint_path))
      File.write!(endpoint_path, old_endpoint)

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "disk full"
      assert File.read!(endpoint_path) == old_endpoint
    after
      File.rm_rf(support_root)
    end
  end

  test "controller env upsert failure deletes newly-created endpoint metadata" do
    support_root = tmp_support_root()
    endpoint_path = Path.join([support_root, "public", "endpoint.json"])

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        shell_env_upsert: fn _path, _assignments -> {:error, "disk full"} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "disk full"
      refute File.exists?(endpoint_path)
    after
      File.rm_rf(support_root)
    end
  end

  test "CA publish failure omits ca_certfile without blocking env or sidecar update" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        copy_public_ca: fn _source, _target -> {:error, "permission denied"} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:ok, message} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "could not be published"

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      assert controller_env =~ ~r/^ORCHARD_TRANSPORT_MODE="direct_https"$/m

      {:ok, endpoint} =
        OrchardCLI.EndpointMetadata.read(
          path: Path.join([support_root, "public", "endpoint.json"])
        )

      assert endpoint.ca_certfile == nil
    after
      File.rm_rf(support_root)
    end
  end

  test "custom port is written to controller env and endpoint sidecar" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:ok, message} =
               Transport.run(
                 ["enable-local-https", "--host", "mawarduri.local", "--port", "9443"],
                 runtime
               )

      assert message =~ "https://mawarduri.local:9443"

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      assert controller_env =~ ~r/^ORCHARD_API_HTTPS_PORT="9443"$/m

      {:ok, endpoint} =
        OrchardCLI.EndpointMetadata.read(
          path: Path.join([support_root, "public", "endpoint.json"])
        )

      assert endpoint.api_https_port == 9443
    after
      File.rm_rf(support_root)
    end
  end

  test "existing transport lines are replaced while unrelated and commented TLS lines are preserved" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end
      })

    try do
      write_controller_env(support_root, """
      # ORCHARD_TRANSPORT_MODE="plain_http_localhost"
      DATABASE_URL="ecto://local"
      ORCHARD_TRANSPORT_MODE="plain_http_localhost"
      ORCHARD_PUBLIC_HOST="oldhost"
      ORCHARD_API_HTTPS_PORT="7443"
      # ORCHARD_TLS_CERTFILE="/operator/server.crt"
      # ORCHARD_TLS_KEYFILE="/operator/server.key"
      # ORCHARD_TLS_CACERTFILE="/operator/ca.crt"
      ORCHARD_RUNTIME_CLIENT_TARGETS="worker:50061"
      """)

      assert {:ok, _message} =
               Transport.run(
                 ["enable-local-https", "--host", "newhost", "--port", "9443"],
                 runtime
               )

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      assert controller_env =~ ~s(# ORCHARD_TRANSPORT_MODE="plain_http_localhost")
      assert controller_env =~ ~s(DATABASE_URL="ecto://local")
      assert controller_env =~ ~s(ORCHARD_RUNTIME_CLIENT_TARGETS="worker:50061")
      assert controller_env =~ ~s(# ORCHARD_TLS_CERTFILE="/operator/server.crt")
      assert controller_env =~ ~s(# ORCHARD_TLS_KEYFILE="/operator/server.key")
      assert controller_env =~ ~s(# ORCHARD_TLS_CACERTFILE="/operator/ca.crt")
      assert controller_env =~ ~r/^ORCHARD_TRANSPORT_MODE="direct_https"$/m
      assert controller_env =~ ~r/^ORCHARD_PUBLIC_HOST="newhost"$/m
      assert controller_env =~ ~r/^ORCHARD_API_HTTPS_PORT="9443"$/m
      refute controller_env =~ ~r/^ORCHARD_PUBLIC_HOST="oldhost"$/m
    after
      File.rm_rf(support_root)
    end
  end

  test "active TLS overrides are rejected without mutating them or writing sidecar" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root ->
          send(parent, :tls_called)
          {:ok, ""}
        end
      })

    try do
      original = """
      SECRET_KEY_BASE="secret"
      ORCHARD_TLS_CERTFILE="/operator/server.crt"
      ORCHARD_TLS_KEYFILE="/operator/server.key"
      """

      write_controller_env(support_root, original)

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "ORCHARD_TLS_CERTFILE"
      assert message =~ "operator-provided TLS overrides"
      refute_received :tls_called
      assert File.read!(Path.join([support_root, "config", "controller.env"])) == original
      refute File.exists?(Path.join([support_root, "public", "endpoint.json"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "pre-existing generated TLS material for host is reused without invoking tls init" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root ->
          send(parent, :tls_called)
          {:ok, ""}
        end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
      write_generated_ca(support_root)

      assert {:ok, message} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      refute_received :tls_called
      assert message =~ "Direct HTTPS transport enabled"
      assert File.exists?(Path.join([support_root, "public", "ca.crt"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "pre-existing generated TLS material for a different host is rejected" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root ->
          flunk("mismatched existing TLS must not be reused or overwritten")
        end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
      write_generated_ca(support_root)

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "otherhost"], runtime)

      assert message =~ "does not include --host otherhost"
      refute File.exists?(Path.join([support_root, "public", "endpoint.json"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "shell env writer safely quotes metacharacters and rejects control characters" do
    assert ShellEnv.shell_quote(~s(host"$`\\#value)) == ~s("host\\"\\$\\`\\\\#value")

    for value <- [
          "bad\nvalue",
          "bad\rvalue",
          "bad\tvalue",
          "bad\0value",
          <<"bad", 0x7F, "value">>
        ] do
      assert {:error, message} = ShellEnv.validate_value(value)
      assert message =~ "control characters"
    end
  end

  test "shell env writer round-trips metacharacters through /bin/sh without execution" do
    support_root = tmp_support_root()
    env_path = Path.join(support_root, "metachar.env")
    marker_path = Path.join(support_root, "executed")

    value = ~s(value#with'quotes" $HOME `touch #{marker_path}` \\ end)

    try do
      assert :ok = ShellEnv.upsert(env_path, [{"ORCHARD_PUBLIC_HOST", value}])

      script = "set -a; . \"$1\"; printf '%s' \"$ORCHARD_PUBLIC_HOST\""
      assert {^value, 0} = System.cmd("/bin/sh", ["-c", script, "sh", env_path])
      refute File.exists?(marker_path)
    after
      File.rm_rf(support_root)
    end
  end

  test "loaded controller restarts only controller through lifecycle support" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, root ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"{ pid = 123 }", 0}
            ["kickstart", "-k", "system/com.orchard.controller"] -> {"", 0}
            unexpected -> flunk("unexpected launchctl args: #{inspect(unexpected)}")
          end
        end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:ok, message} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "Controller restarted"
      refute message =~ "node-agent"

      assert [
               {"launchctl", ["print", "system/com.orchard.controller"], _print_opts},
               {"launchctl", ["kickstart", "-k", "system/com.orchard.controller"], _kick_opts}
             ] = collect_cmds()
    after
      File.rm_rf(support_root)
    end
  end

  test "TLS init failures stop before env and sidecar writes" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root -> {:error, "Error: tls failed", 1} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "tls failed"

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      refute controller_env =~ "ORCHARD_TRANSPORT_MODE"
      refute File.exists?(Path.join([support_root, "public", "endpoint.json"]))
    after
      File.rm_rf(support_root)
    end
  end

  defp collect_cmds do
    collect_cmds([])
  end

  defp collect_cmds(acc) do
    receive do
      {:cmd, program, args, opts} -> collect_cmds([{program, args, opts} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
