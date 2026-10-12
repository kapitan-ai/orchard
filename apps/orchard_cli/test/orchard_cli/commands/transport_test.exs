defmodule OrchardCLI.Commands.TransportTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Transport
  alias OrchardCLI.ShellEnv
  alias OrchardCLI.TransportFixture

  defp tmp_support_root, do: TransportFixture.support_root!()

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        publication_opts: [executable: TransportFixture.helper(:production)],
        read_install_role: fn -> {:ok, "all"} end,
        tls_init: fn host, _support_root, _stage_dir -> {:ok, "tls initialized for #{host}"} end,
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
    File.chmod!(config_dir, 0o700)
    path = Path.join(config_dir, "controller.env")
    File.write!(path, contents)
    File.chmod!(path, 0o600)
    path
  end

  defp write_generated_ca(support_root) do
    tls_dir = Path.join([support_root, "config", "tls"])
    File.mkdir_p!(tls_dir)
    File.chmod!(tls_dir, 0o750)
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
        tls_init: fn _host, _support_root, _stage_dir ->
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
        tls_init: fn _host, _support_root, _stage_dir ->
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
        tls_init: fn _host, _support_root, _stage_dir ->
          flunk("node-agent role must not initialize TLS")
        end
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
        tls_init: fn _host, _root, _stage_dir ->
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
        tls_init: fn host, root, _stage_dir ->
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
               Orchard.EndpointMetadata.read(
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

  test "unsafe public directory stops before TLS or controller env mutation" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      base_runtime(%{
        support_root: support_root,
        tls_init: fn _host, _root, _stage_dir ->
          send(parent, :tls_called)
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
      refute_received :tls_called
      assert TransportFixture.mode(Path.join(support_root, "public")) == 0o777
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
        tls_init: fn _host, root, _stage_dir ->
          write_generated_ca(root)
          {:ok, ""}
        end
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
        tls_init: fn _host, root, _stage_dir ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        shell_env_upsert: fn _path, _assignments -> {:error, "disk full"} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
      File.mkdir!(Path.dirname(endpoint_path))
      File.chmod!(Path.dirname(endpoint_path), 0o755)
      File.write!(endpoint_path, old_endpoint)
      File.chmod!(endpoint_path, 0o644)

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
        tls_init: fn _host, root, _stage_dir ->
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
        tls_init: fn _host, root, _stage_dir ->
          write_generated_ca(root)
          {:ok, ""}
        end,
        read_public_ca: fn _source -> {:error, "permission denied"} end
      })

    try do
      write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

      assert {:ok, message} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ "could not be published"

      controller_env = File.read!(Path.join([support_root, "config", "controller.env"]))
      assert controller_env =~ ~r/^ORCHARD_TRANSPORT_MODE="direct_https"$/m

      {:ok, endpoint} =
        Orchard.EndpointMetadata.read(path: Path.join([support_root, "public", "endpoint.json"]))

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
        tls_init: fn _host, root, _stage_dir ->
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
        Orchard.EndpointMetadata.read(path: Path.join([support_root, "public", "endpoint.json"]))

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
        tls_init: fn _host, root, _stage_dir ->
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
        tls_init: fn _host, _root, _stage_dir ->
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
        tls_init: fn _host, _root, _stage_dir ->
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
        tls_init: fn _host, _root, _stage_dir ->
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
        tls_init: fn _host, root, _stage_dir ->
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
        tls_init: fn _host, _root, _stage_dir -> {:error, "Error: tls failed", 1} end
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

  describe "private-stage publication (SPEC.md §10.7, ADR 0036)" do
    defp enabled_runtime(support_root, overrides) do
      parent = self()

      base_runtime(
        Map.merge(
          %{
            support_root: support_root,
            tls_init: fn _host, root, _stage_dir ->
              send(parent, :tls_called)
              write_generated_ca(root)
              {:ok, ""}
            end
          },
          overrides
        )
      )
    end

    defp assert_public_profile(support_root, ca_contents \\ "public ca cert") do
      public = Path.join(support_root, "public")
      assert TransportFixture.mode(support_root) == 0o711
      assert TransportFixture.mode(public) == 0o755
      assert TransportFixture.mode(Path.join(public, "ca.crt")) == 0o644
      assert TransportFixture.mode(Path.join(public, "endpoint.json")) == 0o644
      assert Enum.sort(File.ls!(public)) == ["ca.crt", "endpoint.json"]
      assert File.read!(Path.join(public, "ca.crt")) == ca_contents
      assert_endpoint_metadata_has_no_private_material(support_root)
      assert TransportFixture.stage_entries(support_root) == []
    end

    defp assert_endpoint_metadata_has_no_private_material(support_root) do
      public = Path.join(support_root, "public")
      tls_dir = Path.join([support_root, "config", "tls"])
      contents = File.read!(Path.join(public, "endpoint.json"))
      metadata = Jason.decode!(contents)

      assert metadata["ca_certfile"] == Path.join(public, "ca.crt")
      refute Enum.any?(Map.keys(metadata), &(&1 =~ ~r/key|secret|cookie/i))

      for forbidden <- [
            "private server key",
            "SECRET_KEY_BASE",
            Path.join(tls_dir, "controller.key"),
            Path.join(support_root, "config")
          ] do
        refute contents =~ forbidden
      end
    end

    for umask <- [0o022, 0o077, 0o002, 0o000] do
      @umask umask
      test "helper child umask #{Integer.to_string(umask, 8)} still publishes the public read profile" do
        support_root = tmp_support_root()

        runtime =
          enabled_runtime(support_root, %{
            publication_opts: [
              executable: TransportFixture.helper(:production),
              wrapper: TransportFixture.umask_wrapper(@umask)
            ]
          })

        try do
          write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

          assert {:ok, _message} =
                   Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

          assert_public_profile(support_root)
        after
          File.rm_rf(support_root)
        end
      end
    end

    test "TLS initialization receives the private owner-only publication stage" do
      support_root = tmp_support_root()
      parent = self()

      runtime =
        enabled_runtime(support_root, %{
          tls_init: fn _host, root, stage_dir ->
            send(
              parent,
              {:tls_stage, stage_dir, TransportFixture.mode(stage_dir), File.ls!(stage_dir)}
            )

            write_generated_ca(root)
            {:ok, ""}
          end
        })

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

        assert {:ok, _message} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert_received {:tls_stage, stage_dir, 0o700, []}
        assert Path.dirname(stage_dir) == support_root
        assert Path.basename(stage_dir) =~ ~r/\A\.orchard-public-stage-[A-Za-z0-9]+\z/
        refute File.exists?(stage_dir)
        assert_public_profile(support_root)
      after
        File.rm_rf(support_root)
      end
    end

    @tag :integration
    test "default TLS initialization generates inside the private stage and publishes" do
      support_root = tmp_support_root()
      runtime = support_root |> enabled_runtime(%{}) |> Map.delete(:tls_init)

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

        assert {:ok, _message} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        tls_dir = Path.join([support_root, "config", "tls"])

        assert Enum.sort(File.ls!(tls_dir)) ==
                 Enum.sort(~w(ca.key ca.crt controller.key controller.crt .orchard-tls-meta.json))

        assert TransportFixture.mode(Path.join(tls_dir, "ca.key")) == 0o600
        assert TransportFixture.mode(Path.join(tls_dir, "controller.key")) == 0o600

        assert_public_profile(support_root, File.read!(Path.join(tls_dir, "ca.crt")))
      after
        File.rm_rf(support_root)
      end
    end

    for mode <- [0o700, 0o750] do
      @mode mode
      test "safe existing public directory #{Integer.to_string(mode, 8)} is accepted" do
        support_root = tmp_support_root()
        runtime = enabled_runtime(support_root, %{})

        try do
          write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
          File.mkdir!(Path.join(support_root, "public"))
          File.chmod!(Path.join(support_root, "public"), @mode)

          assert {:ok, _message} =
                   Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

          assert_public_profile(support_root)
        after
          File.rm_rf(support_root)
        end
      end
    end

    for mode <- [0o775, 0o777] do
      @mode mode
      test "unsafe support root #{Integer.to_string(mode, 8)} refuses before TLS" do
        support_root = tmp_support_root()
        runtime = enabled_runtime(support_root, %{})

        try do
          write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
          File.chmod!(support_root, @mode)

          assert {:error, message, 1} =
                   Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

          assert message =~ "support root is group/world writable"
          refute_received :tls_called
          assert TransportFixture.mode(support_root) == @mode
          refute File.exists?(Path.join(support_root, "public"))
          refute File.exists?(Path.join([support_root, "config", "tls"]))
        after
          File.rm_rf(support_root)
        end
      end
    end

    test "symlinked public directory refuses before TLS without touching the target" do
      support_root = tmp_support_root()
      target = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        File.ln_s!(target, Path.join(support_root, "public"))

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert message =~ "public endpoint directory is a symlink"
        refute_received :tls_called
        assert File.ls!(target) == []
        assert TransportFixture.mode(target) == 0o700
      after
        File.rm_rf(support_root)
        File.rm_rf(target)
      end
    end

    defp assert_refused_unchanged(support_root, runtime, expected) do
      original = File.read!(Path.join([support_root, "config", "controller.env"]))

      assert {:error, message, 1} =
               Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

      assert message =~ expected
      refute_received :tls_called
      refute File.exists?(Path.join(support_root, "public"))
      assert TransportFixture.stage_entries(support_root) == []
      assert File.read!(Path.join([support_root, "config", "controller.env"])) == original
    end

    for {mode, reason} <- [
          {0o750, "Orchard config directory is accessible to group or other users"},
          {0o755, "Orchard config directory is accessible to group or other users"},
          {0o777, "Orchard config directory is group/world writable"}
        ] do
      @mode mode
      @reason reason
      test "config directory #{Integer.to_string(mode, 8)} refuses before TLS unchanged" do
        support_root = tmp_support_root()
        runtime = enabled_runtime(support_root, %{})

        try do
          write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
          config_dir = Path.join(support_root, "config")
          File.chmod!(config_dir, @mode)

          assert_refused_unchanged(support_root, runtime, @reason)
          assert TransportFixture.mode(config_dir) == @mode
          refute File.exists?(Path.join(config_dir, "tls"))
        after
          File.rm_rf(support_root)
        end
      end
    end

    test "symlinked config directory refuses before TLS without touching the target" do
      support_root = tmp_support_root()
      target = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        File.write!(Path.join(target, "controller.env"), "SECRET_KEY_BASE=\"secret\"\n")
        File.ln_s!(target, Path.join(support_root, "config"))

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert message =~ "Orchard config directory is a symlink"
        refute_received :tls_called
        assert File.ls!(target) == ["controller.env"]
        refute File.exists?(Path.join(support_root, "public"))
      after
        File.rm_rf(support_root)
        File.rm_rf(target)
      end
    end

    test "symlinked controller.env refuses before TLS without mutating the target" do
      support_root = tmp_support_root()
      target_root = tmp_support_root()
      target = Path.join(target_root, "controller.env")
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        env_path = Path.join([support_root, "config", "controller.env"])
        File.write!(target, "SECRET_KEY_BASE=\"elsewhere\"\n")
        File.rm!(env_path)
        File.ln_s!(target, env_path)

        assert_refused_unchanged(support_root, runtime, "controller.env is a symlink")
        assert File.read!(target) == "SECRET_KEY_BASE=\"elsewhere\"\n"
      after
        File.rm_rf(support_root)
        File.rm_rf(target_root)
      end
    end

    test "group-writable controller.env refuses before TLS unchanged" do
      support_root = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        env_path = write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        File.chmod!(env_path, 0o660)

        assert_refused_unchanged(support_root, runtime, "controller.env is group/world writable")
        assert TransportFixture.mode(env_path) == 0o660
      after
        File.rm_rf(support_root)
      end
    end

    test "world-writable TLS directory refuses before TLS unchanged" do
      support_root = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        tls_dir = Path.join([support_root, "config", "tls"])
        File.mkdir!(tls_dir)
        File.chmod!(tls_dir, 0o777)

        assert_refused_unchanged(support_root, runtime, "TLS directory is group/world writable")
        assert TransportFixture.mode(tls_dir) == 0o777
        assert File.ls!(tls_dir) == []
      after
        File.rm_rf(support_root)
      end
    end

    test "symlinked TLS source refuses before TLS and is never published" do
      support_root = tmp_support_root()
      target_root = tmp_support_root()
      target = Path.join(target_root, "foreign.crt")
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        write_generated_ca(support_root)
        source = Path.join([support_root, "config", "tls", "ca.crt"])
        File.write!(target, "foreign certificate")
        File.rm!(source)
        File.ln_s!(target, source)

        assert_refused_unchanged(support_root, runtime, "TLS source file is a symlink")
        assert File.read!(target) == "foreign certificate"
      after
        File.rm_rf(support_root)
        File.rm_rf(target_root)
      end
    end

    defp write_partial_ca(support_root) do
      tls_dir = Path.join([support_root, "config", "tls"])
      File.mkdir!(tls_dir)
      File.chmod!(tls_dir, 0o700)
      File.write!(Path.join(tls_dir, "ca.crt"), "public ca cert")
      ca_key = Path.join(tls_dir, "ca.key")
      File.write!(ca_key, "private ca key")
      File.chmod!(ca_key, 0o600)
      ca_key
    end

    test "symlinked ca.key in a partially generated TLS directory refuses before TLS" do
      support_root = tmp_support_root()
      target_root = tmp_support_root()
      target = Path.join(target_root, "foreign.key")
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        ca_key = write_partial_ca(support_root)
        File.write!(target, "foreign key")
        File.rm!(ca_key)
        File.ln_s!(target, ca_key)

        assert_refused_unchanged(
          support_root,
          runtime,
          ~r"TLS source file is a symlink.*: ca.key"
        )

        assert File.read!(target) == "foreign key"
        assert {:ok, ^target} = File.read_link(ca_key)
      after
        File.rm_rf(support_root)
        File.rm_rf(target_root)
      end
    end

    test "group-writable ca.key in a partially generated TLS directory refuses before TLS" do
      support_root = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        ca_key = write_partial_ca(support_root)
        File.chmod!(ca_key, 0o660)

        assert_refused_unchanged(
          support_root,
          runtime,
          "TLS source file is group/world writable: ca.key"
        )

        assert TransportFixture.mode(ca_key) == 0o660
        assert File.read!(ca_key) == "private ca key"
      after
        File.rm_rf(support_root)
      end
    end

    test "a safe partially generated TLS directory proceeds to TLS initialization" do
      support_root = tmp_support_root()
      runtime = enabled_runtime(support_root, %{})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")
        write_partial_ca(support_root)

        assert {:ok, _message} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert_received :tls_called
        assert_public_profile(support_root)
      after
        File.rm_rf(support_root)
      end
    end

    test "missing publication helper refuses before TLS" do
      support_root = tmp_support_root()
      missing = Path.join(support_root, "orchard-transport-publish")

      runtime = enabled_runtime(support_root, %{publication_opts: [executable: missing]})

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert message =~ "transport publication helper is unavailable"
        refute_received :tls_called
        refute File.exists?(Path.join(support_root, "public"))
      after
        File.rm_rf(support_root)
      end
    end

    test "TLS failure after prepare removes the private stage" do
      support_root = tmp_support_root()

      runtime =
        enabled_runtime(support_root, %{
          tls_init: fn _host, _root, _stage_dir -> {:error, "tls failed"} end
        })

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert message =~ "tls failed"
        assert TransportFixture.stage_entries(support_root) == []
        refute File.exists?(Path.join(support_root, "public"))
      after
        File.rm_rf(support_root)
      end
    end

    test "helper publication failure reports the helper error and leaves env unchanged" do
      support_root = tmp_support_root()

      runtime =
        enabled_runtime(support_root, %{
          publication_opts: [
            executable: TransportFixture.helper(:test),
            env: [{"ORCHARD_TRANSPORT_PUBLISH_TEST_FAULT", "rename_error:public"}]
          ]
        })

      try do
        original = "SECRET_KEY_BASE=\"secret\"\n"
        write_controller_env(support_root, original)

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        assert message =~ "public artifact publication: rename failed (eio)"
        assert File.read!(Path.join([support_root, "config", "controller.env"])) == original
        assert TransportFixture.stage_entries(support_root) == []
        refute File.exists?(Path.join(support_root, "public"))
      after
        File.rm_rf(support_root)
      end
    end

    test "COMMIT failure after publication and env upsert reports both completed and skips restart" do
      support_root = tmp_support_root()
      pid_file = Path.join(support_root, "helper.pid")
      parent = self()

      runtime =
        enabled_runtime(support_root, %{
          publication_opts: [
            executable: TransportFixture.helper(:production),
            wrapper: ["/bin/sh", "-c", ~s(echo $$ > "#{pid_file}" && exec "$0" "$@")]
          ],
          shell_env_upsert: fn path, assignments ->
            result = ShellEnv.upsert(path, assignments)
            kill_helper!(pid_file)
            result
          end,
          cmd: fn program, args, opts ->
            send(parent, {:cmd, program, args, opts})
            {"{ pid = 123 }", 0}
          end
        })

      try do
        write_controller_env(support_root, "SECRET_KEY_BASE=\"secret\"\n")

        assert {:error, message, 1} =
                 Transport.run(["enable-local-https", "--host", "mawarduri"], runtime)

        public = Path.join(support_root, "public")
        assert message =~ "public CA and endpoint metadata were published under #{public}"
        assert message =~ "controller.env was updated"
        assert message =~ "did not confirm COMMIT"
        assert message =~ "Controller restart was NOT attempted"

        assert File.read!(Path.join([support_root, "config", "controller.env"])) =~
                 "ORCHARD_PUBLIC_HOST"

        assert_public_profile(support_root)
        assert collect_cmds() == []
      after
        File.rm_rf(support_root)
      end
    end

    defp kill_helper!(pid_file) do
      pid = pid_file |> File.read!() |> String.trim()
      {_output, 0} = System.cmd("kill", ["-KILL", pid])

      Enum.find(1..500, fn _attempt ->
        Process.sleep(10)
        elem(System.cmd("kill", ["-0", pid], stderr_to_stdout: true), 1) != 0
      end) || flunk("transport publication helper #{pid} did not exit")
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
