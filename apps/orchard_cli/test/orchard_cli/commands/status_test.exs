defmodule OrchardCLI.Commands.StatusTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Status

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

  defp ready_response do
    %{
      status: 200,
      body: %{
        "status" => "ok",
        "checks" => %{
          "controller_boot_completed" => true,
          "postgres_reachable" => true,
          "migrations_current" => true,
          "public_api_https_enabled" => true
        },
        "runtime" => %{
          "status" => "ok",
          "node_id" => "550e8400-e29b-41d4-a716-446655440000",
          "display_name" => "test-node",
          "worker_state" => "idle",
          "health" => "healthy",
          "counts" => %{
            "active_requests" => 0,
            "loaded_models" => 1
          },
          "message" => nil
        }
      }
    }
  end

  defp degraded_response(reason \\ "postgres_reachable") do
    %{
      status: 503,
      body: %{
        "status" => "error",
        "reason" => reason,
        "checks" => %{
          "controller_boot_completed" => true,
          "postgres_reachable" => false,
          "migrations_current" => false,
          "public_api_https_enabled" => true
        },
        "runtime" => %{
          "status" => "ok",
          "node_id" => "550e8400-e29b-41d4-a716-446655440000",
          "display_name" => "test-node",
          "worker_state" => "idle",
          "health" => "healthy",
          "counts" => %{
            "active_requests" => 0,
            "loaded_models" => 2
          },
          "message" => nil
        }
      }
    }
  end

  defp runtime_timeout_response do
    %{
      status: 503,
      body: %{
        "status" => "error",
        "reason" => "postgres_reachable",
        "runtime" => %{
          "status" => "timeout",
          "worker_state" => "unknown",
          "node_id" => nil,
          "health" => "unsupported",
          "counts" => %{
            "active_requests" => nil,
            "loaded_models" => nil
          },
          "message" => "node status request timed out"
        }
      }
    }
  end

  # ── Usage / Help ─────────────────────────────────────────────────────

  test "help returns usage" do
    assert {:ok, message} = Status.run(["help"], test_runtime())
    assert message =~ "orchardctl status"
    assert message =~ "health endpoint"
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

  test "ready controller shows full status banner" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "\u{1F333} Orchard v0.1.0"
    assert banner =~ "Role:    all"
    assert banner =~ "Console: http://localhost:4000/console"
    assert banner =~ "API:     http://localhost:4000/v1"
    assert banner =~ "Status:  ready"
    assert banner =~ "1 node"
    assert banner =~ "idle"
    assert banner =~ "1 model loaded"
  end

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

  test "ready banner with plural models" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "counts", "loaded_models"], 3)
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "3 models loaded"
    refute banner =~ "3 model loaded"
  end

  test "ready banner with zero models" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "counts", "loaded_models"], 0)
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "0 models loaded"
  end

  test "ready banner with no node_id shows 0 nodes" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "node_id"], nil)
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "0 nodes"
  end

  test "ready banner uses correct version" do
    runtime =
      test_runtime(%{
        version: fn -> "1.2.3" end,
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Orchard v1.2.3"
  end

  # ── Degraded Banner ──────────────────────────────────────────────────

  test "degraded controller shows reason in status" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, degraded_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "Status:  degraded"
    assert banner =~ "postgres_reachable"
    assert banner =~ "2 models loaded"
  end

  test "degraded with custom reason" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, degraded_response("migrations_current")} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "degraded"
    assert banner =~ "migrations_current"
  end

  # ── Runtime Unavailable ──────────────────────────────────────────────

  test "runtime timeout shows runtime status in details" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, runtime_timeout_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "degraded"
    assert banner =~ "runtime timeout"
  end

  test "response with no runtime block shows runtime unavailable" do
    response = %{
      status: 200,
      body: %{
        "status" => "ok",
        "checks" => %{}
      }
    }

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "ready"
    assert banner =~ "runtime unavailable"
  end

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
    assert message =~ "unexpected health status"
  end

  test "missing status field with single candidate returns invalid-response error" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts ->
          {:ok, %{status: 200, body: %{"other" => "data"}}}
        end
      })

    assert {:error, message, 1} = Status.run([], runtime)
    assert message =~ "missing \"status\" field"
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

  test "runtime as string instead of map shows runtime unavailable" do
    response = %{
      status: 200,
      body: %{
        "status" => "ok",
        "runtime" => "oops"
      }
    }

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "ready"
    assert banner =~ "runtime unavailable"
  end

  test "counts as non-map defaults model count to 0" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "counts"], "broken")
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "0 models loaded"
  end

  # ── Runtime Health Surface ───────────────────────────────────────────

  test "degraded runtime health is surfaced in ready banner" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "health"], "degraded")
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "health: degraded"
  end

  test "unhealthy runtime health is surfaced in ready banner" do
    response = ready_response()
    body = put_in(response.body, ["runtime", "health"], "unhealthy")
    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "health: unhealthy"
  end

  test "healthy runtime health is not shown in banner" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    refute banner =~ "health:"
  end

  test "renders license line when health payload includes a valid license block" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "valid",
        "reason" => nil,
        "message" => "License bundle is valid.",
        "expires_at" => "2027-04-15T00:00:00Z"
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License: valid"
    assert banner =~ "License bundle is valid."
    assert banner =~ "expires: 2027-04-15T00:00:00Z"
  end

  test "renders license tracking line when health payload includes tracking metadata" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "valid",
        "reason" => nil,
        "message" => "License bundle is valid.",
        "expires_at" => "2027-04-15T00:00:00Z",
        "tracking" => %{
          "program" => "aieh",
          "reference" => "aieh-2026-001"
        }
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License: valid"
    assert banner =~ "Tracking: program=aieh ref=aieh-2026-001"
  end

  test "renders license identifiers when health payload includes them" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "valid",
        "reason" => nil,
        "message" => "License bundle is valid.",
        "license_id" => "lic_visible",
        "machine_id" => "mach_visible",
        "licensee" => "Acme Orchard Lab",
        "max_machines" => 3
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License ID: lic_visible"
    assert banner =~ "Machine ID: mach_visible"
    assert banner =~ "Licensee: Acme Orchard Lab"
    assert banner =~ "Max machines: 3"
  end

  test "omits license identifiers when health payload excludes them" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "missing",
        "reason" => "missing_bundle",
        "message" => "No local license bundle is installed."
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License: missing"
    refute banner =~ "License ID:"
    refute banner =~ "Machine ID:"
    refute banner =~ "Licensee:"
    refute banner =~ "Max machines:"
  end

  test "does not render a license line when the health payload omits the license block" do
    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, ready_response()} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    refute banner =~ "License:"
  end

  test "ignores malformed license tracking blocks for backward compatibility" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "valid",
        "reason" => nil,
        "message" => "License bundle is valid.",
        "tracking" => "not-a-map"
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License: valid"
    refute banner =~ "Tracking:"
  end

  test "ignores empty license tracking fields for backward compatibility" do
    response = ready_response()

    body =
      put_in(response.body, ["license"], %{
        "status" => "valid",
        "reason" => nil,
        "message" => "License bundle is valid.",
        "tracking" => %{"program" => "", "reference" => 123}
      })

    response = %{response | body: body}

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    assert banner =~ "License: valid"
    refute banner =~ "Tracking:"
  end

  test "ignores malformed license blocks for backward compatibility" do
    response = ready_response()
    response = put_in(response.body, ["license"], %{"status" => "valid"})

    runtime =
      test_runtime(%{
        request: fn _url, _opts -> {:ok, response} end
      })

    assert {:ok, banner} = Status.run([], runtime)
    refute banner =~ "License:"
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
end
