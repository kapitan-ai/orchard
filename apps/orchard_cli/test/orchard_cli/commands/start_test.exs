defmodule OrchardCLI.Commands.StartTest do
  use ExUnit.Case, async: false

  alias OrchardCLI.Commands.{LifecycleSupport, Start}

  # ── Helpers ──────────────────────────────────────────────────────────

  defp test_services do
    [
      %{
        id: :node_agent,
        label: "com.orchard.node-agent",
        plist_path: "/tmp/test-node-agent.plist",
        display_name: "Node Agent"
      },
      %{
        id: :controller,
        label: "com.orchard.controller",
        plist_path: "/tmp/test-controller.plist",
        display_name: "Controller"
      }
    ]
  end

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        services: test_services(),
        read_install_role: fn -> {:ok, "all"} end,
        file_regular?: fn _path -> true end,
        cmd: fn _prog, _args, _opts -> {"\n", 0} end,
        monotonic_ms: fn -> 0 end,
        sleep: fn _ms -> :ok end,
        ready_timeout_ms: 100,
        poll_interval_ms: 10,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts ->
            {:ok,
             %{
               status: 200,
               body: %{"status" => "ok"}
             }}
          end
        }
      },
      overrides
    )
  end

  # Runtime without a :services key, so LifecycleSupport resolves its own
  # production service list the way the packaged CLI does.
  defp default_services_runtime(overrides) do
    Map.delete(base_runtime(overrides), :services)
  end

  # Simulate service not loaded (launchctl list returns non-zero)
  defp not_loaded_cmd(parent) do
    fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> _label]} -> {"Could not find service\n", 113}
        {"launchctl", ["bootstrap" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end
  end

  # Simulate services already loaded
  defp already_loaded_cmd(parent) do
    fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> _label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        _ -> {"\n", 0}
      end
    end
  end

  # ── Usage / Help ─────────────────────────────────────────────────────

  test "help returns usage" do
    assert {:ok, msg} = Start.run(["help"], base_runtime())
    assert msg =~ "orchardctl start"
  end

  test "--help returns usage" do
    assert {:ok, msg} = Start.run(["--help"], base_runtime())
    assert msg =~ "orchardctl start"
  end

  test "extra args returns error" do
    assert {:error, msg, 1} = Start.run(["extra"], base_runtime())
    assert msg =~ "orchardctl start"
  end

  # ── Root Check ───────────────────────────────────────────────────────

  test "non-root returns root-required error" do
    runtime = base_runtime(%{uid: fn -> 501 end})
    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "root privileges required"
    assert msg =~ "sudo orchardctl start"
  end

  # ── Packaged Install Validation ──────────────────────────────────────

  test "missing plists returns packaged-install error" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn _path -> false end,
        cmd: not_loaded_cmd(parent)
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "packaged install not found"
    assert msg =~ "install role"
  end

  test "missing role-specific plist names the active role" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "controller\n"} end,
        file_regular?: fn _path -> false end,
        cmd: not_loaded_cmd(parent)
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "role controller"
    assert msg =~ "/tmp/test-controller.plist"
    refute msg =~ "/tmp/test-node-agent.plist"
    assert msg =~ "bin/dev"
  end

  test "controller role filters start services to controller only" do
    runtime =
      %{
        read_install_role: fn -> {:ok, "controller"} end,
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: fn _prog, _args, _opts -> {"Could not find service\n", 113} end
      }

    services = LifecycleSupport.services(:start, runtime)
    assert Enum.map(services, & &1.id) == [:controller]
    refute Enum.any?(services, &(&1.id == :node_agent))
  end

  test "lone stale postgres plist is not treated as packaged context" do
    postgres = %{
      id: :postgres,
      label: "com.orchard.postgres",
      plist_path: "/tmp/test-postgres.plist",
      display_name: "Managed Postgres"
    }

    runtime =
      base_runtime(%{
        services: [postgres],
        read_install_role: fn -> {:ok, "all"} end,
        file_regular?: fn _path -> true end
      })

    refute LifecycleSupport.any_plist_exists?(runtime)
    assert LifecycleSupport.services(:start, runtime) == []
  end

  test "node-agent role filters start services to node-agent only" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "node-agent"} end})

    services = LifecycleSupport.services(:start, runtime)
    assert Enum.map(services, & &1.id) == [:node_agent]
    refute Enum.any?(services, &(&1.id == :controller))
  end

  test "node-agent role excludes postgres even when postgres plist is installed" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist")
        end,
        cmd: fn _prog, _args, _opts -> {"Could not find service\n", 113} end
      })
      |> Map.delete(:services)

    services = LifecycleSupport.services(:start, runtime)
    assert Enum.map(services, & &1.id) == [:node_agent]
    refute Enum.any?(services, &(&1.id == :postgres))
  end

  test "missing marker falls back to plist inference for all role" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn path ->
          path in ["/tmp/test-node-agent.plist", "/tmp/test-controller.plist"]
        end
      })

    assert {:ok, :all} = LifecycleSupport.install_role(runtime)
  end

  test "invalid marker returns actionable error" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "bogus"} end,
        file_regular?: fn path -> path == "/tmp/test-controller.plist" end
      })

    assert {:error, msg, 1} = LifecycleSupport.install_role(runtime)
    assert msg =~ "invalid Orchard install role marker"
    assert msg =~ "Expected one of: all, controller, node-agent"
    assert msg =~ ~s(Found: "bogus")
  end

  test "missing marker falls back to plist inference for controller role" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn path -> path == "/tmp/test-controller.plist" end
      })

    assert {:ok, :controller} = LifecycleSupport.install_role(runtime)
  end

  test "missing marker falls back to plist inference for node-agent role" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn path -> path == "/tmp/test-node-agent.plist" end
      })

    assert {:ok, :node_agent} = LifecycleSupport.install_role(runtime)
  end

  # ── Successful Start ─────────────────────────────────────────────────

  test "node-agent role starts without polling controller readiness" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        cmd: not_loaded_cmd(parent),
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts ->
            send(parent, :controller_polled)
            {:error, :unexpected_poll}
          end
        }
      })

    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "Loaded Orchard services into launchd."
    assert banner =~ "Role: node-agent"
    assert banner =~ "Controller: remote/not checked"
    refute_received :controller_polled

    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)
    assert [{_, ["bootstrap", "system", plist]}] = bootstrap_calls
    assert plist =~ "node-agent"
  end

  test "starts services in order: node-agent then controller" do
    parent = self()
    runtime = base_runtime(%{cmd: not_loaded_cmd(parent)})

    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "Loaded Orchard services into launchd."
    assert banner =~ "Orchard v0.1.0"

    # Verify bootstrap order
    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)
    assert length(bootstrap_calls) == 2

    [{_, ["bootstrap", "system", na_plist]}, {_, ["bootstrap", "system", ctrl_plist]}] =
      bootstrap_calls

    assert na_plist =~ "node-agent"
    assert ctrl_plist =~ "controller"
  end

  test "start inherits status probe/display split through snapshot" do
    parent = self()
    ref = make_ref()

    runtime =
      base_runtime(%{
        cmd: not_loaded_cmd(parent),
        status_runtime: %{
          version: fn -> "0.1.0" end,
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

            {:ok, %{status: 200, body: %{"status" => "ok"}}}
          end
        }
      })

    assert {:ok, banner} = Start.run([], runtime)
    assert_received {^ref, "http://127.0.0.1:4101/health/ready"}
    assert banner =~ "Console: https://orchard.example.internal/console"
    refute banner =~ "127.0.0.1:4101/console"
  end

  test "both already loaded shows informative message and banner" do
    parent = self()
    runtime = base_runtime(%{cmd: already_loaded_cmd(parent)})

    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "Orchard services already loaded in launchd."
    assert banner =~ "Orchard v0.1.0"

    # No bootstrap calls should have been made
    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)
    assert bootstrap_calls == []
  end

  test "ignores stale managed postgres plist when starting" do
    parent = self()

    runtime =
      default_services_runtime(%{
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: not_loaded_cmd(parent)
      })

    assert {:ok, _banner} = Start.run([], runtime)

    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)

    assert [
             {_, ["bootstrap", "system", node_agent_plist]},
             {_, ["bootstrap", "system", controller_plist]}
           ] = bootstrap_calls

    assert node_agent_plist =~ "node-agent"
    assert controller_plist =~ "controller"
    refute Enum.any?(bootstrap_calls, fn {_, [_, _, plist]} -> plist =~ "postgres" end)
  end

  test "already-loaded stale postgres is ignored when plist is missing" do
    parent = self()
    postgres_label = "com.orchard.postgres"

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> ^postgres_label]} -> {"{\n\t\"pid\" : 111;\n}\n", 0}
        {"launchctl", ["print", "system/" <> _label]} -> {"Could not find service\n", 113}
        {"launchctl", ["bootstrap" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end

    runtime =
      base_runtime(%{
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.node-agent.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: cmd_fn
      })
      |> Map.delete(:services)

    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "Loaded Orchard services into launchd"

    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)
    assert length(bootstrap_calls) == 2

    refute Enum.any?(cmds, fn {_prog, args} ->
             args == ["print", "system/com.orchard.postgres"]
           end)
  end

  test "partial loaded: only missing service gets bootstrapped" do
    parent = self()
    na_label = "com.orchard.node-agent"
    ctrl_label = "com.orchard.controller"

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> ^na_label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        {"launchctl", ["print", "system/" <> ^ctrl_label]} -> {"Could not find service\n", 113}
        {"launchctl", ["bootstrap" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end

    runtime = base_runtime(%{cmd: cmd_fn})
    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "some services were already loaded"

    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)
    assert length(bootstrap_calls) == 1
    [{_, ["bootstrap", "system", plist]}] = bootstrap_calls
    assert plist =~ "controller"
  end

  # ── Readiness Timeout ────────────────────────────────────────────────

  test "already-loaded services with unreachable readiness do not report already running" do
    parent = self()
    key = make_ref()
    Process.put(key, 0)

    monotonic_ms = fn ->
      current = Process.get(key, 0)
      Process.put(key, current + 25)
      current
    end

    runtime =
      base_runtime(%{
        cmd: already_loaded_cmd(parent),
        ready_timeout_ms: 50,
        poll_interval_ms: 10,
        monotonic_ms: monotonic_ms,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts -> {:error, :econnrefused} end
        }
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "Orchard services already loaded in launchd."
    refute msg =~ "already running"
    assert msg =~ "did not become ready"
  end

  test "readiness timeout returns error with last state" do
    parent = self()
    key = make_ref()
    Process.put(key, 0)

    monotonic_ms = fn ->
      current = Process.get(key, 0)
      Process.put(key, current + 25)
      current
    end

    runtime =
      base_runtime(%{
        cmd: not_loaded_cmd(parent),
        ready_timeout_ms: 50,
        poll_interval_ms: 10,
        monotonic_ms: monotonic_ms,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts -> {:error, :econnrefused} end
        }
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "did not become ready"
    assert msg =~ "offline"
    assert msg =~ "orchardctl status"
  end

  test "status install errors for active-mode ports stop polling and surface config error" do
    parent = self()
    request_count = :counters.new(1, [:atomics])
    original_mode = System.get_env("ORCHARD_TRANSPORT_MODE")
    original_public_port = System.get_env("ORCHARD_PUBLIC_PORT")
    original_port = System.get_env("PORT")

    on_exit(fn ->
      restore_env("ORCHARD_TRANSPORT_MODE", original_mode)
      restore_env("ORCHARD_PUBLIC_PORT", original_public_port)
      restore_env("PORT", original_port)
    end)

    System.put_env("ORCHARD_TRANSPORT_MODE", "plain_http_localhost")
    System.put_env("PORT", "abc")

    runtime =
      base_runtime(%{
        cmd: not_loaded_cmd(parent),
        ready_timeout_ms: 50,
        poll_interval_ms: 10,
        monotonic_ms: fn -> 0 end,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          request: fn _url, _opts ->
            :counters.add(request_count, 1, 1)
            {:ok, %{status: 200, body: %{"status" => "ok"}}}
          end
        }
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "invalid PORT: abc"
    refute msg =~ "did not become ready"
    assert :counters.get(request_count, 1) == 0
  end

  test "invalid health response stops polling and surfaces the URL immediately" do
    parent = self()
    request_count = :counters.new(1, [:atomics])

    runtime =
      base_runtime(%{
        cmd: not_loaded_cmd(parent),
        ready_timeout_ms: 50,
        poll_interval_ms: 10,
        monotonic_ms: fn -> 0 end,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts ->
            :counters.add(request_count, 1, 1)
            {:ok, %{status: 200, body: "<html>oops</html>"}}
          end
        }
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "invalid health response"
    assert msg =~ "malformed JSON in health response"
    assert msg =~ "http://localhost:4000"
    assert :counters.get(request_count, 1) == 1
  end

  test "mixed invalid and unreachable candidates continue polling until a candidate is ready" do
    parent = self()
    http_calls_key = make_ref()
    Process.put(http_calls_key, 0)

    runtime =
      base_runtime(%{
        cmd: not_loaded_cmd(parent),
        ready_timeout_ms: 50,
        poll_interval_ms: 10,
        monotonic_ms: fn -> 0 end,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn ->
            [
              %{base_url: "https://localhost:8443", ca_certfile: nil},
              %{base_url: "http://localhost:4000", ca_certfile: nil}
            ]
          end,
          request: fn url, _opts ->
            if String.starts_with?(url, "https://") do
              {:ok, %{status: 200, body: "<html>oops</html>"}}
            else
              current = Process.get(http_calls_key, 0)
              Process.put(http_calls_key, current + 1)

              if current == 0 do
                {:error, :econnrefused}
              else
                {:ok, %{status: 200, body: %{"status" => "ok"}}}
              end
            end
          end
        }
      })

    assert {:ok, banner} = Start.run([], runtime)
    assert banner =~ "Loaded Orchard services into launchd."
    assert banner =~ "Orchard v0.1.0"
    assert Process.get(http_calls_key) == 2
  end

  # ── Bootstrap Failure ────────────────────────────────────────────────

  test "bootstrap failure after earlier success mentions partial start" do
    parent = self()

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        # Neither loaded initially
        {"launchctl", ["print", "system/" <> _label]} ->
          {"Could not find service\n", 113}

        # Node agent starts fine
        {"launchctl", ["bootstrap", "system", plist]} ->
          if plist =~ "node-agent" do
            {"\n", 0}
          else
            {"Bootstrap failed\n", 5}
          end

        _ ->
          {"\n", 0}
      end
    end

    runtime = base_runtime(%{cmd: cmd_fn})
    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "failed to start Controller"
    assert msg =~ "launchctl exit 5: Bootstrap failed"
    assert msg =~ "Node Agent was loaded into launchd but not rolled back"
    assert msg =~ "orchardctl stop"
  end

  test "partial failure does not claim already-loaded services were loaded" do
    parent = self()
    na_label = "com.orchard.node-agent"

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> ^na_label]} ->
          {"{\n\t\"pid\" : 123;\n}\n", 0}

        {"launchctl", ["print", "system/" <> _label]} ->
          {"Could not find service\n", 113}

        {"launchctl", ["bootstrap", "system", plist]} ->
          if plist =~ "controller" do
            {"Bootstrap failed\n", 5}
          else
            {"\n", 0}
          end

        _ ->
          {"\n", 0}
      end
    end

    runtime = base_runtime(%{cmd: cmd_fn})
    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "failed to start Controller"
    assert msg =~ "Node Agent was already loaded in launchd and not changed"
    refute msg =~ "Node Agent was loaded into launchd but not rolled back"
  end

  test "partial failure ignores stale postgres and preserves start order" do
    parent = self()

    runtime =
      default_services_runtime(%{
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: fn prog, args, _opts ->
          send(parent, {:cmd, prog, args})

          case {prog, args} do
            {"launchctl", ["print", _target]} ->
              {"Could not find service\n", 113}

            {"launchctl", ["bootstrap", "system", plist]} ->
              if plist =~ "controller" do
                {"Bootstrap failed\n", 5}
              else
                {"\n", 0}
              end

            _ ->
              {"\n", 0}
          end
        end,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts -> {:error, :econnrefused} end
        }
      })

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "Node Agent was loaded into launchd but not rolled back"
    refute msg =~ "Managed Postgres"
  end

  # ── Helper ───────────────────────────────────────────────────────────

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

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
end
