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

    assert %{
             "request" => %{
               "headers" => [
                 {"authorization", "[Filtered]"},
                 {"cookie", "[Filtered]"},
                 {"x-api-key", "[Filtered]"},
                 {"accept", "application/json"}
               ]
             }
           } = SentryFilter.filter(event)
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

    assert %{
             "request" => %{
               "headers" => [
                 %{"name" => "authorization", "value" => "[Filtered]"},
                 %{"name" => "cookie", "value" => "[Filtered]"},
                 %{"name" => "x-api-key", "value" => "[Filtered]"},
                 %{"name" => "accept", "value" => "application/json"}
               ]
             }
           } = SentryFilter.filter(event)
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
    assert data["secret"] == "[Filtered]"
    assert data["secret_hash"] == "[Filtered]"
    assert data["password"] == "[Filtered]"
    assert data["model"] == "mlx-community/qwen2.5"
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

    assert get_in(filtered, [:request, :headers, "Authorization"]) == "[Filtered]"
    assert get_in(filtered, [:request, :headers, "x-api-key"]) == "[Filtered]"
    assert get_in(filtered, [:request, :headers, :accept]) == "application/json"
    assert get_in(filtered, [:request, :payload, :token]) == "[Filtered]"
    assert get_in(filtered, [:request, :payload, :safe_value, :nested]) == "ok"
  end
end
