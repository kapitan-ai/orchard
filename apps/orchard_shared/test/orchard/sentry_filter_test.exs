defmodule Orchard.SentryFilterTest do
  use ExUnit.Case, async: true

  alias Orchard.SentryFilter

  test "reconstructs string-keyed request context from the method allowlist" do
    event = %{
      "request" => %{
        "method" => "POST",
        "headers" => [
          {"authorization", "Bearer secret"},
          {"cookie", "session=value"},
          {"x-api-key", "apikey"},
          {"accept", "application/json"}
        ],
        "query_string" => "api_key=secret"
      }
    }

    assert %{"request" => %{"method" => "POST"}} = SentryFilter.filter(event)
  end

  test "removes the entire request body including unknown inference fields" do
    event = %{
      request: %{
        method: "POST",
        data: %{
          messages: [%{role: "user", content: "hello"}],
          instructions: "system instructions",
          tools: [%{name: "proprietary_tool"}],
          tool_choice: "required",
          metadata: %{tenant: "demo"},
          model: "mlx-community/qwen2.5"
        }
      }
    }

    assert %{request: %{method: "POST"}} = SentryFilter.filter(event)
  end

  test "drops invalid request methods with every other request field" do
    event = %{
      request: %{
        method: "POST\r\nx-injected: value",
        data: %{input: "secret"},
        headers: %{"authorization" => "Bearer secret"}
      }
    }

    assert %{request: %{}} = SentryFilter.filter(event)
  end

  test "scrubs breadcrumb data recursively" do
    event = %{
      breadcrumbs: [
        %{
          category: "orchard.auth",
          data: %{
            api_key: "api-key",
            nested: %{ip_address: "10.0.0.1", model_id: "mlx-community/qwen2.5"}
          }
        }
      ]
    }

    filtered = SentryFilter.filter(event)
    [breadcrumb] = filtered.breadcrumbs

    assert breadcrumb.data.api_key == "[Filtered]"
    assert breadcrumb.data.nested.ip_address == "[Filtered]"
    assert breadcrumb.data.nested.model_id == "mlx-community/qwen2.5"
  end

  test "scrubs x-api-key outside canonical headers" do
    event = %{
      contexts: %{
        orchard: %{
          "x-api-key" => "secret-api-key",
          nested: %{:"x-api-key" => "other-secret", model_id: "mlx-community/qwen2.5"}
        }
      }
    }

    filtered = SentryFilter.filter(event)

    assert filtered.contexts.orchard["x-api-key"] == "[Filtered]"
    assert filtered.contexts.orchard.nested[:"x-api-key"] == "[Filtered]"
    assert filtered.contexts.orchard.nested.model_id == "mlx-community/qwen2.5"
  end

  test "scrubs common sensitive key variants while preserving safe token counters" do
    event = %{
      extra: %{
        "access_token" => "access-token",
        "refresh-token" => "refresh-token",
        "clientSecret" => "client-secret",
        "secretAccessKey" => "secret-access-key",
        "apiKey" => "api-key",
        "token_prefix" => "orch_prefix",
        "api_key_prefix" => "orch_prefix",
        "keyPrefix" => "orch_prefix",
        "authorizationHeader" => "Bearer secret",
        "node_id" => "node-1",
        "orchard_node_id" => "node-2",
        "orchard_node_hash" => "0123456789abcdef",
        "machine_id" => "raw-machine-id",
        "orchardMachineId" => "raw-orchard-machine-id",
        "fingerprint" => "raw-fingerprint",
        "local_node_fingerprint" => "raw-local-node-fingerprint",
        "nodeFingerprint" => "raw-node-fingerprint",
        "licenseFingerprint" => "raw-license-fingerprint",
        "keyFingerprint" => "raw-key-fingerprint",
        "remoteMachineId" => "raw-remote-machine-id",
        "input_tokens" => 12,
        "outputTokens" => 3,
        "token_usage" => %{total: 15}
      }
    }

    filtered = SentryFilter.filter(event)

    assert filtered.extra["access_token"] == "[Filtered]"
    assert filtered.extra["refresh-token"] == "[Filtered]"
    assert filtered.extra["clientSecret"] == "[Filtered]"
    assert filtered.extra["secretAccessKey"] == "[Filtered]"
    assert filtered.extra["apiKey"] == "[Filtered]"
    assert filtered.extra["token_prefix"] == "[Filtered]"
    assert filtered.extra["api_key_prefix"] == "[Filtered]"
    assert filtered.extra["keyPrefix"] == "[Filtered]"
    assert filtered.extra["authorizationHeader"] == "[Filtered]"
    assert filtered.extra["node_id"] == "[Filtered]"
    assert filtered.extra["orchard_node_id"] == "[Filtered]"
    assert filtered.extra["orchard_node_hash"] == "0123456789abcdef"
    assert filtered.extra["machine_id"] == "[Filtered]"
    assert filtered.extra["orchardMachineId"] == "[Filtered]"
    assert filtered.extra["fingerprint"] == "[Filtered]"
    assert filtered.extra["local_node_fingerprint"] == "[Filtered]"
    assert filtered.extra["nodeFingerprint"] == "[Filtered]"
    assert filtered.extra["licenseFingerprint"] == "[Filtered]"
    assert filtered.extra["keyFingerprint"] == "[Filtered]"
    assert filtered.extra["remoteMachineId"] == "[Filtered]"
    assert filtered.extra["input_tokens"] == 12
    assert filtered.extra["outputTokens"] == 3
    assert filtered.extra["token_usage"] == %{total: 15}
  end

  test "preserves known Orchard HMAC correlation hashes while filtering adjacent secrets" do
    event = %{
      extra: %{
        "orchard_api_key_hash" => "0123456789abcdef",
        "orchardTenantHash" => "aaaaaaaaaaaaaaaa",
        :orchard_principal_hash => "bbbbbbbbbbbbbbbb",
        "orchard_node_hash" => "cccccccccccccccc",
        "api_key" => "raw-api-key",
        "api_key_id" => "raw-api-key-id",
        "api_key_prefix" => "orch_prefix",
        "secret_hash" => "secret-hash",
        "api_key_hash" => "not-an-orchard-safe-field"
      },
      contexts: %{
        orchard: %{
          "orchard_api_key_hash" => "dddddddddddddddd",
          "orchard_node_hash" => "not-a-valid-hash",
          "x-api-key" => "header-style-secret"
        }
      },
      breadcrumbs: [
        %{
          data: %{
            orchard_api_key_hash: "eeeeeeeeeeeeeeee",
            api_key: "breadcrumb-api-key"
          }
        }
      ]
    }

    filtered = SentryFilter.filter(event)

    assert filtered.extra["orchard_api_key_hash"] == "0123456789abcdef"
    assert filtered.extra["orchardTenantHash"] == "aaaaaaaaaaaaaaaa"
    assert filtered.extra.orchard_principal_hash == "bbbbbbbbbbbbbbbb"
    assert filtered.extra["orchard_node_hash"] == "cccccccccccccccc"

    assert filtered.extra["api_key"] == "[Filtered]"
    assert filtered.extra["api_key_id"] == "[Filtered]"
    assert filtered.extra["api_key_prefix"] == "[Filtered]"
    assert filtered.extra["secret_hash"] == "[Filtered]"
    assert filtered.extra["api_key_hash"] == "[Filtered]"

    assert filtered.contexts.orchard["orchard_api_key_hash"] == "dddddddddddddddd"
    assert filtered.contexts.orchard["orchard_node_hash"] == "[Filtered]"
    assert filtered.contexts.orchard["x-api-key"] == "[Filtered]"

    [breadcrumb] = filtered.breadcrumbs
    assert breadcrumb.data.orchard_api_key_hash == "eeeeeeeeeeeeeeee"
    assert breadcrumb.data.api_key == "[Filtered]"

    refute inspect(filtered) =~ "raw-api-key"
    refute inspect(filtered) =~ "raw-api-key-id"
    refute inspect(filtered) =~ "orch_prefix"
    refute inspect(filtered) =~ "header-style-secret"
    refute inspect(filtered) =~ "breadcrumb-api-key"
  end

  test "scrubs explicit license secret keys in extra and breadcrumb data" do
    secret_keys = [
      "license_certificate",
      "machine_certificate",
      "activation_key",
      "license_key",
      "keygen_admin_token",
      "orchard_keygen_admin_token",
      "keygen_public_key",
      "keygen_private_key",
      "private_key",
      "certificate",
      "key",
      "certificate_pem",
      "private_key_pem",
      "key_pem",
      "signing_key",
      "public_key",
      "certfile",
      "keyfile",
      "pem",
      "cert",
      "certificate_chain",
      "bundle_path",
      "node_identity_path",
      "models_root",
      "worker_log_dir",
      "artifact_uri"
    ]

    event = %{
      extra: Map.new(secret_keys, &{&1, "secret-#{&1}"}),
      breadcrumbs: [
        %{
          data:
            secret_keys
            |> Enum.map(&String.to_atom/1)
            |> Map.new(&{&1, "breadcrumb-secret-#{&1}"})
        }
      ]
    }

    filtered = SentryFilter.filter(event)

    for key <- secret_keys do
      assert filtered.extra[key] == "[Filtered]"
    end

    [breadcrumb] = filtered.breadcrumbs

    for key <- Enum.map(secret_keys, &String.to_atom/1) do
      assert breadcrumb.data[key] == "[Filtered]"
    end
  end

  test "preserves valid orchard machine hash and filters malformed values" do
    event = %{
      extra: %{
        orchard_machine_id_hash: "abc123def4567890"
      },
      contexts: %{
        orchard: %{
          "orchard_machine_id_hash" => "not-a-valid-hash"
        }
      }
    }

    filtered = SentryFilter.filter(event)

    assert filtered.extra.orchard_machine_id_hash == "abc123def4567890"
    assert filtered.contexts.orchard["orchard_machine_id_hash"] == "[Filtered]"
  end

  test "scrubs nested Keygen-style certificate and key payloads" do
    event = %{
      contexts: %{
        keygen: %{
          data: %{
            attributes: %{
              certificate: "raw-certificate",
              key: "raw-license-key",
              fingerprint: "raw-machine-fingerprint"
            }
          }
        }
      }
    }

    filtered = SentryFilter.filter(event)

    attrs = filtered.contexts.keygen.data.attributes
    assert attrs.certificate == "[Filtered]"
    assert attrs.key == "[Filtered]"
    assert attrs.fingerprint == "[Filtered]"
    refute inspect(filtered) =~ "raw-certificate"
    refute inspect(filtered) =~ "raw-license-key"
    refute inspect(filtered) =~ "raw-machine-fingerprint"
  end

  test "scrubs path-like suffixes without filtering safe Orchard hashes" do
    event = %{
      extra: %{
        "download_path" => "/Users/test/private/model",
        "cacheDir" => "/Library/Application Support/Orchard/cache",
        "modelsRoot" => "/Library/Application Support/Orchard/models",
        "source_uri" => "file:///private/current.json",
        "orchard_machine_id_hash" => "abc123def4567890"
      }
    }

    filtered = SentryFilter.filter(event)

    assert filtered.extra["download_path"] == "[Filtered]"
    assert filtered.extra["cacheDir"] == "[Filtered]"
    assert filtered.extra["modelsRoot"] == "[Filtered]"
    assert filtered.extra["source_uri"] == "[Filtered]"
    assert filtered.extra["orchard_machine_id_hash"] == "abc123def4567890"
    refute inspect(filtered) =~ "/Library/Application Support/Orchard"
  end

  test "passes through non-sensitive license traceability fields" do
    traceability = %{
      orchard_license_state: "valid",
      orchard_license_id: "lic_eval_123",
      orchard_expires_at: "2027-04-15T00:00:00Z",
      orchard_max_machines: 3,
      orchard_tracking_program: "aieh",
      orchard_tracking_reference: "aieh-2026-001",
      orchard_build_channel: "trial",
      orchard_build_ref: "abc1234"
    }

    event = %{extra: traceability}

    assert SentryFilter.filter(event).extra == traceability
  end

  test "does not preserve raw licensee identity as Sentry traceability" do
    filtered = SentryFilter.filter(%{extra: %{licensee: "Acme Orchard Lab"}})

    assert filtered.extra.licensee == "[Filtered]"
  end

  test "scrubs user and host identity fields" do
    event = %{
      server_name: "workstation.local",
      user: %{id: "user-1", email: "person@example.com", ip_address: "127.0.0.1"},
      contexts: %{runtime: %{ip_address: "192.0.2.1"}}
    }

    filtered = SentryFilter.filter(event)

    assert filtered.server_name == "[redacted]"
    assert filtered.user.id == "[Filtered]"
    assert filtered.user.email == "[Filtered]"
    assert filtered.user.ip_address == "[Filtered]"
    assert filtered.contexts.runtime.ip_address == "[Filtered]"
  end

  test "preserves allowlisted Sentry enrichment structs while dropping unknown fields" do
    event_module = Module.concat([Sentry, Event])
    breadcrumb_module = Module.concat([Sentry, Interfaces, Breadcrumb])

    Code.ensure_loaded!(event_module)
    Code.ensure_loaded!(breadcrumb_module)

    event =
      struct(event_module,
        event_id: String.duplicate("a", 32),
        timestamp: "2026-04-26T00:00:00",
        server_name: "macbook.local",
        user: %{email: "person@example.com", ip_address: "127.0.0.1"},
        extra: %{orchard_request_id: "req_safe", unknown_payload: "secret prompt"},
        tags: %{orchard_app: "controller", unknown_tag: "secret tag"},
        breadcrumbs: [
          struct(breadcrumb_module,
            category: "orchard.auth",
            message: "auth.success",
            level: :info,
            data: %{
              auth_mechanism: "bearer",
              api_key: "secret",
              unknown_payload: "secret prompt"
            }
          )
        ]
      )

    filtered = SentryFilter.filter(event)
    [breadcrumb] = filtered.breadcrumbs

    assert filtered.__struct__ == event_module
    assert filtered.server_name == "[redacted]"
    assert filtered.user == %{}
    assert filtered.extra == %{orchard_request_id: "req_safe"}
    assert filtered.tags == %{orchard_app: "controller"}
    assert breadcrumb.__struct__ == breadcrumb_module
    assert breadcrumb.category == "orchard.auth"
    assert breadcrumb.message == "auth.success"
    assert breadcrumb.data == %{auth_mechanism: "bearer"}
    refute inspect(filtered) =~ "secret"
  end

  test "normalizes an absolute first-party stack frame to a repo-relative filename" do
    event = %{
      "exception" => [
        %{
          "stacktrace" => %{
            "frames" => [
              %{
                "module" => "Elixir.Orchard.SentryFilter",
                "function" => "filter/1",
                "lineno" => 17,
                "abs_path" =>
                  "/Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
                "filename" =>
                  "/Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
                "source_url" =>
                  "file:///Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
                "context_line" => "instructions = secret",
                "pre_context" => ["secret source"],
                "vars" => %{"token" => "secret"}
              }
            ]
          }
        }
      ]
    }

    filtered = SentryFilter.filter(event)
    [frame] = get_in(filtered, ["exception", Access.at(0), "stacktrace", "frames"])

    assert frame == %{
             "module" => "Elixir.Orchard.SentryFilter",
             "function" => "filter/1",
             "lineno" => 17,
             "filename" => "apps/orchard_shared/lib/orchard/sentry_filter.ex"
           }
  end

  test "filters unsafe stack-frame filenames" do
    filenames = [
      "lib/orchard/sentry_filter.ex",
      "apps/orchard_shared/lib/../secrets.ex",
      "apps/unknown/lib/private.ex",
      "_build/prod/lib/orchard_shared/ebin/Elixir.Orchard.beam",
      "file:///Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
      "/Users/demo/deps/sentry/lib/sentry/event.ex"
    ]

    event = %{stacktrace: %{frames: Enum.map(filenames, &%{filename: &1})}}
    filtered = SentryFilter.filter(event)

    assert Enum.all?(filtered.stacktrace.frames, &(&1.filename == "[Filtered]"))
    refute inspect(filtered) =~ "/Users/demo"
    refute inspect(filtered) =~ "../"
  end

  test "rebuilds Sentry stacktraces and bounds every retained frame field" do
    event = sentry_event(%{})
    [exception] = event.exception
    [frame] = exception.stacktrace.frames

    hostile_frame = %{
      frame
      | module: "Orchard.API.ResponsesController ISSUE114_FRAME_MODULE",
        function: "create/2\nISSUE114_FRAME_FUNCTION",
        lineno: 10_000_001,
        colno: -1,
        in_app: "yes"
    }

    event = %{
      event
      | exception: [
          %{exception | stacktrace: %{exception.stacktrace | frames: [hostile_frame]}}
        ]
    }

    payload = event |> serialized_filtered_envelope() |> envelope_event_payload()

    frame =
      get_in(payload, [
        "exception",
        Access.at(0),
        "stacktrace",
        "frames",
        Access.at(0)
      ])

    assert frame["module"] == "[Filtered]"
    assert frame["function"] == "[Filtered]"

    assert frame["filename"] ==
             "apps/orchard_controller/lib/orchard/api/responses_controller.ex"

    assert frame["lineno"] == nil
    assert frame["colno"] == nil
    assert frame["in_app"] == nil
    refute inspect(payload) =~ "ISSUE114_FRAME"
  end

  test "filters path-shaped frame functions and exception names before serialization" do
    event = sentry_event(%{})
    [exception] = event.exception
    [frame] = exception.stacktrace.frames

    hostile_exception = %{
      exception
      | type: :"/Users/ISSUE114_EXCEPTION_TYPE",
        module: :"/Users/ISSUE114_EXCEPTION_MODULE",
        stacktrace: %{
          exception.stacktrace
          | frames: [%{frame | function: "/Users/ISSUE114_FRAME_FUNCTION/1"}]
        }
    }

    payload =
      %{event | exception: [hostile_exception]}
      |> serialized_filtered_envelope()
      |> envelope_event_payload()

    [filtered_exception] = payload["exception"]
    [filtered_frame] = filtered_exception["stacktrace"]["frames"]

    assert filtered_exception["type"] == "[Filtered]"
    assert filtered_exception["module"] == "[Filtered]"
    assert filtered_frame["function"] == "[Filtered]"
    refute inspect(payload) =~ "/Users/ISSUE114"
  end

  test "removes unknown stacktrace keys before serialization" do
    event = sentry_event(%{})
    [exception] = event.exception

    event = %{
      event
      | exception: [
          %{
            exception
            | stacktrace: %{
                frames: exception.stacktrace.frames,
                notes: "ISSUE114_STACKTRACE_NOTES"
              }
          }
        ]
    }

    filtered = SentryFilter.filter(event)
    [filtered_exception] = filtered.exception

    assert Map.keys(filtered_exception.stacktrace) == [:frames]
    refute inspect(filtered) =~ "ISSUE114_STACKTRACE_NOTES"
    refute serialized_filtered_envelope(event) =~ "ISSUE114_STACKTRACE_NOTES"
  end

  test "removes request URL and query fields instead of retaining filtered structure" do
    event = %{
      request: %{
        url: "https://orchard.local/v1/responses?api_key=secret",
        raw_url: "https://orchard.local/v1/chat/completions?token=secret",
        request_url: "https://orchard.local/v1/responses?prompt=secret",
        query_string: "api_key=secret&token=secret&prompt=secret",
        method: "POST"
      }
    }

    assert SentryFilter.filter(event).request == %{method: "POST"}
  end

  test "removes atom-keyed request values when no method is present" do
    event = %{
      request: %{
        headers: %{
          "Authorization" => "Bearer atom-secret",
          "x-api-key" => "atom-api-key",
          :accept => "application/json"
        },
        payload: %{
          token: "token",
          safe_value: %{nested: "ok"}
        }
      }
    }

    assert SentryFilter.filter(event).request == %{}
  end

  test "serialized Responses API envelope excludes proprietary request and source values" do
    event =
      sentry_event(%{
        instructions: "ISSUE114_RESPONSES_INSTRUCTIONS",
        input: "ISSUE114_RESPONSES_INPUT",
        tools: [%{name: "ISSUE114_RESPONSES_TOOL"}],
        tool_choice: "required",
        metadata: %{customer: "ISSUE114_RESPONSES_CUSTOMER"}
      })

    envelope = serialized_filtered_envelope(event)
    payload = envelope_event_payload(envelope)

    assert payload["request"] == %{"method" => "POST"}

    assert payload["message"] == %{
             "formatted" => "[Filtered]",
             "message" => nil,
             "params" => nil
           }

    assert get_in(payload, ["exception", Access.at(0), "value"]) == "[Filtered]"
    assert payload["extra"] == %{"orchard_request_id" => "req_safe"}
    assert payload["tags"] == %{"orchard_app" => "controller"}
    assert payload["contexts"] in [nil, %{}]

    assert [breadcrumb] = payload["breadcrumbs"]
    assert breadcrumb["category"] == "orchard.request"
    assert breadcrumb["message"] == "request.validated"
    assert breadcrumb["data"] == %{"model_id" => "qwen"}

    assert get_in(payload, [
             "exception",
             Access.at(0),
             "stacktrace",
             "frames",
             Access.at(0),
             "filename"
           ]) ==
             "apps/orchard_controller/lib/orchard/api/responses_controller.ex"

    refute envelope =~ "ISSUE114_RESPONSES"
    refute envelope =~ "/Users/private-builder"
    refute envelope =~ "secret source line"
  end

  test "serialized Chat Completions envelope excludes unknown request fields" do
    event =
      sentry_event(%{
        messages: [%{role: "user", content: "ISSUE114_CHAT_MESSAGE"}],
        functions: [%{name: "ISSUE114_CHAT_FUNCTION"}],
        parallel_tool_calls: true,
        future_unknown_field: "ISSUE114_CHAT_FUTURE_FIELD"
      })

    envelope = serialized_filtered_envelope(event)

    assert envelope_event_payload(envelope)["request"] == %{"method" => "POST"}
    refute envelope =~ "ISSUE114_CHAT"
    refute envelope =~ "future_unknown_field"
  end

  test "Sentry event allowlist makes hostile allowed values wire-serializable" do
    event =
      sentry_event(%{})
      |> Map.put(:timestamp, "/Users/ISSUE114_ALLOWED_TIMESTAMP")
      |> Map.put(:release, "/Users/ISSUE114_ALLOWED_RELEASE")
      |> Map.put(:environment, "https://ISSUE114_ALLOWED_ENVIRONMENT")
      |> Map.put(:extra, %{
        orchard_anomaly: self(),
        orchard_event_count: 9_007_199_254_740_992,
        orchard_model_backend: :"ISSUE114_ATOM\nSECRET",
        orchard_model_id: "/Users/ISSUE114_ALLOWED_MODEL",
        orchard_request_id: "https://ISSUE114_ALLOWED_REQUEST",
        orchard_target_host_sanitized: "ISSUE114_ALLOWED_HOST.local",
        unknown_payload: fn -> :secret end
      })
      |> Map.put(:tags, %{
        orchard_app: {:bad, :component},
        orchard_surface: "/Users/ISSUE114_ALLOWED_SURFACE",
        unknown_tag: self()
      })
      |> Map.put(:breadcrumbs, [
        %Sentry.Interfaces.Breadcrumb{
          category: "orchard.request",
          message: "request.validated",
          level: :info,
          data: %{
            model_id: "/Users/ISSUE114_ALLOWED_BREADCRUMB_MODEL",
            target_host_sanitized: "ISSUE114_ALLOWED_BREADCRUMB_HOST.local"
          }
        }
      ])

    envelope = serialized_filtered_envelope(event)
    payload = envelope_event_payload(envelope)

    assert payload["release"] == "[Filtered]"
    assert payload["environment"] == "[Filtered]"

    assert payload["extra"] == %{
             "orchard_anomaly" => "[Filtered]",
             "orchard_event_count" => "[Filtered]",
             "orchard_model_backend" => "[Filtered]",
             "orchard_model_id" => "[Filtered]",
             "orchard_request_id" => "[Filtered]",
             "orchard_target_host_sanitized" => "[Filtered]"
           }

    assert payload["tags"] == %{
             "orchard_app" => "[Filtered]",
             "orchard_surface" => "[Filtered]"
           }

    assert [breadcrumb] = payload["breadcrumbs"]

    assert breadcrumb["data"] == %{
             "model_id" => "[Filtered]",
             "target_host_sanitized" => "[Filtered]"
           }

    refute envelope =~ "ISSUE114_ALLOWED"
    refute envelope =~ "unknown_payload"
    refute envelope =~ "unknown_tag"
  end

  defp sentry_event(request_data) do
    frame = %Sentry.Interfaces.Stacktrace.Frame{
      module: Orchard.API.ResponsesController,
      function: "create/2",
      filename:
        "/Users/private-builder/orchard/apps/orchard_controller/lib/orchard/api/responses_controller.ex",
      lineno: 24,
      context_line: "secret source line",
      pre_context: ["secret neighboring source"],
      vars: %{authorization: "Bearer secret"}
    }

    exception = %Sentry.Interfaces.Exception{
      type: "RuntimeError",
      value: "failed with ISSUE114_EXCEPTION_CONTEXT at /Users/private-builder/secret",
      stacktrace: %Sentry.Interfaces.Stacktrace{frames: [frame]}
    }

    %Sentry.Event{
      event_id: String.duplicate("a", 32),
      timestamp: "2026-07-30T00:00:00",
      environment: "test",
      message: %Sentry.Interfaces.Message{formatted: "ISSUE114_EVENT_MESSAGE"},
      exception: [exception],
      extra: %{
        orchard_request_id: "req_safe",
        unknown_payload: %{instructions: "ISSUE114_EXTRA_INSTRUCTIONS"}
      },
      tags: %{orchard_app: "controller", unknown_tag: "ISSUE114_UNKNOWN_TAG"},
      breadcrumbs: [
        %Sentry.Interfaces.Breadcrumb{
          category: "library.http",
          message: "ISSUE114_LIBRARY_BREADCRUMB",
          data: %{body: "ISSUE114_BREADCRUMB_BODY"}
        },
        %Sentry.Interfaces.Breadcrumb{
          category: "orchard.request",
          message: "request.validated",
          level: :info,
          data: %{model_id: "qwen", unknown_payload: "ISSUE114_BREADCRUMB_UNKNOWN"}
        }
      ],
      contexts: %{runtime: %{path: "/Users/private-builder/private"}},
      modules: %{"issue114_private_dependency" => "ISSUE114_MODULE_VERSION"},
      fingerprint: ["ISSUE114_FINGERPRINT"],
      threads: [
        %Sentry.Interfaces.Thread{
          id: "ISSUE114_THREAD_ID",
          name: "ISSUE114_THREAD_NAME",
          state: %{body: "ISSUE114_THREAD_STATE"}
        }
      ],
      attachments: [
        %Sentry.Attachment{
          filename: "ISSUE114_ATTACHMENT.txt",
          data: "ISSUE114_ATTACHMENT_DATA"
        }
      ],
      original_exception: RuntimeError.exception("ISSUE114_ORIGINAL_EXCEPTION"),
      request: %Sentry.Interfaces.Request{
        method: "POST",
        url: "https://orchard.local/v1/responses?token=ISSUE114_QUERY_SECRET",
        query_string: "token=ISSUE114_QUERY_SECRET",
        data: request_data,
        cookies: %{"session" => "ISSUE114_COOKIE_SECRET"},
        headers: %{"authorization" => "Bearer ISSUE114_HEADER_SECRET"},
        env: %{"REMOTE_ADDR" => "192.0.2.42", "SERVER_NAME" => "private-builder.local"}
      },
      server_name: "private-builder.local",
      user: %{username: "private-builder", ip_address: "192.0.2.42"}
    }
  end

  defp serialized_filtered_envelope(event) do
    filtered = SentryFilter.filter(event)
    {:ok, envelope} = filtered |> Sentry.Envelope.from_event() |> Sentry.Envelope.to_binary()
    envelope
  end

  defp envelope_event_payload(envelope) do
    [_envelope_header, _item_header, event_json | _rest] = String.split(envelope, "\n")
    Jason.decode!(event_json)
  end

  defmodule DummyEvent do
    defstruct [:request, :data, :metadata, :token, :secret, :abs_path, :safe]
  end

  test "filters generic struct input without sentry compile dependency" do
    event = %DummyEvent{
      request: %{"headers" => [{"authorization", "Bearer secret"}]},
      data: %{"prompt" => "secret prompt", "model" => "mlx-community/qwen2.5"},
      metadata: %{"tenant" => "demo"},
      token: "token-value",
      secret: "secret-value",
      abs_path: "/Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
      safe: "ok"
    }

    filtered = SentryFilter.filter(event)

    assert %DummyEvent{} = filtered
    assert filtered.request == %{}
    assert filtered.data["prompt"] == "[Filtered]"
    assert filtered.data["model"] == "mlx-community/qwen2.5"
    assert filtered.metadata == "[Filtered]"
    assert filtered.token == "[Filtered]"
    assert filtered.secret == "[Filtered]"
    assert filtered.abs_path == "[Filtered]"
    assert filtered.safe == "ok"
  end

  test "fails closed when hostile event shape breaks struct rebuilding" do
    event = %{
      __struct__: Does.Not.Exist,
      event_id: "event-1",
      token: "token-value",
      user: %{email: "person@example.com"},
      breadcrumbs: [%{data: %{prompt: "secret prompt"}}]
    }

    filtered = SentryFilter.filter(event)

    assert filtered.event_id == "event-1"
    assert filtered.message == "[Filtered]"
    assert filtered.server_name == "[redacted]"
    assert filtered.user == %{}
    refute inspect(filtered) =~ "token-value"
    refute inspect(filtered) =~ "person@example.com"
    refute inspect(filtered) =~ "secret prompt"
  end
end
