defmodule OrchardConsole.RedactionTest do
  use ExUnit.Case, async: true

  alias OrchardConsole.Redaction

  @hf_token "hf_1234567890abcdef"
  @jwt_secret "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig_nature-test"
  @opaque_secret "abcdef1234567890"
  @sk_secret "sk-test-abcdef1234567890"
  @slash_secret "abc/def+ghi="
  @bearer_secrets [@jwt_secret, @opaque_secret, @sk_secret, @slash_secret]

  describe "redact_secrets/1" do
    test "redacts bearer, HF token, and authorization key-value shapes" do
      text =
        "Authorization: Bearer #{@slash_secret}; " <>
          "authorization=\"Bearer #{@jwt_secret}\"; " <>
          "authorization: \"#{@sk_secret}\"; " <>
          "Authorization: Basic #{@opaque_secret}; " <>
          "Proxy-Authorization: Token #{@sk_secret}; " <>
          ~s(%{"authorization" => "Basic #{@jwt_secret}"}; ) <>
          ~s({"proxy-authorization", "Token #{@slash_secret}"}; ) <>
          "retry Bearer #{@opaque_secret}; token #{@hf_token}"

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "Authorization: Bearer [REDACTED]"
      assert redacted =~ "Authorization: [REDACTED]"
      assert redacted =~ "Proxy-Authorization: [REDACTED]"
      assert redacted =~ "Bearer [REDACTED]"
      assert redacted =~ "[REDACTED-HF-TOKEN]"
      refute redacted =~ "Basic abcdef"
      refute redacted =~ "Token sk-test"
      refute_secrets(redacted)
    end

    test "redacts generic sensitive key-value strings" do
      text =
        "api_key=plain-api-secret; " <>
          "client_secret: plain-client-secret; " <>
          "api key=plain-spaced-api-secret; " <>
          "client secret: plain-spaced-client-secret; " <>
          "private.key: plain-dotted-private-secret; " <>
          "access token: plain-spaced-access-secret; " <>
          "password: \"plain-password-secret\"; " <>
          ~s(%{token: "plain-token-secret"}; ) <>
          ~s(%{"accessToken" => "plain-access-secret"}; ) <>
          ~s({:github_token, "plain-github-secret"})

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "api_key=[REDACTED]"
      assert redacted =~ "client_secret: [REDACTED]"
      assert redacted =~ "api key=[REDACTED]"
      assert redacted =~ "client secret: [REDACTED]"
      assert redacted =~ "private.key: [REDACTED]"
      assert redacted =~ "access token: [REDACTED]"
      assert redacted =~ "password: \"[REDACTED]\""
      assert redacted =~ ~s(token: "[REDACTED]")
      assert redacted =~ ~s("accessToken" => "[REDACTED]")
      assert redacted =~ ~s(:github_token, "[REDACTED]")
      refute redacted =~ "plain-api-secret"
      refute redacted =~ "plain-client-secret"
      refute redacted =~ "plain-spaced-api-secret"
      refute redacted =~ "plain-spaced-client-secret"
      refute redacted =~ "plain-dotted-private-secret"
      refute redacted =~ "plain-spaced-access-secret"
      refute redacted =~ "plain-password-secret"
      refute redacted =~ "plain-token-secret"
      refute redacted =~ "plain-access-secret"
      refute redacted =~ "plain-github-secret"
    end

    test "redacts bracketed sensitive key-value strings" do
      text =
        ~s(access_token=["plain-access-secret"]; ) <>
          "token: [plain-token-secret]; " <>
          ~s(%{api_key: ["plain-api-secret"]})

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "access_token=[REDACTED]"
      assert redacted =~ "token: [REDACTED]"
      assert redacted =~ "api_key: [REDACTED]"
      refute redacted =~ "plain-access-secret"
      refute redacted =~ "plain-token-secret"
      refute redacted =~ "plain-api-secret"
    end

    test "redacts nested sensitive keys inside non-sensitive bracketed containers" do
      text = "details: [api_key: [plain-api-secret], tokenizer_config: missing]"

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "details: ["
      assert redacted =~ "api_key: [REDACTED]"
      assert redacted =~ "tokenizer_config: missing"
      refute redacted =~ "plain-api-secret"
    end

    test "redacts multiline bracketed sensitive key-value strings" do
      text = "api_key: [plain-api-secret\nmore]; access_token=[plain-access-secret\nmore]"

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "api_key: [REDACTED]"
      assert redacted =~ "access_token=[REDACTED]"
      refute redacted =~ "plain-api-secret"
      refute redacted =~ "plain-access-secret"
      refute redacted =~ "more]"
    end

    test "redacts open or long bracketed sensitive key-value strings" do
      open_text = "api_key: [plain-open-secret\n" <> String.duplicate("x", 5_000)
      late_close_text = "token: [plain-late-secret" <> String.duplicate("y", 4_200) <> "]"

      open_redacted = Redaction.redact_secrets(open_text)
      late_close_redacted = Redaction.redact_secrets(late_close_text)

      assert open_redacted =~ "api_key: [REDACTED]"
      assert late_close_redacted =~ "token: [REDACTED]"
      refute open_redacted =~ "plain-open-secret"
      refute late_close_redacted =~ "plain-late-secret"
    end

    test "drops long bracketed sensitive value tails beyond the scan window" do
      tail_secret = "plain-tail-secret"
      text = "api_key: [" <> String.duplicate("x", 4_200) <> tail_secret <> "]"

      redacted = Redaction.redact_secrets(text)

      assert redacted == "api_key: [REDACTED]"
      refute redacted =~ tail_secret
    end

    test "preserves benign bearer prose" do
      assert Redaction.redact_secrets("Bearer authentication is required") ==
               "Bearer authentication is required"
    end

    test "preserves tokenizer and tokenization diagnostics while redacting token keys" do
      text =
        "tokenizer_config: missing; tokenization=failed; tokenizer: qwen; " <>
          "token=plain-token-secret; access_token: plain-access-secret"

      redacted = Redaction.redact_secrets(text)

      assert redacted =~ "tokenizer_config: missing"
      assert redacted =~ "tokenization=failed"
      assert redacted =~ "tokenizer: qwen"
      assert redacted =~ "token=[REDACTED]"
      assert redacted =~ "access_token: [REDACTED]"
      refute redacted =~ "plain-token-secret"
      refute redacted =~ "plain-access-secret"
    end

    test "does not return invalid binaries containing tokens unchanged" do
      invalid = <<255, "Bearer #{@opaque_secret}; #{@hf_token}">>

      redacted = Redaction.redact_secrets(invalid)

      assert redacted == "[REDACTED-BINARY]"
      refute redacted == invalid
      refute redacted =~ "66, 101, 97, 114, 101, 114"
      refute redacted =~ "104, 102, 95"
      refute_secrets(redacted)
    end
  end

  describe "safe_inspect/1" do
    test "redacts binaries before inspect truncation and again after slicing" do
      boundary_bearer = String.duplicate("a", 1012) <> " Bearer #{@opaque_secret}"
      boundary_hf = String.duplicate("b", 1018) <> " #{@hf_token}"

      redacted = Redaction.safe_inspect(%{bearer: boundary_bearer, hf: boundary_hf})

      refute redacted =~ "Bearer abc"
      refute redacted =~ "hf_"
      refute_secrets(redacted)
      assert String.length(redacted) <= 4096
    end

    test "does not leak partial bearer tokens at pre-inspection truncation boundary" do
      term = String.duplicate("a", 1_140) <> " Bearer #{@opaque_secret}"

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED"
      refute redacted =~ "Bearer abc"
      refute redacted =~ "abcdef"
      refute_secrets(redacted)
    end

    test "bounds after final safe_inspect redaction" do
      term = String.duplicate("a", 4_078) <> " #{@hf_token}"

      redacted = Redaction.safe_inspect(term)

      assert String.length(redacted) <= 4096
      refute redacted =~ @hf_token
    end

    test "redacts textual non-bearer authorization values" do
      redacted =
        Redaction.safe_inspect(
          "Authorization: Basic #{@opaque_secret}; Proxy-Authorization: Token #{@sk_secret}"
        )

      assert redacted =~ "Authorization: [REDACTED]"
      assert redacted =~ "Proxy-Authorization: [REDACTED]"
      refute redacted =~ "Basic abcdef"
      refute redacted =~ "Token sk-test"
      refute_secrets(redacted)
    end

    test "redacts common nested containers and authorization keys" do
      term = %{
        headers: [authorization: "Bearer #{@slash_secret}"],
        string_headers: %{
          "authorization" => @opaque_secret,
          "Proxy-Authorization" => "Basic #{@sk_secret}"
        },
        header_pairs: [
          {"Authorization", @jwt_secret},
          {"proxy-authorization", "Basic #{@slash_secret}"}
        ],
        tuple: {:token, "Bearer #{@jwt_secret}"},
        list: ["Bearer #{@sk_secret}", @hf_token]
      }

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "Bearer [REDACTED]"
      assert redacted =~ "[REDACTED-HF-TOKEN]"
      assert redacted =~ "[REDACTED]"
      refute_secrets(redacted)
      refute redacted =~ "Basic sk-test"
      refute redacted =~ "Basic abc/def"
    end

    test "redacts common sensitive key values" do
      term = %{
        "api_key" => "plain-api-secret",
        "apiKey" => "plain-camel-api-secret",
        "accessToken" => "plain-camel-access-secret",
        "x-api-key" => "plain-x-api-secret",
        "session_token" => "plain-session-secret",
        "id_token" => "plain-id-secret",
        "auth_token" => "plain-auth-secret",
        "bearer_token" => "plain-bearer-secret",
        "github_token" => "plain-github-secret",
        ~c"access_token" => "plain-access-secret",
        token: "plain-token-secret",
        nested: [client_secret: "plain-client-secret", hf_token: "plain-hf-secret"]
      }

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED]"
      refute redacted =~ "plain-token-secret"
      refute redacted =~ "plain-api-secret"
      refute redacted =~ "plain-camel-api-secret"
      refute redacted =~ "plain-camel-access-secret"
      refute redacted =~ "plain-x-api-secret"
      refute redacted =~ "plain-session-secret"
      refute redacted =~ "plain-id-secret"
      refute redacted =~ "plain-auth-secret"
      refute redacted =~ "plain-bearer-secret"
      refute redacted =~ "plain-github-secret"
      refute redacted =~ "plain-access-secret"
      refute redacted =~ "plain-client-secret"
      refute redacted =~ "plain-hf-secret"
    end

    test "sanitizes secret-bearing and invalid binary keys in inspected terms" do
      term = %{
        "Bearer #{@opaque_secret}" => "value",
        <<255, "#{@hf_token}">> => "plain-invalid-key-secret"
      }

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "Bearer [REDACTED]"
      assert redacted =~ "[REDACTED-BINARY]"
      refute redacted =~ "plain-invalid-key-secret"
      refute redacted =~ "Bearer abc"
      refute redacted =~ "hf_"
      refute_secrets(redacted)
    end

    test "redacts inspect-style authorization values after depth cutoff" do
      term =
        Enum.reduce(1..10, %{"authorization" => "Basic #{@opaque_secret}"}, fn _idx, acc ->
          [acc]
        end)

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED-DEPTH-LIMIT]"
      refute redacted =~ "Basic abcdef"
      refute_secrets(redacted)
    end

    test "does not leak boundary-crossing secrets below depth cutoff" do
      secret = String.duplicate("a", 1012) <> " Bearer #{@opaque_secret}"
      term = Enum.reduce(1..10, secret, fn _idx, acc -> [acc] end)

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED-DEPTH-LIMIT]"
      refute redacted =~ "Bearer abc"
      refute_secrets(redacted)
    end

    test "redacts printable charlist authorization keys" do
      term = %{
        ~c"authorization" => "Basic #{@opaque_secret}",
        headers: [{~c"proxy-authorization", "Token #{@sk_secret}"}]
      }

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED]"
      refute redacted =~ "Basic abcdef"
      refute redacted =~ "Token sk-test"
      refute_secrets(redacted)
    end

    test "handles improper lists defensively" do
      term = [{:safe, "value"} | {:authorization, "Basic #{@opaque_secret}"}]

      redacted = Redaction.safe_inspect(term)

      assert redacted =~ "[REDACTED-IMPROPER-LIST]"
      refute redacted =~ "Basic abcdef"
      refute_secrets(redacted)
    end

    test "handles structs without crashing" do
      redacted = Redaction.safe_inspect(%RuntimeError{message: "boom Bearer #{@opaque_secret}"})

      assert redacted =~ "Bearer [REDACTED]"
      refute_secrets(redacted)
    end
  end

  describe "format_exception/3" do
    test "redacts exception messages" do
      formatted =
        try do
          raise RuntimeError,
                "boom Authorization: Bearer #{@slash_secret}; #{@hf_token}; Bearer #{@jwt_secret}"
        rescue
          exception -> Redaction.format_exception(:error, exception, __STACKTRACE__)
        end

      assert formatted =~ "Authorization: Bearer [REDACTED]"
      assert formatted =~ "[REDACTED-HF-TOKEN]"
      refute_secrets(formatted)
    end

    test "bounds after final exception redaction" do
      formatted =
        try do
          raise RuntimeError, String.duplicate("a", 4_078) <> " #{@hf_token}"
        rescue
          exception -> Redaction.format_exception(:error, exception, __STACKTRACE__)
        end

      assert String.length(formatted) <= 4096
      refute formatted =~ @hf_token
    end

    test "bounds exception input before redaction and masks boundary partial bearer tokens" do
      formatted =
        try do
          raise RuntimeError, String.duplicate("a", 4_058) <> " Bearer #{@opaque_secret}"
        rescue
          exception -> Redaction.format_exception(:error, exception, __STACKTRACE__)
        end

      assert String.length(formatted) <= 4096
      assert formatted =~ "[REDACTED"
      refute formatted =~ "Bearer abc"
      refute formatted =~ "abcdef"
      refute_secrets(formatted)
    end

    test "bounds stacktrace entries before exception formatting" do
      stacktrace = [
        {__MODULE__, :large_arg, [String.duplicate("a", 4_058) <> " Bearer #{@opaque_secret}"],
         [file: "redaction_test.exs", line: 1]}
      ]

      formatted = Redaction.format_exception(:error, %RuntimeError{message: "boom"}, stacktrace)

      assert String.length(formatted) <= 4096
      refute formatted =~ "Bearer abc"
      refute formatted =~ "abcdef"
      refute_secrets(formatted)
    end

    test "redacts generic sensitive key-value exception messages" do
      formatted =
        try do
          raise RuntimeError,
                "boom api_key=plain-api-secret api key=plain-spaced-api-secret " <>
                  "client_secret: plain-client-secret client secret: plain-spaced-client-secret " <>
                  "private.key: plain-dotted-private-secret " <>
                  ~s(password: "plain-password-secret" %{token: "plain-token-secret"})
        rescue
          exception -> Redaction.format_exception(:error, exception, __STACKTRACE__)
        end

      assert formatted =~ "api_key=[REDACTED]"
      assert formatted =~ "client_secret: [REDACTED]"
      assert formatted =~ "api key=[REDACTED]"
      assert formatted =~ "client secret: [REDACTED]"
      assert formatted =~ "private.key: [REDACTED]"
      assert formatted =~ "password: \"[REDACTED]\""
      assert formatted =~ ~s(token: "[REDACTED]")
      refute formatted =~ "plain-api-secret"
      refute formatted =~ "plain-client-secret"
      refute formatted =~ "plain-spaced-api-secret"
      refute formatted =~ "plain-spaced-client-secret"
      refute formatted =~ "plain-dotted-private-secret"
      refute formatted =~ "plain-password-secret"
      refute formatted =~ "plain-token-secret"
    end
  end

  describe "sanitize_result/1" do
    test "redacts secret-bearing atom-key message fields in error tuples" do
      result =
        Redaction.sanitize_result(
          {:error,
           %{
             status: :error,
             code: "hf_error",
             message: "failed Bearer #{@jwt_secret}; #{@hf_token}"
           }}
        )

      assert {:error, error} = result
      assert error.message =~ "Bearer [REDACTED]"
      assert error.message =~ "[REDACTED-HF-TOKEN]"
      refute_secrets(error.message)
    end

    test "preserves non-error results" do
      result = {:ok, %{message: "Bearer #{@opaque_secret}"}}
      assert Redaction.sanitize_result(result) == result
    end
  end

  describe "sanitize_error_map/1" do
    test "redacts secret-bearing string-key message fields" do
      error = %{
        "message" => "failed Bearer #{@sk_secret}; #{@hf_token}",
        status: :error,
        code: "hf_unauthorized"
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.status == :error
      assert redacted.code == "hf_unauthorized"
      assert redacted["message"] =~ "Bearer [REDACTED]"
      assert redacted["message"] =~ "[REDACTED-HF-TOKEN]"
      refute_secrets(redacted["message"])
    end

    test "sanitizes top-level structs as error maps" do
      error = %RuntimeError{message: "failed Bearer #{@opaque_secret}; #{@hf_token}"}

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message =~ "Bearer [REDACTED]"
      assert redacted.message =~ "[REDACTED-HF-TOKEN]"
      refute_secrets(redacted.message)
    end

    test "redacts generic sensitive key-value message fields" do
      error = %{
        message:
          "failed api_key=plain-api-secret api key=plain-spaced-api-secret " <>
            "client_secret: plain-client-secret client secret: plain-spaced-client-secret " <>
            "access token: plain-spaced-access-secret " <>
            ~s(password: "plain-password-secret" %{token: "plain-token-secret"})
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message =~ "api_key=[REDACTED]"
      assert redacted.message =~ "client_secret: [REDACTED]"
      assert redacted.message =~ "api key=[REDACTED]"
      assert redacted.message =~ "client secret: [REDACTED]"
      assert redacted.message =~ "access token: [REDACTED]"
      assert redacted.message =~ "password: \"[REDACTED]\""
      assert redacted.message =~ ~s(token: "[REDACTED]")
      refute redacted.message =~ "plain-api-secret"
      refute redacted.message =~ "plain-client-secret"
      refute redacted.message =~ "plain-spaced-api-secret"
      refute redacted.message =~ "plain-spaced-client-secret"
      refute redacted.message =~ "plain-spaced-access-secret"
      refute redacted.message =~ "plain-password-secret"
      refute redacted.message =~ "plain-token-secret"
    end

    test "redacts invalid binary messages containing tokens" do
      error = %{message: <<255, "Bearer #{@opaque_secret}; #{@hf_token}">>}

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message == "[REDACTED-BINARY]"
      refute redacted.message =~ "66, 101, 97, 114, 101, 114"
      refute redacted.message =~ "104, 102, 95"
      refute_secrets(redacted.message)
    end

    test "bounds non-secret visible messages" do
      long_message = String.duplicate("downloader client unavailable. ", 300)
      error = %{message: long_message}

      redacted = Redaction.sanitize_error_map(error)

      assert String.length(redacted.message) == 4096
      assert redacted.message == String.slice(long_message, 0, 4096)
    end

    test "bounds after final visible-message redaction" do
      error = %{message: String.duplicate("a", 4_078) <> " #{@hf_token}"}

      redacted = Redaction.sanitize_error_map(error)

      assert String.length(redacted.message) <= 4096
      refute redacted.message =~ @hf_token
    end

    test "bounds visible message input before redaction and masks boundary partial bearer tokens" do
      error = %{message: String.duplicate("a", 4_090) <> " Bearer #{@opaque_secret}"}

      redacted = Redaction.sanitize_error_map(error)

      assert String.length(redacted.message) <= 4096
      assert redacted.message =~ "[REDACTED"
      refute redacted.message =~ "Bearer abc"
      refute redacted.message =~ "abcdef"
      refute_secrets(redacted.message)
    end

    test "bounds recursive list and map sanitization" do
      list = Enum.map(1..25, fn idx -> "item-#{idx}" end)
      map = Map.new(1..25, fn idx -> {"key-#{idx}", "value-#{idx}"} end)

      redacted = Redaction.sanitize_error_map(%{details: %{list: list, map: map}})

      assert length(redacted.details.list) <= 20
      assert map_size(redacted.details.map) <= 20
    end

    test "bounds large printable charlist values and keys" do
      value = String.to_charlist(String.duplicate("v", 5_000))
      key = String.to_charlist(String.duplicate("k", 5_000))

      redacted = Redaction.sanitize_error_map(Map.put(%{message: value}, key, "value"))
      keys = Map.keys(redacted)

      assert is_binary(redacted.message)
      assert String.length(redacted.message) == 4096
      assert Enum.any?(keys, &(is_binary(&1) and String.length(&1) == 4096))
    end

    test "preserves top-level error contract keys when bounding metadata" do
      metadata = Map.new(1..30, fn idx -> {"metadata-#{idx}", "value-#{idx}"} end)

      error =
        Map.merge(metadata, %{
          message: "failed Bearer #{@opaque_secret}",
          code: "hf_error",
          status: :error
        })

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message =~ "Bearer [REDACTED]"
      assert redacted.code == "hf_error"
      assert redacted.status == :error
      assert map_size(redacted) <= 20
      refute_secrets(inspect(redacted))
    end

    test "redacts printable charlist message and nested values containing tokens" do
      error = %{
        message: ~c"failed Bearer #{@opaque_secret}; #{@hf_token}",
        details: [reason: ~c"Authorization: Bearer #{@slash_secret}"]
      }

      redacted = Redaction.sanitize_error_map(error)

      assert is_binary(redacted.message)
      assert redacted.message =~ "Bearer [REDACTED]"
      assert redacted.message =~ "[REDACTED-HF-TOKEN]"
      assert redacted.details == [reason: "Authorization: Bearer [REDACTED]"]
      refute_secrets(redacted.message)
      refute_secrets(inspect(redacted.details))
    end

    test "sanitizes public metadata values without redacting normal codes" do
      error = %{
        "code" => "hf_abcdefghij",
        "status" => "hf_unauthorized",
        code: "Bearer #{@opaque_secret}",
        status: %{authorization: "Basic #{@sk_secret}"}
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.code =~ "Bearer [REDACTED]"
      assert redacted.status.authorization == "[REDACTED]"
      assert redacted["code"] == "[REDACTED-HF-TOKEN]"
      assert redacted["status"] == "hf_unauthorized"
      refute_secrets(inspect(redacted))
    end

    test "preserves known public HF error metadata codes" do
      error = %{code: "hf_unavailable", status: "hf_unauthorized"}

      assert Redaction.sanitize_error_map(error) == error
    end

    test "redacts nested authorization headers outside message fields" do
      error = %{
        "headers" => [authorization: "Bearer #{@jwt_secret}"],
        status: :error,
        message: "failed",
        details: %{
          headers: %{
            "authorization" => "Basic #{@opaque_secret}",
            "Proxy-Authorization" => "Token #{@sk_secret}",
            "x-request-id" => "request-123"
          },
          header_pairs: [{~c"authorization", "Basic #{@slash_secret}"}]
        }
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message == "failed"
      assert redacted.details.headers["authorization"] == "[REDACTED]"
      assert redacted.details.headers["Proxy-Authorization"] == "[REDACTED]"
      assert redacted.details.headers["x-request-id"] == "request-123"
      assert redacted.details.header_pairs == [{~c"authorization", "[REDACTED]"}]
      assert redacted["headers"] == [authorization: "[REDACTED]"]
      refute_secrets(inspect(redacted))
    end

    test "redacts common sensitive keys in error maps" do
      error = %{
        details: %{
          "api_key" => "plain-api-secret",
          "apiKey" => "plain-camel-api-secret",
          "accessToken" => "plain-camel-access-secret",
          "x-api-key" => "plain-x-api-secret",
          "session_token" => "plain-session-secret",
          "id_token" => "plain-id-secret",
          "auth_token" => "plain-auth-secret",
          "bearer_token" => "plain-bearer-secret",
          "github_token" => "plain-github-secret",
          ~c"access_token" => "plain-access-secret",
          token: "plain-token-secret",
          nested: [client_secret: "plain-client-secret", hf_token: "plain-hf-secret"]
        }
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.details.token == "[REDACTED]"
      assert redacted.details["api_key"] == "[REDACTED]"
      assert redacted.details["apiKey"] == "[REDACTED]"
      assert redacted.details["accessToken"] == "[REDACTED]"
      assert redacted.details["x-api-key"] == "[REDACTED]"
      assert redacted.details["session_token"] == "[REDACTED]"
      assert redacted.details["id_token"] == "[REDACTED]"
      assert redacted.details["auth_token"] == "[REDACTED]"
      assert redacted.details["bearer_token"] == "[REDACTED]"
      assert redacted.details["github_token"] == "[REDACTED]"
      assert redacted.details[~c"access_token"] == "[REDACTED]"
      assert redacted.details.nested == [client_secret: "[REDACTED]", hf_token: "[REDACTED]"]
      refute inspect(redacted) =~ "plain-token-secret"
      refute inspect(redacted) =~ "plain-api-secret"
      refute inspect(redacted) =~ "plain-camel-api-secret"
      refute inspect(redacted) =~ "plain-camel-access-secret"
      refute inspect(redacted) =~ "plain-x-api-secret"
      refute inspect(redacted) =~ "plain-session-secret"
      refute inspect(redacted) =~ "plain-id-secret"
      refute inspect(redacted) =~ "plain-auth-secret"
      refute inspect(redacted) =~ "plain-bearer-secret"
      refute inspect(redacted) =~ "plain-github-secret"
      refute inspect(redacted) =~ "plain-access-secret"
      refute inspect(redacted) =~ "plain-client-secret"
      refute inspect(redacted) =~ "plain-hf-secret"
    end

    test "sanitizes secret-bearing and invalid binary keys in error maps" do
      error = %{
        "Bearer #{@opaque_secret}" => "value",
        <<255, "#{@hf_token}">> => "plain-invalid-key-secret"
      }

      redacted = Redaction.sanitize_error_map(error)
      keys = Map.keys(redacted)

      assert "Bearer [REDACTED]" in keys
      assert "[REDACTED-BINARY]" in keys
      assert redacted["[REDACTED-BINARY]"] == "[REDACTED]"
      refute inspect(redacted) =~ "plain-invalid-key-secret"
      refute inspect(redacted) =~ "Bearer abc"
      refute inspect(redacted) =~ "hf_"
      refute_secrets(inspect(redacted))
    end

    test "sanitizes tuple, list, and charlist keys recursively in error maps" do
      error = %{
        {"Bearer #{@opaque_secret}", :metadata} => "tuple-value",
        [~c"Bearer #{@slash_secret}", "#{@hf_token}"] => "list-value",
        ~c"Bearer #{@sk_secret}" => "charlist-value"
      }

      redacted = Redaction.sanitize_error_map(error)
      keys = Map.keys(redacted)

      assert {"Bearer [REDACTED]", :metadata} in keys
      assert ["Bearer [REDACTED]", "[REDACTED-HF-TOKEN]"] in keys
      assert "Bearer [REDACTED]" in keys
      assert redacted[{"Bearer [REDACTED]", :metadata}] == "tuple-value"
      assert redacted[["Bearer [REDACTED]", "[REDACTED-HF-TOKEN]"]] == "list-value"
      assert redacted["Bearer [REDACTED]"] == "charlist-value"
      refute_secrets(inspect(redacted))
    end

    test "preserves benign bearer prose" do
      error = %{message: "Bearer authentication is required"}

      assert Redaction.sanitize_error_map(error) == error
    end

    test "recursively sanitizes non-binary message fields" do
      error = %{
        :message => %{authorization: "Basic #{@opaque_secret}"},
        "message" => {:token, "Bearer #{@sk_secret}"}
      }

      redacted = Redaction.sanitize_error_map(error)

      assert redacted.message.authorization == "[REDACTED]"
      assert redacted["message"] == {:token, "[REDACTED]"}
      refute_secrets(inspect(redacted))
    end
  end

  defp refute_secrets(text) do
    Enum.each(@bearer_secrets, fn secret -> refute text =~ secret end)
    refute text =~ @hf_token
  end
end
