defmodule Orchard.SentryFilterTest do
  use ExUnit.Case, async: true

  alias Orchard.SentryFilter

  test "scrubs required request headers" do
    event = %{
      "request" => %{
        "headers" => [
          {"authorization", "Bearer secret"},
          {"cookie", "session=value"},
          {"x-api-key", "apikey"},
          {"accept", "application/json"}
        ]
      }
    }

    assert %{"request" => %{"headers" => []}} = SentryFilter.filter(event)
  end

  test "scrubs required request headers from list-of-map format" do
    event = %{
      "request" => %{
        "headers" => [
          %{"name" => "authorization", "value" => "Bearer secret"},
          %{"name" => "cookie", "value" => "session=value"},
          %{"name" => "x-api-key", "value" => "apikey"},
          %{"name" => "accept", "value" => "application/json"}
        ]
      }
    }

    assert %{"request" => %{"headers" => []}} = SentryFilter.filter(event)
  end

  test "scrubs required body and token fields" do
    event = %{
      "request" => %{
        "data" => %{
          "messages" => [%{"role" => "user", "content" => "hello"}],
          "content" => "body content",
          "prompt" => "prompt text",
          "input" => "input text",
          "rendered_prompt" => "rendered prompt",
          "metadata" => %{"tenant" => "demo"},
          "token" => "token-value",
          "api_key" => "api-key-value",
          "x-api-key" => "header-style-api-key",
          "secret" => "secret-value",
          "secret_hash" => "hash-value",
          "password" => "password-value",
          "model" => "mlx-community/qwen2.5"
        }
      }
    }

    filtered = SentryFilter.filter(event)

    data = get_in(filtered, ["request", "data"])

    assert data["messages"] == "[Filtered]"
    assert data["content"] == "[Filtered]"
    assert data["prompt"] == "[Filtered]"
    assert data["input"] == "[Filtered]"
    assert data["rendered_prompt"] == "[Filtered]"
    assert data["metadata"] == "[Filtered]"
    assert data["token"] == "[Filtered]"
    assert data["api_key"] == "[Filtered]"
    assert data["x-api-key"] == "[Filtered]"
    assert data["secret"] == "[Filtered]"
    assert data["secret_hash"] == "[Filtered]"
    assert data["password"] == "[Filtered]"
    assert data["model"] == "mlx-community/qwen2.5"
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

  test "preserves Sentry event and breadcrumb structs while scrubbing unsafe fields" do
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
        breadcrumbs: [
          struct(breadcrumb_module,
            category: "orchard.auth",
            data: %{api_key: "secret", safe: %{model_id: "qwen"}}
          )
        ]
      )

    filtered = SentryFilter.filter(event)
    [breadcrumb] = filtered.breadcrumbs

    assert filtered.__struct__ == event_module
    assert filtered.server_name == "[redacted]"
    assert filtered.user.email == "[Filtered]"
    assert filtered.user.ip_address == "[Filtered]"
    assert breadcrumb.__struct__ == breadcrumb_module
    assert breadcrumb.data.api_key == "[Filtered]"
    assert breadcrumb.data.safe.model_id == "qwen"
  end

  test "scrubs stacktrace path-bearing fields" do
    event = %{
      "exception" => [
        %{
          "stacktrace" => %{
            "frames" => [
              %{
                "abs_path" =>
                  "/Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex",
                "filename" => "lib/orchard/sentry_filter.ex",
                "source_url" =>
                  "file:///Users/demo/orchard/apps/orchard_shared/lib/orchard/sentry_filter.ex"
              }
            ]
          }
        }
      ]
    }

    filtered = SentryFilter.filter(event)
    [frame] = get_in(filtered, ["exception", Access.at(0), "stacktrace", "frames"])

    assert frame["abs_path"] == "[Filtered]"
    assert frame["filename"] == "[Filtered]"
    assert frame["source_url"] == "[Filtered]"
  end

  test "scrubs request URL and query fields" do
    event = %{
      request: %{
        url: "https://orchard.local/v1/responses?api_key=secret",
        raw_url: "https://orchard.local/v1/chat/completions?token=secret",
        request_url: "https://orchard.local/v1/responses?prompt=secret",
        query_string: "api_key=secret&token=secret&prompt=secret",
        method: "POST"
      }
    }

    filtered = SentryFilter.filter(event)

    assert filtered.request.url == "[Filtered]"
    assert filtered.request.raw_url == "[Filtered]"
    assert filtered.request.request_url == "[Filtered]"
    assert filtered.request.query_string == "[Filtered]"
    assert filtered.request.method == "POST"
  end

  test "supports atom keys and preserves unrelated values" do
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

    filtered = SentryFilter.filter(event)

    assert filtered.request.headers == %{
             "Authorization" => "[Filtered]",
             "x-api-key" => "[Filtered]",
             accept: "[Filtered]"
           }

    assert get_in(filtered, [:request, :payload, :token]) == "[Filtered]"
    assert get_in(filtered, [:request, :payload, :safe_value, :nested]) == "ok"
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
    assert filtered.request["headers"] == []
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
