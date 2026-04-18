defmodule OrchardCLI.Commands.StartTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Start

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
               body: %{
                 "status" => "ok",
                 "runtime" => %{
                   "status" => "ok",
                   "node_id" => "n1",
                   "worker_state" => "idle",
                   "counts" => %{"loaded_models" => 0},
                   "health" => "healthy"
                 }
               }
             }}
          end
        }
      },
      overrides
    )
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
    runtime = base_runtime(%{file_regular?: fn _path -> false end, cmd: not_loaded_cmd(parent)})
    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "packaged install not found"
    assert msg =~ "bin/dev"
  end

  # ── Successful Start ─────────────────────────────────────────────────

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

  test "includes managed postgres first when its plist is installed" do
    parent = self()

    runtime =
      %{
        uid: fn -> 0 end,
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: not_loaded_cmd(parent),
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
               body: %{
                 "status" => "ok",
                 "runtime" => %{
                   "status" => "ok",
                   "node_id" => "n1",
                   "worker_state" => "idle",
                   "counts" => %{"loaded_models" => 0},
                   "health" => "healthy"
                 }
               }
             }}
          end
        }
      }

    assert {:ok, _banner} = Start.run([], runtime)

    cmds = collect_cmds()
    bootstrap_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootstrap" | _], args) end)

    assert [
             {_, ["bootstrap", "system", postgres_plist]},
             {_, ["bootstrap", "system", node_agent_plist]},
             {_, ["bootstrap", "system", controller_plist]}
           ] = bootstrap_calls

    assert postgres_plist =~ "postgres"
    assert node_agent_plist =~ "node-agent"
    assert controller_plist =~ "controller"
  end

  test "already-loaded optional postgres does not fail validation when plist is missing" do
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
            cond do
              String.starts_with?(url, "https://") ->
                {:ok, %{status: 200, body: "<html>oops</html>"}}

              true ->
                current = Process.get(http_calls_key, 0)
                Process.put(http_calls_key, current + 1)

                if current == 0 do
                  {:error, :econnrefused}
                else
                  {:ok,
                   %{
                     status: 200,
                     body: %{
                       "status" => "ok",
                       "runtime" => %{
                         "status" => "ok",
                         "node_id" => "n1",
                         "worker_state" => "idle",
                         "counts" => %{"loaded_models" => 0},
                         "health" => "healthy"
                       }
                     }
                   }}
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

  test "multi-service partial failure preserves start order and pluralizes note" do
    parent = self()

    runtime =
      %{
        uid: fn -> 0 end,
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
              cond do
                plist =~ "controller" -> {"Bootstrap failed\n", 5}
                true -> {"\n", 0}
              end

            _ ->
              {"\n", 0}
          end
        end,
        monotonic_ms: fn -> 0 end,
        sleep: fn _ms -> :ok end,
        ready_timeout_ms: 100,
        poll_interval_ms: 10,
        status_runtime: %{
          version: fn -> "0.1.0" end,
          endpoint_candidates: fn -> [%{base_url: "http://localhost:4000", ca_certfile: nil}] end,
          request: fn _url, _opts -> {:error, :econnrefused} end
        }
      }

    assert {:error, msg, 1} = Start.run([], runtime)
    assert msg =~ "Managed Postgres, Node Agent were loaded into launchd but not rolled back"
    refute msg =~ "Node Agent, Managed Postgres"
  end

  # ── Helper ───────────────────────────────────────────────────────────

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
