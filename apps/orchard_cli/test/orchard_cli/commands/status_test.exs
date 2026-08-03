defmodule OrchardCLI.Commands.StatusTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.Commands.Status

  setup do
    original_support_root = System.get_env("ORCHARD_SUPPORT_ROOT")

    support_root =
      Path.join(System.tmp_dir!(), "orchard status support #{System.unique_integer([:positive])}")

    tls_dir = Path.join([support_root, "config", "tls"])
    certfile = Path.join(tls_dir, "controller.crt")
    keyfile = Path.join(tls_dir, "controller.key")

    generate_self_signed_cert!(certfile, keyfile)
    System.put_env("ORCHARD_SUPPORT_ROOT", support_root)

    on_exit(fn ->
      restore_env("ORCHARD_SUPPORT_ROOT", original_support_root)
      File.rm_rf(support_root)
    end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp test_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "all"} end,
        endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      },
      overrides
    )
  end

  defp generate_self_signed_cert!(certfile, keyfile) do
    openssl = System.find_executable("openssl") || flunk("openssl is required for status tests")
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

  defp ready_response do
    %{
      status: 200,
      body: %{"status" => "ok"}
    }
  end

  defp degraded_response(_reason \\ "postgres_reachable") do
    %{
      status: 503,
      body: %{"status" => "error"}
    }
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp without_transport_env(fun) do
    keys = [
      "ORCHARD_TRANSPORT_MODE",
      "ORCHARD_TLS_DISABLED",
      "ORCHARD_TLS_CERTFILE",
      "ORCHARD_TLS_KEYFILE",
      "ORCHARD_TLS_CACERTFILE",
      "ORCHARD_PUBLIC_HOST",
      "ORCHARD_PUBLIC_PORT",
      "ORCHARD_API_HTTPS_PORT",
      "ORCHARD_API_BIND_IP",
      "PHX_HOST",
      "PORT"
    ]

    originals = Map.new(keys, &{&1, System.get_env(&1)})
    Enum.each(keys, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(originals, fn {key, value} -> restore_env(key, value) end)
    end
  end

  # ── Usage / Help ─────────────────────────────────────────────────────

  test "help returns usage" do
    assert {:ok, message} = Status.run(["help"], test_runtime())
    assert message =~ "orchardctl status"
    assert message =~ "health endpoint"
    assert message =~ "Local Orchard version and install role"
    assert message =~ "Controller reachability and readiness state"
    refute message =~ "Runtime summary"
  end

  test "--help returns usage" do
    assert {:ok, message} = Status.run(["--help"], test_runtime())
    assert message =~ "orchardctl status"
  end

  test "extra args returns error with usage" do
    assert {:error, message, 1} = Status.run(["extra"], test_runtime())
    assert message =~ "orchardctl status"
  end

  test "multiple extra args returns error with usage" do
    assert {:error, message, 1} = Status.run(["a", "b"], test_runtime())
    assert message =~ "orchardctl status"
  end

  # ── Ready Banner ─────────────────────────────────────────────────────

  test "controller role shows role line and controller status" do
    runtime =
      test_runtime(%{
        read_install_role: fn -> {:ok, "controller"} end,
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Role:    controller"
    assert banner =~ "Status:  ready"
    assert banner =~ "Console: http://localhost:4000/console"
  end

  test "source-dev fallback probes controller when marker and plists are missing" do
    runtime =
      test_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn _path -> false end,
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Role:    source-dev"
    assert banner =~ "Status:  ready"
    assert banner =~ "Console: http://localhost:4000/console"
  end

  test "source-dev fallback shows offline when controller is unreachable" do
    runtime =
      test_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn _path -> false end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Role:    source-dev"
    assert banner =~ "Status:  offline (controller unreachable)"
  end

  test "invalid marker returns install error and does not probe controller" do
    parent = self()

    runtime =
      test_runtime(%{
        read_install_role: fn -> {:ok, "bogus"} end,
        request: fn _url, _opts ->
          send(parent, :controller_polled)
          {:ok, ready_response()}
        end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid Orchard install role marker"
    refute_received :controller_polled
  end

  test "node-agent role reports local launchd state and skips local controller checks" do
    parent = self()

    runtime =
      test_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        cmd: fn prog, args, _opts ->
          send(parent, {:cmd, prog, args})

          case {prog, args} do
            {"launchctl", ["print", "system/com.orchard.node-agent"]} ->
              {"{\n\t\"pid\" : 123;\n}\n", 0}

            _other ->
              {"Could not find service\n", 113}
          end
        end,
        request: fn _url, _opts ->
          send(parent, :controller_polled)
          {:error, :unexpected_poll}
        end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Role:    node-agent"
    assert banner =~ "Node Agent: loaded"
    assert banner =~ "Node Agent Health: not checked"
    assert banner =~ "Controller: remote/not checked"
    refute_received :controller_polled

    cmds = collect_cmds()

    assert Enum.any?(cmds, fn {_prog, args} ->
             args == ["print", "system/com.orchard.node-agent"]
           end)
  end

  test "node-agent role surfaces injected local health" do
    runtime =
      test_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        cmd: fn _prog, _args, _opts -> {"Could not find service\n", 113} end,
        node_agent_health: fn -> {:ok, %{ready: false, health_code: "starting"}} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Role:    node-agent"
    assert banner =~ "Node Agent: not loaded"
    assert banner =~ "Node Agent Health: not ready — starting"
    assert banner =~ "Controller: remote/not checked"
  end

  test "ready banner uses the local version with the status-only public response" do
    runtime =
      test_runtime(%{
        version: fn -> "1.2.3" end,
        request: fn _url, _opts -> {:ok, %{status: 200, body: %{"status" => "ok"}}} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Orchard v1.2.3"
    assert banner =~ "Console: http://localhost:4000/console\n"
    assert banner =~ "Status:  ready"
    refute banner =~ "Console: http://localhost:4000/console (unknown)"
    refute banner =~ "License:"
    refute banner =~ "Transport:"
  end

  test "degraded status-only response points to authenticated operator diagnostics" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, degraded_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Status:  degraded"
    assert banner =~ "Details: use authenticated GET /ops/v1/health for diagnostics"
  end

  test "status-only probing never presents disclosed version or build as remote identity" do
    runtime =
      test_runtime(%{
        version: fn -> "1.2.3" end,
        request: fn _url, _opts ->
          {:ok,
           %{
             status: 200,
             body: %{"status" => "ok", "version" => "9.9.9", "build_ref" => "remote-sha"}
           }}
        end
      })

    # Extra public fields are rejected rather than rendered as remote identity.
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
    refute message =~ "9.9.9"
    refute message =~ "remote-sha"
  end

  # ── Degraded Banner ──────────────────────────────────────────────────

  # ── Runtime Unavailable ──────────────────────────────────────────────

  # ── Offline ──────────────────────────────────────────────────────────

  test "unreachable controller shows offline banner" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:error, :econnrefused} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "\u{1F333} Orchard v0.1.0"
    assert banner =~ "Console: http://localhost:4000/console"
    assert banner =~ "API:     http://localhost:4000/v1"
    assert banner =~ "Status:  offline (controller unreachable)"
  end

  test "offline returns ok tuple (not error)" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:error, :timeout} end
      })

    assert {:ok, _banner} = Status.run([], runtime)
  end

  # ── Candidate Fallback ───────────────────────────────────────────────

  test "first candidate fails, second succeeds" do
    call_count = :counters.new(1, [:atomics])

    runtime =
      test_runtime(%{
        endpoint_candidates: fn ->
          [
            %{base_url: "https://localhost:8443", ca_certfile: nil},
            %{base_url: "http://localhost:4000", ca_certfile: nil}
          ]
        end,
        request: fn url, _opts ->
          :counters.add(call_count, 1, 1)

          if String.starts_with?(url, "https://") do
            {:error, :econnrefused}
          else
            {:ok, ready_response()}
          end
        end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Console: http://localhost:4000/console"
    assert banner =~ "ready"
    assert :counters.get(call_count, 1) == 2
  end

  test "all candidates fail shows offline with first candidate URL" do
    runtime =
      test_runtime(%{
        endpoint_candidates: fn ->
          [
            %{base_url: "https://localhost:8443", ca_certfile: nil},
            %{base_url: "http://localhost:4000", ca_certfile: nil}
          ]
        end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Console: https://localhost:8443/console"
    assert banner =~ "offline"
  end

  test "request function receives correct URL with health path" do
    received_url = :erlang.make_ref()
    ref = received_url

    runtime =
      test_runtime(%{
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      })

    Status.run([], runtime)
    assert_received {^ref, url}
    assert url == "http://localhost:4000/health/ready"
  end

  test "candidate probes probe_url and renders display_url" do
    ref = make_ref()

    runtime =
      test_runtime(%{
        endpoint_candidates: fn ->
          [
            %{
              probe_url: "http://127.0.0.1:4101",
              display_url: "https://orchard.example.internal",
              ca_certfile: nil
            }
          ]
        end,
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert_received {^ref, "http://127.0.0.1:4101/health/ready"}
    assert banner =~ "Console: https://orchard.example.internal/console"
    refute banner =~ "127.0.0.1:4101/console"
  end

  test "packaged fallback uses direct HTTPS when ORCHARD_TRANSPORT_MODE selects it" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_port = System.get_env("ORCHARD_API_HTTPS_PORT")
    original_public_host = System.get_env("ORCHARD_PUBLIC_HOST")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_API_HTTPS_PORT", original_port)
      restore_env("ORCHARD_PUBLIC_HOST", original_public_host)
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_API_HTTPS_PORT", "9443")
    System.put_env("ORCHARD_PUBLIC_HOST", "orchard.example.internal")

    ref = make_ref()

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn url, _opts ->
        send(self(), {ref, url})
        {:ok, ready_response()}
      end
    }

    assert {:ok, banner} = Status.run([], runtime)
    assert_received {^ref, "https://orchard.example.internal:9443/health/ready"}
    assert banner =~ "Console: https://orchard.example.internal:9443/console"
  end

  test "direct HTTPS packaged fallback passes configured external CA to request" do
    ca_path =
      Path.join(System.tmp_dir!(), "orchard-status-ca-#{System.unique_integer([:positive])}.crt")

    generate_self_signed_cert!(ca_path, ca_path <> ".key")

    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(ca_path)
      File.rm(ca_path <> ".key")
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CACERTFILE", ca_path)

    ref = make_ref()

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, opts ->
        send(self(), {ref, opts})
        {:ok, ready_response()}
      end
    }

    assert {:ok, _banner} = Status.run([], runtime)
    assert_received {^ref, opts}
    assert Keyword.get(opts, :ca_certfile) == ca_path
  end

  test "packaged fallback uses HTTPS for legacy shims when transport mode is unset" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_disabled = System.get_env("ORCHARD_TLS_DISABLED")
    original_cert = System.get_env("ORCHARD_TLS_CERTFILE")
    original_key = System.get_env("ORCHARD_TLS_KEYFILE")
    original_port = System.get_env("ORCHARD_API_HTTPS_PORT")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_DISABLED", original_disabled)
      restore_env("ORCHARD_TLS_CERTFILE", original_cert)
      restore_env("ORCHARD_TLS_KEYFILE", original_key)
      restore_env("ORCHARD_API_HTTPS_PORT", original_port)
    end)

    operator_cert =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-operator-#{System.unique_integer([:positive])}.crt"
      )

    operator_key = operator_cert <> ".key"
    generate_self_signed_cert!(operator_cert, operator_key)

    on_exit(fn ->
      File.rm(operator_cert)
      File.rm(operator_key)
    end)

    for env <- [
          %{"ORCHARD_TLS_DISABLED" => "false"},
          %{
            "ORCHARD_TLS_CERTFILE" => operator_cert,
            "ORCHARD_TLS_KEYFILE" => operator_key
          }
        ] do
      System.delete_env("ORCHARD_TRANSPORT_MODE")
      System.delete_env("ORCHARD_TLS_DISABLED")
      System.delete_env("ORCHARD_TLS_CERTFILE")
      System.delete_env("ORCHARD_TLS_KEYFILE")
      System.put_env("ORCHARD_API_HTTPS_PORT", "9444")
      Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "https://localhost:9444/health/ready"}
      assert banner =~ "Console: https://localhost:9444/console"
    end
  end

  test "packaged fallback uses reverse proxy bind IP as probe host" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_bind_ip = System.get_env("ORCHARD_API_BIND_IP")
    original_trusted_proxies = System.get_env("ORCHARD_TRUSTED_PROXIES")
    original_port = System.get_env("PORT")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_API_BIND_IP", original_bind_ip)
      restore_env("ORCHARD_TRUSTED_PROXIES", original_trusted_proxies)
      restore_env("PORT", original_port)
    end)

    for {bind_ip, expected_host} <- [
          {"::1", "[::1]"},
          {"::", "[::1]"},
          {"0.0.0.0", "127.0.0.1"},
          {"10.0.0.5", "10.0.0.5"}
        ] do
      System.put_env("ORCHARD_TRANSPORT_MODE", "reverse_proxy")
      System.put_env("ORCHARD_API_BIND_IP", bind_ip)
      System.put_env("PORT", "4102")
      System.put_env("ORCHARD_TRUSTED_PROXIES", "10.0.0.0/24")

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        request: fn url, _opts ->
          send(self(), {ref, bind_ip, url})
          {:ok, ready_response()}
        end
      }

      expected_url = "http://#{expected_host}:4102/health/ready"
      assert {:ok, _banner} = Status.run([], runtime)
      assert_received {^ref, ^bind_ip, ^expected_url}
    end
  end

  test "packaged fallback rejects reverse proxy bind and trusted proxy config that runtime rejects" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_bind_ip = System.get_env("ORCHARD_API_BIND_IP")
    original_trusted_proxies = System.get_env("ORCHARD_TRUSTED_PROXIES")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_API_BIND_IP", original_bind_ip)
      restore_env("ORCHARD_TRUSTED_PROXIES", original_trusted_proxies)
    end)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("invalid reverse proxy config should not probe") end
    }

    System.put_env("ORCHARD_TRANSPORT_MODE", "reverse_proxy")
    System.put_env("ORCHARD_API_BIND_IP", "")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_API_BIND_IP must not be empty"

    System.put_env("ORCHARD_API_BIND_IP", "not-an-ip")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_API_BIND_IP: not-an-ip"

    System.put_env("ORCHARD_API_BIND_IP", "10.0.0.5")
    System.delete_env("ORCHARD_TRUSTED_PROXIES")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_TRUSTED_PROXIES must be set"

    System.put_env("ORCHARD_TRUSTED_PROXIES", ", ,")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_TRUSTED_PROXIES must contain at least one CIDR"

    System.put_env("ORCHARD_TRUSTED_PROXIES", "10.0.0.0/not-a-prefix")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_TRUSTED_PROXIES contains invalid CIDR"
  end

  test "packaged fallback brackets IPv6 public display host" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_host = System.get_env("ORCHARD_PUBLIC_HOST")
    original_port = System.get_env("ORCHARD_API_HTTPS_PORT")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_PUBLIC_HOST", original_host)
      restore_env("ORCHARD_API_HTTPS_PORT", original_port)
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_PUBLIC_HOST", "::1")
    System.put_env("ORCHARD_API_HTTPS_PORT", "9443")

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> {:ok, ready_response()} end
    }

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Console: https://[::1]:9443/console"
  end

  test "packaged fallback rejects direct HTTPS bind IP that runtime rejects" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_bind_ip = System.get_env("ORCHARD_API_BIND_IP")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_API_BIND_IP", original_bind_ip)
    end)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("invalid direct HTTPS bind IP should not probe") end
    }

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_API_BIND_IP", "")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_API_BIND_IP must not be empty"

    System.put_env("ORCHARD_API_BIND_IP", "not-an-ip")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_API_BIND_IP: not-an-ip"
  end

  test "packaged fallback does not auto-use generated-local CA with explicit operator certs" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_cert = System.get_env("ORCHARD_TLS_CERTFILE")
    original_key = System.get_env("ORCHARD_TLS_KEYFILE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT")
    tls_dir = Path.join([support_root, "config", "tls"])
    default_ca = Path.join(tls_dir, "ca.crt")

    operator_cert =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-operator-no-ca-#{System.unique_integer([:positive])}.crt"
      )

    operator_key = operator_cert <> ".key"

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CERTFILE", original_cert)
      restore_env("ORCHARD_TLS_KEYFILE", original_key)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(operator_cert)
      File.rm(operator_key)
      File.rm(Path.join(tls_dir, ".orchard-tls-meta.json"))
      File.rm(default_ca)
    end)

    File.cp!(Path.join(tls_dir, "controller.crt"), default_ca)

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"})
    )

    generate_self_signed_cert!(operator_cert, operator_key)
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CERTFILE", operator_cert)
    System.put_env("ORCHARD_TLS_KEYFILE", operator_key)
    System.delete_env("ORCHARD_TLS_CACERTFILE")

    ref = make_ref()

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, opts ->
        send(self(), {ref, opts})
        {:ok, ready_response()}
      end
    }

    assert {:ok, _banner} = Status.run([], runtime)
    assert_received {^ref, opts}
    assert Keyword.get(opts, :ca_certfile) == nil
  end

  test "packaged fallback allows explicit default cert paths with external CA despite generated-local metadata" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_cert = System.get_env("ORCHARD_TLS_CERTFILE")
    original_key = System.get_env("ORCHARD_TLS_KEYFILE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT")
    tls_dir = Path.join([support_root, "config", "tls"])
    default_cert = Path.join(tls_dir, "controller.crt")
    default_key = Path.join(tls_dir, "controller.key")

    operator_ca =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-explicit-default-ca-#{System.unique_integer([:positive])}.crt"
      )

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CERTFILE", original_cert)
      restore_env("ORCHARD_TLS_KEYFILE", original_key)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(operator_ca)
      File.rm(operator_ca <> ".key")
      File.rm(Path.join(tls_dir, ".orchard-tls-meta.json"))
    end)

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"})
    )

    generate_self_signed_cert!(operator_ca, operator_ca <> ".key")
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CERTFILE", default_cert)
    System.put_env("ORCHARD_TLS_KEYFILE", default_key)
    System.put_env("ORCHARD_TLS_CACERTFILE", operator_ca)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> {:ok, ready_response()} end
    }

    assert {:ok, _banner} = Status.run([], runtime)
  end

  test "packaged fallback allows explicit cert CA override despite generated-local metadata" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_cert = System.get_env("ORCHARD_TLS_CERTFILE")
    original_key = System.get_env("ORCHARD_TLS_KEYFILE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT")
    tls_dir = Path.join([support_root, "config", "tls"])

    operator_cert =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-explicit-#{System.unique_integer([:positive])}.crt"
      )

    operator_key = operator_cert <> ".key"
    operator_ca = operator_cert <> ".ca"

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CERTFILE", original_cert)
      restore_env("ORCHARD_TLS_KEYFILE", original_key)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(operator_cert)
      File.rm(operator_key)
      File.rm(operator_ca)
      File.rm(Path.join(tls_dir, ".orchard-tls-meta.json"))
    end)

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"})
    )

    generate_self_signed_cert!(operator_cert, operator_key)
    File.cp!(operator_cert, operator_ca)
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CERTFILE", operator_cert)
    System.put_env("ORCHARD_TLS_KEYFILE", operator_key)
    System.put_env("ORCHARD_TLS_CACERTFILE", operator_ca)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> {:ok, ready_response()} end
    }

    assert {:ok, _banner} = Status.run([], runtime)
  end

  test "packaged fallback rejects missing generated-local default CA in direct_https" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT")
    tls_dir = Path.join([support_root, "config", "tls"])
    default_ca = Path.join(tls_dir, "ca.crt")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      File.rm(Path.join(tls_dir, ".orchard-tls-meta.json"))
      File.rm(default_ca)
    end)

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"})
    )

    File.rm(default_ca)
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("missing generated-local CA should not probe") end
    }

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "CA certificate not found"
  end

  test "packaged fallback rejects generated-local CA override in direct_https" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT")
    tls_dir = Path.join([support_root, "config", "tls"])
    default_ca = Path.join(tls_dir, "ca.crt")

    override_ca =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-operator-ca-#{System.unique_integer([:positive])}.crt"
      )

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(override_ca)
      File.rm(override_ca <> ".key")
      File.rm(Path.join(tls_dir, ".orchard-tls-meta.json"))
      File.rm(default_ca)
    end)

    File.cp!(Path.join(tls_dir, "controller.crt"), default_ca)

    File.write!(
      Path.join(tls_dir, ".orchard-tls-meta.json"),
      Jason.encode!(%{"source" => "generated_local_ca"})
    )

    generate_self_signed_cert!(override_ca, override_ca <> ".key")
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CACERTFILE", override_ca)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("generated-local CA override should not probe") end
    }

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_TLS_CACERTFILE cannot override generated-local CA publication"
  end

  test "packaged fallback rejects malformed explicit CA in direct_https" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")

    ca_path =
      Path.join(
        System.tmp_dir!(),
        "orchard-status-malformed-ca-#{System.unique_integer([:positive])}.crt"
      )

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      File.rm(ca_path)
    end)

    File.write!(ca_path, "not a certificate\n")
    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CACERTFILE", ca_path)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("malformed explicit CA should not probe") end
    }

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "TLS CA certificate file is malformed"
  end

  test "packaged fallback rejects missing explicit CA in direct_https" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.put_env("ORCHARD_TLS_CACERTFILE", "/tmp/orchard-missing-ca.crt")

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("missing explicit CA should not probe") end
    }

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "CA certificate not found: /tmp/orchard-missing-ca.crt"
  end

  test "packaged fallback probes loopback and displays proxy URL for reverse_proxy" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_port = System.get_env("PORT")
    original_public_host = System.get_env("ORCHARD_PUBLIC_HOST")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("PORT", original_port)
      restore_env("ORCHARD_PUBLIC_HOST", original_public_host)
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "reverse_proxy")
    System.put_env("PORT", "4101")
    System.put_env("ORCHARD_PUBLIC_HOST", "orchard.example.internal")

    ref = make_ref()

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn url, _opts ->
        send(self(), {ref, url})
        {:ok, ready_response()}
      end
    }

    assert {:ok, banner} = Status.run([], runtime)
    assert_received {^ref, "http://127.0.0.1:4101/health/ready"}
    assert banner =~ "Console: https://orchard.example.internal/console"
  end

  test "packaged fallback uses PORT for plain local HTTP transport" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_port = System.get_env("PORT")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("PORT", original_port)
    end)

    for mode <- ["plain_http_localhost"] do
      System.put_env("ORCHARD_TRANSPORT_MODE", mode)
      System.put_env("PORT", "4100")

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        request: fn url, _opts ->
          send(self(), {ref, mode, url})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, ^mode, "http://localhost:4100/health/ready"}
      assert banner =~ "Console: http://localhost:4100/console"
    end
  end

  test "packaged fallback rejects malformed legacy transport envs" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_disabled = System.get_env("ORCHARD_TLS_DISABLED")
    original_cert = System.get_env("ORCHARD_TLS_CERTFILE")
    original_key = System.get_env("ORCHARD_TLS_KEYFILE")
    original_ca = System.get_env("ORCHARD_TLS_CACERTFILE")
    original_public_port = System.get_env("ORCHARD_PUBLIC_PORT")
    original_port = System.get_env("PORT")
    original_https_port = System.get_env("ORCHARD_API_HTTPS_PORT")
    original_bind_ip = System.get_env("ORCHARD_API_BIND_IP")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_TLS_DISABLED", original_disabled)
      restore_env("ORCHARD_TLS_CERTFILE", original_cert)
      restore_env("ORCHARD_TLS_KEYFILE", original_key)
      restore_env("ORCHARD_TLS_CACERTFILE", original_ca)
      restore_env("ORCHARD_PUBLIC_PORT", original_public_port)
      restore_env("PORT", original_port)
      restore_env("ORCHARD_API_HTTPS_PORT", original_https_port)
      restore_env("ORCHARD_API_BIND_IP", original_bind_ip)
    end)

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("invalid legacy transport env should not probe") end
    }

    System.put_env("ORCHARD_TRANSPORT_MODE", "plain_http_localhost")
    System.put_env("ORCHARD_TLS_DISABLED", "maybe")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_TLS_DISABLED: maybe"

    System.put_env("ORCHARD_TRANSPORT_MODE", "direct_https")
    System.delete_env("ORCHARD_TLS_DISABLED")
    System.put_env("ORCHARD_TLS_CERTFILE", "/tmp/controller.crt")
    System.delete_env("ORCHARD_TLS_KEYFILE")
    assert {:error, message, 1} = Status.run([], runtime)

    assert message =~
             "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must both be set or both unset"

    System.put_env("ORCHARD_TLS_KEYFILE", "/tmp/controller.key")

    for empty_ca <- ["", "   "] do
      System.put_env("ORCHARD_TLS_CACERTFILE", empty_ca)
      assert {:error, message, 1} = Status.run([], runtime)
      assert message =~ "ORCHARD_TLS_CACERTFILE must not be empty"
    end

    System.delete_env("ORCHARD_TLS_CERTFILE")
    System.delete_env("ORCHARD_TLS_KEYFILE")
    System.put_env("ORCHARD_TLS_CACERTFILE", "unknown")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "CA certificate not found: unknown"

    System.delete_env("ORCHARD_TLS_CACERTFILE")

    System.delete_env("ORCHARD_TLS_CERTFILE")
    System.delete_env("ORCHARD_TLS_KEYFILE")

    for mode <- ["direct_https", "plain_http_localhost"] do
      System.put_env("ORCHARD_TRANSPORT_MODE", mode)
      System.put_env("ORCHARD_PUBLIC_PORT", "")

      assert {:ok, _banner} =
               Status.run([], %{runtime | request: fn _url, _opts -> {:ok, ready_response()} end})
    end

    System.put_env("ORCHARD_TRANSPORT_MODE", "reverse_proxy")
    System.put_env("ORCHARD_PUBLIC_PORT", "")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "ORCHARD_PUBLIC_PORT must not be empty"

    System.put_env("ORCHARD_PUBLIC_PORT", "abc")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_PUBLIC_PORT: abc"

    System.put_env("ORCHARD_TRANSPORT_MODE", "https")
    System.put_env("PORT", "abc")
    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_TRANSPORT_MODE: https"

    for {mode, env_name, value, expected} <- [
          {"plain_http_localhost", "PORT", "abc", "invalid PORT: abc"},
          {"reverse_proxy", "PORT", "0", "invalid PORT: 0"},
          {"direct_https", "ORCHARD_API_HTTPS_PORT", "65536",
           "invalid ORCHARD_API_HTTPS_PORT: 65536"}
        ] do
      System.put_env("ORCHARD_TRANSPORT_MODE", mode)
      System.delete_env("PORT")
      System.delete_env("ORCHARD_PUBLIC_PORT")
      System.delete_env("ORCHARD_API_HTTPS_PORT")
      System.put_env(env_name, value)

      assert {:error, message, 1} = Status.run([], runtime)
      assert message =~ expected
    end
  end

  test "packaged fallback rejects invalid ORCHARD_TRANSPORT_MODE" do
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")

    on_exit(fn -> restore_env("ORCHARD_TRANSPORT_MODE", original_mode) end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "https")

    runtime = %{
      version: fn -> "0.1.0" end,
      read_install_role: fn -> {:ok, "controller"} end,
      request: fn _url, _opts -> flunk("invalid transport mode should not probe") end
    }

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid ORCHARD_TRANSPORT_MODE: https"
  end

  test "application default endpoint config does not mask valid endpoint sidecar" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "direct_https",
          "public_host" => "orchard.example.internal",
          "api_https_port" => 9443,
          "plain_http_port" => nil,
          "api_bind_ip" => nil,
          "ca_certfile" => nil,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "transport"
        })
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "https://orchard.example.internal:9443/health/ready"}
      assert banner =~ "Console: https://orchard.example.internal:9443/console"
    end)
  end

  test "status uses non-default application endpoint config when endpoint sidecar is absent" do
    without_transport_env(fn ->
      original = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

      on_exit(fn ->
        Application.put_env(:orchard_controller, Orchard.API.Endpoint, original)
      end)

      Application.put_env(:orchard_controller, Orchard.API.Endpoint,
        url: [host: "127.0.0.1"],
        http: [port: 4101]
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path:
          Path.join(System.fetch_env!("ORCHARD_SUPPORT_ROOT"), "public/missing-endpoint.json"),
        request: fn url, opts ->
          send(self(), {ref, url, opts})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "http://localhost:4101/health/ready", opts}
      assert Keyword.get(opts, :ca_certfile) == nil
      assert banner =~ "Console: http://127.0.0.1:4101/console"
    end)
  end

  test "status prefers endpoint config over valid endpoint sidecar when config is available" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      ca_path = Path.join([support_root, "public", "ca.crt"])
      File.mkdir_p!(Path.dirname(sidecar_path))
      File.write!(ca_path, "public ca placeholder\n")

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "direct_https",
          "public_host" => "orchard.example.internal",
          "api_https_port" => 9443,
          "plain_http_port" => nil,
          "api_bind_ip" => "10.99.0.12",
          "ca_certfile" => ca_path,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "postinstall"
        })
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> [url: [host: "localhost"], http: [port: 4100]] end,
        request: fn url, opts ->
          send(self(), {ref, url, opts})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "http://localhost:4100/health/ready", opts}
      assert Keyword.get(opts, :ca_certfile) == nil
      assert banner =~ "Console: http://localhost:4100/console"
      refute banner =~ "orchard.example.internal"
      refute banner =~ "10.99.0.12"
    end)
  end

  test "status uses reverse-proxy endpoint sidecar from public host and public HTTPS port" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "reverse_proxy",
          "public_host" => "orchard-proxy.example.internal",
          "api_https_port" => 443,
          "plain_http_port" => 4000,
          "api_bind_ip" => "127.0.0.1",
          "ca_certfile" => nil,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "postinstall"
        })
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> [] end,
        request: fn url, opts ->
          send(self(), {ref, url, opts})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "https://orchard-proxy.example.internal/health/ready", opts}
      assert Keyword.get(opts, :ca_certfile) == nil
      assert banner =~ "Console: https://orchard-proxy.example.internal/console"
      refute banner =~ "127.0.0.1"
    end)
  end

  test "direct HTTPS endpoint sidecar is used when endpoint config is unavailable" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      ca_path = Path.join([support_root, "public", "ca.crt"])
      File.mkdir_p!(Path.dirname(sidecar_path))
      File.write!(ca_path, "public ca placeholder\n")

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "direct_https",
          "public_host" => "orchard.example.internal",
          "api_https_port" => 9443,
          "plain_http_port" => nil,
          "api_bind_ip" => "10.99.0.12",
          "ca_certfile" => ca_path,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "transport"
        })
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> [] end,
        request: fn url, opts ->
          send(self(), {ref, url, opts})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "https://orchard.example.internal:9443/health/ready", opts}
      assert Keyword.get(opts, :ca_certfile) == ca_path
      assert banner =~ "Console: https://orchard.example.internal:9443/console"
      refute banner =~ "10.99.0.12"
    end)
  end

  test "unreadable endpoint config falls through to direct HTTPS sidecar with guidance" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "direct_https",
          "public_host" => "orchard.example.internal",
          "api_https_port" => 9443,
          "plain_http_port" => nil,
          "api_bind_ip" => nil,
          "ca_certfile" => nil,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "postinstall"
        })
      )

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> {:error, :eacces} end,
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "https://orchard.example.internal:9443/health/ready"}
      assert banner =~ "Warning: ignored endpoint config"
      assert banner =~ "Run: sudo orchardctl status or check endpoint.json"
      assert banner =~ "Status:  ready"
    end)
  end

  test "unreadable endpoint config and malformed sidecar render guidance before fallback" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))
      File.write!(sidecar_path, "not json")

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> {:error, :eacces} end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert banner =~ "Warning: ignored endpoint config"
      assert banner =~ "Warning: ignored endpoint metadata sidecar"
      assert banner =~ "Run: sudo orchardctl status or check endpoint.json"
      assert banner =~ "Status:  offline"
    end)
  end

  test "valid but unreachable endpoint sidecar renders targeted configured endpoint warning" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))

      File.write!(
        sidecar_path,
        Jason.encode!(%{
          "schema_version" => 1,
          "transport_mode" => "direct_https",
          "public_host" => "orchard.example.internal",
          "api_https_port" => 9443,
          "plain_http_port" => nil,
          "api_bind_ip" => "10.99.0.12",
          "ca_certfile" => nil,
          "updated_at" => "2026-05-18T01:02:03Z",
          "generated_by" => "postinstall"
        })
      )

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> [] end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert banner =~ "configured endpoint unreachable"
      assert banner =~ "https://orchard.example.internal:9443"
      refute banner =~ "10.99.0.12"
    end)
  end

  test "malformed endpoint sidecar is ignored with targeted warning and status still probes fallback" do
    without_transport_env(fn ->
      support_root = System.fetch_env!("ORCHARD_SUPPORT_ROOT")
      sidecar_path = Path.join([support_root, "public", "endpoint.json"])
      File.mkdir_p!(Path.dirname(sidecar_path))
      File.write!(sidecar_path, "not json")

      ref = make_ref()

      runtime = %{
        version: fn -> "0.1.0" end,
        read_install_role: fn -> {:ok, "controller"} end,
        endpoint_metadata_path: sidecar_path,
        endpoint_config: fn -> [] end,
        request: fn url, _opts ->
          send(self(), {ref, url})
          {:ok, ready_response()}
        end
      }

      assert {:ok, banner} = Status.run([], runtime)
      assert_received {^ref, "http://localhost:4000/health/ready"}
      assert banner =~ "Warning: ignored endpoint metadata sidecar"
      assert banner =~ "malformed JSON"
      assert banner =~ "Status:  ready"
    end)
  end

  test "offline packaged install with unloaded services prints bootstrap guidance" do
    services = [
      %{
        id: :controller,
        label: "com.orchard.controller",
        plist_path: "/Library/LaunchDaemons/com.orchard.controller.plist",
        display_name: "Controller"
      }
    ]

    runtime =
      test_runtime(%{
        services: services,
        endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
        file_regular?: fn "/Library/LaunchDaemons/com.orchard.controller.plist" -> true end,
        cmd: fn "launchctl", ["print", "system/com.orchard.controller"], _opts ->
          {"Could not find service\n", 113}
        end,
        request: fn _url, _opts -> {:error, :econnrefused} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "services are installed but not bootstrapped"
    assert banner =~ "Run: sudo orchardctl start"
    assert banner =~ "Console: http://localhost:4000/console (unknown)"
  end

  test "request function receives ca_certfile from candidate" do
    ref = make_ref()

    runtime =
      test_runtime(%{
        endpoint_candidates: fn ->
          [%{base_url: "https://localhost:8443", ca_certfile: "/path/to/ca.crt"}]
        end,
        request: fn _url, opts ->
          send(self(), {ref, opts})
          {:ok, ready_response()}
        end
      })

    Status.run([], runtime)
    assert_received {^ref, opts}
    assert Keyword.get(opts, :ca_certfile) == "/path/to/ca.crt"
  end

  # ── add_ca_cert_connect_options regression tests ───────────────────────

  test "add_ca_cert_connect_options adds nested transport_opts for Req 0.5.x" do
    opts = [connect_timeout: 5_000, receive_timeout: 10_000]

    result = Status.add_ca_cert_connect_options(opts, "/path/to/ca.crt")

    # Critical: must use :transport_opts (not :transport_options) with :cacertfile
    # Note: connect_options only contains the nested transport_opts,
    # not the top-level connect_timeout/receive_timeout
    assert Keyword.get(result, :connect_options) == [
             transport_opts: [cacertfile: "/path/to/ca.crt"]
           ]

    # Original opts preserved at top level
    assert Keyword.get(result, :connect_timeout) == 5_000
    assert Keyword.get(result, :receive_timeout) == 10_000
  end

  test "add_ca_cert_connect_options merges with existing transport_opts" do
    opts = [
      connect_timeout: 5_000,
      connect_options: [
        timeout: 3_000,
        transport_opts: [custom_opt: :value]
      ]
    ]

    result = Status.add_ca_cert_connect_options(opts, "/path/to/ca.crt")

    transport_opts =
      result
      |> Keyword.get(:connect_options, [])
      |> Keyword.get(:transport_opts, [])

    # Must merge, not replace existing transport_opts
    assert Keyword.get(transport_opts, :cacertfile) == "/path/to/ca.crt"
    assert Keyword.get(transport_opts, :custom_opt) == :value
  end

  test "add_ca_cert_connect_options returns opts unchanged when cert is nil" do
    opts = [connect_timeout: 5_000]
    result = Status.add_ca_cert_connect_options(opts, nil)
    assert result == opts
  end

  # ── Invalid / Malformed Response ──────────────────────────────────────

  # Invalid responses are treated as failed candidates while probing.
  # If a later candidate succeeds, status succeeds. If every candidate is invalid,
  # status reports the invalid health response instead of flattening it to offline.

  test "malformed JSON with single candidate returns invalid-response error" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, %{status: 200, body: "not json"}} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response from http://localhost:4000"
    assert message =~ "malformed JSON in health response"
  end

  test "unexpected status field with single candidate returns invalid-response error" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts ->
          {:ok, %{status: 200, body: %{"status" => "weird"}}}
        end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
  end

  test "missing status field with single candidate returns invalid-response error" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts ->
          {:ok, %{status: 200, body: %{"other" => "data"}}}
        end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
  end

  test "non-map body with single candidate returns invalid-response error" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts ->
          {:ok, %{status: 200, body: [1, 2, 3]}}
        end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "unexpected response format"
  end

  test "first candidate returns non-Orchard HTML, second returns valid JSON" do
    runtime =
      test_runtime(%{
        endpoint_candidates: fn ->
          [
            %{base_url: "https://localhost:8443", ca_certfile: nil},
            %{base_url: "http://localhost:4000", ca_certfile: nil}
          ]
        end,
        request: fn url, _opts ->
          if String.starts_with?(url, "https://") do
            {:ok, %{status: 200, body: "<html>Not Orchard</html>"}}
          else
            {:ok, ready_response()}
          end
        end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Console: http://localhost:4000/console"
    assert banner =~ "ready"
  end

  # ── Malformed Nested Payloads ────────────────────────────────────────

  # ── Runtime Health Surface ───────────────────────────────────────────

  test "healthy runtime health is not shown in banner" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    refute banner =~ "health:"
  end

  test "does not render a license line when the health payload omits the license block" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    refute banner =~ "License:"
  end

  test "rejects a rich public health payload with a license block" do
    response = ready_response()
    response = put_in(response, [:body, "license"], %{"status" => "valid"})

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
    refute message =~ "License:"
  end

  defp collect_cmds do
    collect_cmds([])
  end

  defp collect_cmds(acc) do
    receive do
      {:cmd, prog, args} -> collect_cmds([{prog, args} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  test "status-only public health contract rejects extra fields" do
    response = %{status: 200, body: %{"status" => "ok", "version" => "v-secret"}}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
    refute message =~ "v-secret"
  end

  test "status-only public health contract rejects HTTP/body mismatch" do
    response = %{status: 503, body: %{"status" => "ok"}}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
  end

  test "status-only public health contract rejects inverse HTTP/body mismatch" do
    response = %{status: 200, body: %{"status" => "error"}}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
  end

  test "status-only public health contract rejects otherwise exact bodies for other statuses" do
    response = %{status: 404, body: %{"status" => "ok"}}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
  end

  test "status-only public health contract rejects extra fields on the error pair" do
    response = %{status: 503, body: %{"status" => "error", "reason" => "hidden"}}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "invalid health response"
    refute message =~ "hidden"
  end

  test "status-only public health accepts exact ok and error pairs" do
    ready =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], ready)
    assert banner =~ "Status:  ready"
    refute banner =~ "runtime"
    refute banner =~ "Remediation"

    degraded =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, degraded_response()} end
      })

    assert {:ok, banner} = Status.run([], degraded)
    assert banner =~ "Status:  degraded"
    refute banner =~ "postgres_reachable"
  end
end
