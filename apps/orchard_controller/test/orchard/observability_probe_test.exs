Code.require_file("../../../../scripts/support/observability_probe.exs", __DIR__)

defmodule Orchard.ObservabilityProbeTest do
  use Orchard.DataCase, async: false

  import ExUnit.CaptureLog
  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.ObservabilityProbe
  alias Orchard.Requests

  @valid_config %{
    "schema_version" => 1,
    "probe_id" => "probe_550e8400-e29b-41d4-a716-446655440000",
    "endpoint_kind" => "responses",
    "endpoint_url" => "http://127.0.0.1:4000/v1/responses",
    "stream" => true,
    "model_env_var" => "ORCHARD_OBSERVABILITY_PROBE_MODEL",
    "credential_env_var" => "ORCHARD_OBSERVABILITY_PROBE_API_KEY",
    "connect_timeout_ms" => 5_000,
    "request_timeout_ms" => 120_000,
    "terminal_validation" => "http_only",
    "cadence_notes" => "test cadence"
  }

  @valid_result %{
    "schema_version" => 1,
    "probe_id" => "probe_550e8400-e29b-41d4-a716-446655440000",
    "started_at" => "2026-08-03T01:02:03.000Z",
    "finished_at" => "2026-08-03T01:02:04.000Z",
    "outcome" => "pass",
    "classification" => "completed",
    "public_request_id" => "resp_550e8400-e29b-41d4-a716-446655440000",
    "terminal_count" => 1,
    "terminal_state" => "completed",
    "http_status" => 200,
    "latency_ms" => 1_000
  }

  describe "versioned config schema" do
    test "accepts the exact Phase 0 schema" do
      assert {:ok, @valid_config} = ObservabilityProbe.validate_config(@valid_config)
    end

    test "rejects a different version, endpoint, streaming mode, or extra field" do
      invalid_configs = [
        Map.put(@valid_config, "schema_version", 2),
        Map.put(@valid_config, "endpoint_kind", "chat_completions"),
        Map.put(@valid_config, "stream", false),
        Map.put(@valid_config, "endpoint_url", "http://127.0.0.1:4000/v1/chat/completions"),
        Map.put(@valid_config, "api_key", "not-allowed")
      ]

      assert Enum.all?(invalid_configs, fn config ->
               match?({:error, {:invalid, _reason}}, ObservabilityProbe.validate_config(config))
             end)
    end

    test "accepts only environment variable names for model and credential" do
      refute match?(
               {:ok, _config},
               @valid_config
               |> Map.put("model_env_var", "mlx-community/model")
               |> ObservabilityProbe.validate_config()
             )

      refute match?(
               {:ok, _config},
               @valid_config
               |> Map.put("credential_env_var", "sk-secret-value")
               |> ObservabilityProbe.validate_config()
             )
    end
  end

  describe "safe result schema" do
    test "accepts and encodes only the allowlisted scalar result" do
      assert {:ok, @valid_result} = ObservabilityProbe.validate_result(@valid_result)

      assert @valid_result ==
               @valid_result
               |> ObservabilityProbe.encode_result!()
               |> Jason.decode!()
    end

    test "rejects prompts, responses, credentials, tenant IDs, DSNs, and stack traces" do
      forbidden_fields = ~w(prompt response response_body credential tenant_id dsn stack_trace)

      for field <- forbidden_fields do
        result = Map.put(@valid_result, field, "must-not-serialize")
        assert {:error, {:invalid, _reason}} = ObservabilityProbe.validate_result(result)
        assert_raise ArgumentError, fn -> ObservabilityProbe.encode_result!(result) end
      end
    end

    test "rejects any other unversioned result field" do
      assert {:error, {:invalid, _reason}} =
               @valid_result
               |> Map.put("node_id", "private")
               |> ObservabilityProbe.validate_result()
    end

    @tag spec: "probe-results-are-allowlisted-and-content-free"
    test "refuses non-string timestamps instead of raising" do
      for value <- [42, false, %{"at" => "2026-08-03T01:02:03Z"}, ["2026-08-03T01:02:03Z"]] do
        for key <- ~w(started_at finished_at) do
          result = Map.put(@valid_result, key, value)

          assert {:error, {:invalid, _reason}} = ObservabilityProbe.validate_result(result)
          assert_raise ArgumentError, fn -> ObservabilityProbe.encode_result!(result) end
        end
      end
    end
  end

  describe "stream classification" do
    test "classifies exactly one completed terminal event as a pass" do
      body = sse("response.completed", "resp_550e8400-e29b-41d4-a716-446655440001", "completed")

      assert %{
               "outcome" => "pass",
               "classification" => "completed",
               "public_request_id" => "resp_550e8400-e29b-41d4-a716-446655440001",
               "terminal_count" => 1,
               "terminal_state" => "completed"
             } = classify_http_result(200, body)
    end

    test "classifies a failed terminal event as a probe failure" do
      body = sse("response.failed", "resp_550e8400-e29b-41d4-a716-446655440002", "incomplete")

      assert %{
               "outcome" => "fail",
               "classification" => "response_failed",
               "terminal_count" => 1,
               "terminal_state" => "incomplete"
             } = classify_http_result(200, body)
    end

    test "rejects missing, duplicate, and malformed terminal events" do
      duplicate =
        sse("response.completed", "resp_550e8400-e29b-41d4-a716-446655440003", "completed") <>
          sse("response.completed", "resp_550e8400-e29b-41d4-a716-446655440003", "completed")

      malformed = "event: response.completed\ndata: not-json\n\n"

      for body <- ["event: response.created\ndata: {}\n\n", duplicate, malformed] do
        assert %{"outcome" => "fail", "classification" => "invalid_stream"} =
                 classify_http_result(200, body)
      end
    end

    test "classifies a non-200 response without retaining its body" do
      assert %{
               "outcome" => "fail",
               "classification" => "http_error",
               "public_request_id" => nil
             } = classify_http_result(401, "secret response body")
    end
  end

  describe "controller-local durable terminal validation" do
    test "requires exactly one terminal state transition matching the request row" do
      request =
        create_request!(%{
          public_id: "resp_550e8400-e29b-41d4-a716-446655440004",
          state: :running
        })

      assert {:ok, _event} =
               Requests.append_request_event(request, %{
                 event_type: "state_transition",
                 state: :completed,
                 payload: %{to_state: "completed"}
               })

      persisted = Requests.get_request_by_public_id(request.public_id)
      events = Requests.list_request_events(persisted)

      assert {:ok, %{terminal_count: 1, terminal_state: "completed"}} =
               ObservabilityProbe.validate_terminal_record(persisted, events)
    end

    test "fails when durable terminal transitions are absent or duplicated" do
      request = %{state: :failed}
      event = %{event_type: "state_transition", state: :failed}

      assert {:error, %{terminal_count: 0, terminal_state: "failed"}} =
               ObservabilityProbe.validate_terminal_record(request, [])

      assert {:error, %{terminal_count: 2, terminal_state: "failed"}} =
               ObservabilityProbe.validate_terminal_record(request, [event, event])
    end
  end

  defp sse(type, public_id, state) do
    payload =
      Jason.encode!(%{"type" => type, "response" => %{"id" => public_id, "status" => state}})

    "event: #{type}\ndata: #{payload}\n\n"
  end

  describe "identifier, endpoint, and terminal refusal boundaries" do
    test "rejects secret-like values in allowlisted probe_id" do
      assert {:error, {:invalid, _}} =
               @valid_result
               |> Map.put("probe_id", "postgres://tenant:secret@host/db")
               |> ObservabilityProbe.validate_result()
    end

    test "rejects non-canonical public_request_id values" do
      assert {:error, {:invalid, _}} =
               @valid_result
               |> Map.put("public_request_id", "sk-secret-prompt-stacktrace")
               |> ObservabilityProbe.validate_result()
    end

    test "rejects valid terminal plus malformed terminal candidate" do
      good =
        "event: response.completed
data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_550e8400-e29b-41d4-a716-446655440000\",\"status\":\"completed\"}}

"

      bad = "event: response.completed
data: {not-json}

"
      classified = classify_http_result(200, good <> bad)
      assert classified["outcome"] == "fail"
      assert classified["classification"] == "invalid_stream"
    end

    test "rejects completed event with mismatched status" do
      body =
        "event: response.completed
data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_550e8400-e29b-41d4-a716-446655440000\",\"status\":\"failed\"}}

"

      classified = classify_http_result(200, body)
      assert classified["outcome"] == "fail"
      assert classified["classification"] == "invalid_stream"
    end

    test "rejects non-loopback http endpoint_url" do
      config = Map.put(@valid_config, "endpoint_url", "http://example.com/v1/responses")
      assert {:error, {:invalid, reason}} = ObservabilityProbe.validate_config(config)
      assert reason =~ "HTTPS"
    end

    test "rejects endpoint_url with userinfo" do
      config =
        Map.put(@valid_config, "endpoint_url", "https://user:pass@example.com/v1/responses")

      assert {:error, {:invalid, reason}} = ObservabilityProbe.validate_config(config)
      assert reason =~ "userinfo"
    end

    test "rejects identical model and credential env vars" do
      config =
        @valid_config
        |> Map.put("model_env_var", "ORCHARD_SHARED")
        |> Map.put("credential_env_var", "ORCHARD_SHARED")

      assert {:error, {:invalid, _}} = ObservabilityProbe.validate_config(config)
    end

    test "accepts https endpoint_url" do
      config = Map.put(@valid_config, "endpoint_url", "https://controller.example/v1/responses")
      assert {:ok, ^config} = ObservabilityProbe.validate_config(config)
    end
  end

  describe "canonical content-free identifiers" do
    @tag spec: "probe-results-are-allowlisted-and-content-free"
    test "accepts a nil probe ID only for invalid configuration results" do
      invalid_config =
        @valid_result
        |> Map.put("probe_id", nil)
        |> Map.put("outcome", "fail")
        |> Map.put("classification", "invalid_config")
        |> Map.put("public_request_id", nil)
        |> Map.put("terminal_count", nil)
        |> Map.put("terminal_state", nil)
        |> Map.put("http_status", nil)
        |> Map.put("latency_ms", 0)

      assert {:ok, ^invalid_config} = ObservabilityProbe.validate_result(invalid_config)

      assert {:error, {:invalid, _reason}} =
               @valid_result
               |> Map.put("probe_id", nil)
               |> ObservabilityProbe.validate_result()
    end

    @tag spec: "probe-results-are-allowlisted-and-content-free"
    test "rejects malformed or content-bearing identifiers" do
      invalid_probe_ids = [
        "probe_550E8400-e29b-41d4-a716-446655440000",
        "probe_550e8400-e29b-41d4-a716-446655440000-extra",
        "postgres://tenant:secret@host/db",
        "sk-secret-prompt-stacktrace"
      ]

      invalid_public_ids = [
        "resp_550E8400-e29b-41d4-a716-446655440000",
        "resp_550e8400-e29b-41d4-a716-446655440000-extra",
        "postgres://tenant:secret@host/db",
        "sk-secret-prompt-stacktrace",
        42
      ]

      for probe_id <- invalid_probe_ids do
        assert {:error, {:invalid, _reason}} =
                 @valid_result
                 |> Map.put("probe_id", probe_id)
                 |> ObservabilityProbe.validate_result()
      end

      for public_id <- invalid_public_ids do
        assert {:error, {:invalid, _reason}} =
                 @valid_result
                 |> Map.put("public_request_id", public_id)
                 |> ObservabilityProbe.validate_result()
      end
    end
  end

  describe "fail-closed terminal parsing" do
    @tag spec: "buffered-typed-terminal-determines-http-only-outcome"
    test "accepts only the producer terminal status set" do
      for status <- ["failed", "incomplete"] do
        assert %{"classification" => "response_failed", "terminal_state" => ^status} =
                 classify_http_result(
                   200,
                   sse("response.failed", "resp_550e8400-e29b-41d4-a716-446655440010", status)
                 )
      end

      for status <- ["completed", "cancelled", "unknown", "", nil, 42] do
        body = terminal_block("response.failed", "response.failed", valid_response(status))

        assert %{"classification" => "invalid_stream", "outcome" => "fail"} =
                 classify_http_result(200, body)
      end
    end

    @tag spec: "buffered-typed-terminal-determines-http-only-outcome"
    test "rejects every malformed or contradictory terminal candidate" do
      id = "resp_550e8400-e29b-41d4-a716-446655440011"

      invalid_bodies = [
        terminal_block(nil, "response.completed", %{"id" => id, "status" => "completed"}),
        terminal_block("response.created", "response.completed", %{
          "id" => id,
          "status" => "completed"
        }),
        terminal_block("response.completed", "response.failed", %{
          "id" => id,
          "status" => "failed"
        }),
        terminal_block("response.failed", "response.completed", %{
          "id" => id,
          "status" => "completed"
        }),
        terminal_block("response.completed", "response.completed", nil),
        terminal_block("response.completed", "response.completed", "scalar"),
        terminal_block("response.completed", "response.completed", []),
        terminal_block("response.completed", "response.completed", %{"status" => "completed"}),
        terminal_block("response.completed", "response.completed", %{
          "id" => 42,
          "status" => "completed"
        }),
        terminal_block("response.completed", "response.completed", %{"id" => id}),
        "event: response.completed\nevent: response.failed\ndata: {}\n\n",
        "event: response.completed\ndata: {}\ndata: {}\n\n",
        <<"event: response.completed\ndata: ", 255, "\n\n">>
      ]

      for body <- invalid_bodies do
        assert %{"classification" => "invalid_stream", "outcome" => "fail"} =
                 classify_http_result(200, body)
      end
    end

    @tag spec: "buffered-typed-terminal-determines-http-only-outcome"
    test "colonless or repeated terminal event and data fields poison the block" do
      valid =
        sse("response.completed", "resp_550e8400-e29b-41d4-a716-446655440015", "completed")

      terminal_lines = String.trim_trailing(valid)

      invalid_bodies = [
        terminal_lines <> "\nevent\n\n",
        terminal_lines <> "\ndata\n\n",
        terminal_lines <> "\nevent: response.completed\n\n",
        terminal_lines <> "\ndata: {}\n\n"
      ]

      for body <- invalid_bodies do
        assert %{"classification" => "invalid_stream", "outcome" => "fail"} =
                 classify_http_result(200, body)
      end
    end

    @tag spec: "buffered-typed-terminal-determines-http-only-outcome"
    test "ignores unrelated producer events but never discards an invalid terminal candidate" do
      id = "resp_550e8400-e29b-41d4-a716-446655440012"
      unrelated = terminal_block("response.created", "response.created", %{"id" => id})
      valid = sse("response.completed", id, "completed")
      malformed = "event: response.failed\ndata: not-json\n\n"

      hidden_terminal =
        "event: response.created\n" <>
          "data: #{Jason.encode!(%{"type" => "response.completed", "response" => valid_response("completed")})}\n" <>
          "data: {}\n\n"

      assert %{"classification" => "completed", "outcome" => "pass"} =
               classify_http_result(200, unrelated <> valid)

      for invalid_candidate <- [malformed, hidden_terminal] do
        assert %{"classification" => "invalid_stream", "outcome" => "fail"} =
                 classify_http_result(
                   200,
                   unrelated <> valid <> invalid_candidate
                 )
      end
    end
  end

  describe "controller-local cross-plane agreement" do
    @tag spec: "controller-local-mode-reconciles-http-and-durable-terminals"
    test "accepts only documented HTTP-to-durable terminal mappings" do
      completed = http_classification("completed", "completed")
      failed = http_classification("response_failed", "failed")
      incomplete = http_classification("response_failed", "incomplete")

      assert %{"classification" => "completed", "terminal_state" => "completed"} =
               reconcile(completed, :completed)

      for durable <- [:failed, :cancelled, :timed_out, :interrupted] do
        result = reconcile(failed, durable)
        assert result["classification"] == "response_failed"
        assert result["terminal_state"] == Atom.to_string(durable)
      end

      for durable <- [:cancelled, :timed_out, :interrupted] do
        result = reconcile(incomplete, durable)
        assert result["classification"] == "response_failed"
        assert result["terminal_state"] == Atom.to_string(durable)
      end
    end

    @tag spec: "controller-local-mode-reconciles-http-and-durable-terminals"
    test "fails closed for missing IDs, cross-plane contradictions, and active rows" do
      completed = http_classification("completed", "completed")
      failed = http_classification("response_failed", "failed")
      incomplete = http_classification("response_failed", "incomplete")

      for result <- [
            reconcile(completed, :failed),
            reconcile(failed, :completed),
            reconcile(incomplete, :failed),
            reconcile(Map.put(completed, "public_request_id", nil), :completed)
          ] do
        assert result["classification"] == "terminal_validation_failed"
        assert result["outcome"] == "fail"
      end

      active = reconcile(completed, :running, [])
      assert active["classification"] == "terminal_validation_failed"
      assert active["terminal_state"] == nil
      assert active["terminal_count"] == 0
    end
  end

  describe "Controller-local query failure safety" do
    @tag spec: "controller-local-mode-reconciles-http-and-durable-terminals"
    test "preserves transport, HTTP, and stream failures without a durable lookup" do
      for classification <- ~w(transport_error http_error invalid_stream) do
        classified = %{
          "outcome" => "fail",
          "classification" => classification,
          "public_request_id" => nil,
          "terminal_count" => nil,
          "terminal_state" => nil
        }

        assert ^classified =
                 ObservabilityProbe.validate_controller_local_result(
                   classified,
                   fn -> flunk("durable lookup ran without an observed terminal") end,
                   fn _request -> flunk("event listing ran without an observed terminal") end
                 )
      end
    end

    @tag spec: "controller-local-mode-reconciles-http-and-durable-terminals"
    test "sanitizes ordinary lookup and event-query failures" do
      secret = "postgres://operator:secret@db/private"
      classified = http_classification("completed", "completed")

      failures = [
        {
          fn -> raise DBConnection.ConnectionError, message: secret end,
          fn _request -> [] end
        },
        {
          fn -> %{state: :completed} end,
          fn _request -> raise DBConnection.ConnectionError, message: secret end
        },
        {
          fn -> %{state: :completed} end,
          fn _request -> exit({:shutdown, secret}) end
        }
      ]

      for {lookup, list_events} <- failures do
        result =
          ObservabilityProbe.validate_controller_local_result(classified, lookup, list_events)

        assert result["classification"] == "terminal_validation_failed"
        assert result["outcome"] == "fail"
        assert result["terminal_state"] == nil

        encoded =
          @valid_result
          |> Map.merge(result)
          |> ObservabilityProbe.encode_result!()

        refute encoded =~ secret
      end
    end
  end

  describe "Controller-local stdout isolation" do
    @tag spec: "probe-results-are-allowlisted-and-content-free"
    test "http-only terminal validation starts no Repo" do
      assert :ok =
               ObservabilityProbe.start_terminal_validation_repo("http_only", fn _options ->
                 flunk("http_only terminal validation started the Repo")
               end)
    end

    @tag spec: "probe-results-are-allowlisted-and-content-free"
    test "controller-local terminal validation starts the Repo with query logging disabled" do
      tenant_id = Ecto.UUID.generate()

      # Query logs reach the default handler, which shares the stdout stream the
      # probe reserves for its result JSON.
      {:ok, _unguarded} = start_probe_repo(:probe_repo_unguarded, [])
      leaked = capture_durable_lookup_log(:probe_repo_unguarded, tenant_id)

      assert leaked =~ "QUERY OK"
      assert leaked =~ tenant_id

      assert :ok =
               ObservabilityProbe.start_terminal_validation_repo(
                 "controller_local",
                 &start_probe_repo(:probe_repo_guarded, &1)
               )

      silenced = capture_durable_lookup_log(:probe_repo_guarded, tenant_id)

      refute silenced =~ tenant_id
      refute silenced =~ ~s(FROM "requests")
    end
  end

  describe "trusted credential destination" do
    @tag spec: "phase-0-probe-configuration-is-exact-and-versioned"
    test "rejects unsafe or ambiguous endpoint authorities" do
      invalid_urls = [
        "http://example.com/v1/responses",
        "https://user:pass@example.com/v1/responses",
        "https://example.com:0/v1/responses",
        "https://example.com:65536/v1/responses",
        "https:///v1/responses",
        "https://example.com/v1/responses?redirect=evil",
        "https://example.com/v1/responses#fragment"
      ]

      for url <- invalid_urls do
        assert {:error, {:invalid, _reason}} =
                 @valid_config
                 |> Map.put("endpoint_url", url)
                 |> ObservabilityProbe.validate_config()
      end

      for url <- [
            "http://localhost:4000/v1/responses",
            "http://127.0.0.1:4000/v1/responses",
            "http://[::1]:4000/v1/responses",
            "https://controller.example/v1/responses"
          ] do
        assert {:ok, _config} =
                 @valid_config
                 |> Map.put("endpoint_url", url)
                 |> ObservabilityProbe.validate_config()
      end
    end

    @tag spec: "phase-0-probe-configuration-is-exact-and-versioned"
    test "builds no-redirect HTTP options with explicit HTTPS peer and hostname verification" do
      assert {:ok, http_options} = ObservabilityProbe.build_http_options(@valid_config)
      assert http_options[:autoredirect] == false
      refute Keyword.has_key?(http_options, :ssl)

      https_config =
        Map.put(@valid_config, "endpoint_url", "https://controller.example/v1/responses")

      assert {:ok, https_options} = ObservabilityProbe.build_http_options(https_config)
      assert https_options[:autoredirect] == false
      assert https_options[:ssl][:verify] == :verify_peer
      assert is_list(https_options[:ssl][:cacerts])
      assert https_options[:ssl][:cacerts] != []
      assert https_options[:ssl][:server_name_indication] == ~c"controller.example"
      assert is_function(https_options[:ssl][:customize_hostname_check][:match_fun], 2)
    end

    @tag spec: "phase-0-probe-configuration-is-exact-and-versioned"
    test "refuses HTTPS transport when the host CA store is unavailable" do
      https_config =
        Map.put(@valid_config, "endpoint_url", "https://controller.example/v1/responses")

      unavailable_stores = [
        fn -> :erlang.error(:enoent) end,
        fn -> raise ArgumentError, "/etc/ssl/cert.pem" end,
        fn -> [] end,
        fn -> :undefined end
      ]

      for load_cacerts <- unavailable_stores do
        assert {:error, {:invalid, reason}} =
                 ObservabilityProbe.build_http_options(https_config, load_cacerts)

        assert reason =~ "CA store"
        refute reason =~ "cert.pem"
      end

      assert {:ok, _options} =
               ObservabilityProbe.build_http_options(@valid_config, fn ->
                 :erlang.error(:enoent)
               end)
    end

    @tag spec: "phase-0-probe-configuration-is-exact-and-versioned"
    test "rejects unsafe resolved model and credential values without echoing them" do
      unsafe_values = [
        {"model\nleak", "safe-token"},
        {"model", "token\r\nX-Leak: yes"},
        {"model", "token with spaces"},
        {"", "safe-token"},
        {String.duplicate("m", 513), "safe-token"},
        {"model", String.duplicate("t", 4097)}
      ]

      for {model, credential} <- unsafe_values do
        assert {:error, {:invalid, reason}} =
                 ObservabilityProbe.validate_resolved_values(model, credential)

        if model != "", do: refute(String.contains?(reason, model))
        if credential != "", do: refute(String.contains?(reason, credential))
      end

      assert :ok = ObservabilityProbe.validate_resolved_values("model-id", "safe-token")
    end
  end

  describe "final HTTP acceptance boundaries" do
    @tag spec: "buffered-typed-terminal-determines-http-only-outcome"
    test "requires exactly one event-stream response media type" do
      body =
        sse("response.completed", "resp_550e8400-e29b-41d4-a716-446655440016", "completed")

      assert %{"classification" => "completed", "outcome" => "pass"} =
               classify_http_result(
                 200,
                 [{~c"Content-Type", ~c"text/event-stream; charset=utf-8"}],
                 body
               )

      invalid_headers = [
        [],
        [{~c"content-type", ~c"application/json"}],
        [{~c"content-type", ~c"text/event-stream, application/json"}],
        [
          {~c"content-type", ~c"text/event-stream"},
          {~c"Content-Type", ~c"text/event-stream"}
        ]
      ]

      for headers <- invalid_headers do
        assert %{"classification" => "invalid_stream", "outcome" => "fail"} =
                 classify_http_result(200, headers, body)
      end
    end

    @tag spec: "phase-0-probe-configuration-is-exact-and-versioned"
    test "rejects raw malformed authorities before URI normalization" do
      invalid_urls = [
        "https://controller.example:/v1/responses",
        "https://controller.example:abc/v1/responses",
        "https://controller.example: 443/v1/responses",
        "https://controller.example:\t443/v1/responses",
        "https://[::1/v1/responses",
        "https://[::1]]/v1/responses",
        "https://::1/v1/responses"
      ]

      for url <- invalid_urls do
        assert {:error, {:invalid, _reason}} =
                 @valid_config
                 |> Map.put("endpoint_url", url)
                 |> ObservabilityProbe.validate_config()
      end

      for url <- [
            "https://controller.example/v1/responses",
            "https://controller.example:443/v1/responses",
            "http://localhost/v1/responses",
            "http://[::1]:4000/v1/responses"
          ] do
        assert {:ok, _config} =
                 @valid_config
                 |> Map.put("endpoint_url", url)
                 |> ObservabilityProbe.validate_config()
      end
    end

    @tag spec: "probe-results-are-allowlisted-and-content-free"
    @tag timeout: 120_000
    test "normalizes an out-of-contract HTTP status to a safe exit-1 result" do
      {port, server} =
        start_raw_http_server(
          "HTTP/1.1 700 Out of Contract\r\n" <>
            "Content-Type: text/event-stream\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

      on_exit(fn -> Process.exit(server, :kill) end)

      tmp_dir =
        Path.join(System.tmp_dir!(), "orchard-probe-status-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      config_path = Path.join(tmp_dir, "config.json")

      config =
        Map.put(@valid_config, "endpoint_url", "http://127.0.0.1:#{port}/v1/responses")

      File.write!(config_path, Jason.encode!(config))
      wrapper = Path.expand("../../../../scripts/smoke-observability-probe.sh", __DIR__)

      {stdout, 1} =
        System.cmd(wrapper, [config_path],
          env: [
            {"ORCHARD_OBSERVABILITY_PROBE_MODEL", "model-id"},
            {"ORCHARD_OBSERVABILITY_PROBE_API_KEY", "safe-token"}
          ]
        )

      result = stdout |> String.trim() |> Jason.decode!()
      assert result["outcome"] == "fail"
      assert result["classification"] == "http_error"
      assert result["http_status"] == nil
    end
  end

  describe "launcher contract" do
    @tag spec: "launcher-preserves-caller-path-and-owned-exit-semantics"
    @tag timeout: 120_000
    test "resolves relative config paths from the caller and documents owned exit codes" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "orchard-probe-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      File.write!(Path.join(tmp_dir, "invalid.json"), "not-json")

      wrapper = Path.expand("../../../../scripts/smoke-observability-probe.sh", __DIR__)
      stdout_path = Path.join(tmp_dir, "stdout")
      stderr_path = Path.join(tmp_dir, "stderr")

      {_output, 2} =
        System.cmd(
          "sh",
          ["-c", "\"$1\" invalid.json >stdout 2>stderr", "probe-launch", wrapper],
          cd: tmp_dir
        )

      stdout = stdout_path |> File.read!() |> String.trim() |> Jason.decode!()
      stderr = File.read!(stderr_path)

      assert stdout["classification"] == "invalid_config"
      assert stdout["probe_id"] == nil
      assert stderr =~ "config is not valid JSON"
      refute stderr =~ tmp_dir

      {usage, 64} = System.cmd(wrapper, [], stderr_to_stdout: true)
      assert usage =~ "0=pass"
      assert usage =~ "1=probe fail"
      assert usage =~ "2=invalid config"
      assert usage =~ "64=usage"
    end

    @tag spec: "probe-results-are-allowlisted-and-content-free"
    @tag timeout: 120_000
    test "retains the pinned probe ID when a refusal follows a valid configuration" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "orchard-probe-refusal-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      config_path = Path.join(tmp_dir, "config.json")
      File.write!(config_path, Jason.encode!(@valid_config))
      wrapper = Path.expand("../../../../scripts/smoke-observability-probe.sh", __DIR__)

      {output, 2} =
        System.cmd(wrapper, [config_path],
          env: [
            {"ORCHARD_OBSERVABILITY_PROBE_MODEL", nil},
            {"ORCHARD_OBSERVABILITY_PROBE_API_KEY", nil}
          ]
        )

      result = output |> String.trim() |> Jason.decode!()

      assert result["classification"] == "invalid_config"
      assert result["probe_id"] == @valid_config["probe_id"]
      assert result["public_request_id"] == nil
    end

    @tag spec: "launcher-preserves-caller-path-and-owned-exit-semantics"
    @tag timeout: 120_000
    test "passes a nonexistent nested caller-relative path to invalid-config handling" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "orchard-probe-nested-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      wrapper = Path.expand("../../../../scripts/smoke-observability-probe.sh", __DIR__)

      {_output, 2} =
        System.cmd(
          "sh",
          ["-c", "\"$1\" missing/child/config.json >stdout 2>stderr", "probe-launch", wrapper],
          cd: tmp_dir
        )

      stdout = tmp_dir |> Path.join("stdout") |> File.read!() |> String.trim() |> Jason.decode!()
      stderr = tmp_dir |> Path.join("stderr") |> File.read!()

      assert stdout["classification"] == "invalid_config"
      assert stdout["probe_id"] == nil
      assert stderr =~ "cannot read config"
      refute stderr =~ tmp_dir
      refute stderr =~ "can't cd"
      refute stderr =~ "cd:"
    end
  end

  defp start_probe_repo(name, options) do
    # The probe owns its Repo instance outside the test sandbox, so this mirrors
    # the launcher with a real connection pool.
    config =
      :orchard_controller
      |> Application.fetch_env!(Orchard.Repo)
      |> Keyword.merge(options)
      |> Keyword.merge(name: name, pool: DBConnection.ConnectionPool, pool_size: 1)

    start_supervised({Orchard.Repo, config}, id: name)
  end

  defp capture_durable_lookup_log(repo_name, tenant_id) do
    previous_repo = Orchard.Repo.get_dynamic_repo()
    previous_level = Logger.level()
    # Source dev runs the probe at the default :debug level, where Ecto query
    # logs share the stdout stream reserved for the probe result JSON.
    Logger.configure(level: :debug)
    Orchard.Repo.put_dynamic_repo(repo_name)

    try do
      capture_log(fn ->
        Requests.get_request_by_tenant_and_idempotency_key(tenant_id, "probe-log-check")
      end)
    after
      Orchard.Repo.put_dynamic_repo(previous_repo)
      Logger.configure(level: previous_level)
    end
  end

  defp classify_http_result(status, body) do
    Orchard.ObservabilityProbe.classify_http_result(
      status,
      [{~c"content-type", ~c"text/event-stream"}],
      body
    )
  end

  defp classify_http_result(status, headers, body) do
    Orchard.ObservabilityProbe.classify_http_result(status, headers, body)
  end

  defp start_raw_http_server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    pid =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {port, pid}
  end

  defp terminal_block(event_type, json_type, response) do
    event_line = if event_type, do: "event: #{event_type}\n", else: ""
    payload = Jason.encode!(%{"type" => json_type, "response" => response})
    event_line <> "data: #{payload}\n\n"
  end

  defp valid_response(status) do
    %{"id" => "resp_550e8400-e29b-41d4-a716-446655440013", "status" => status}
  end

  defp http_classification(classification, terminal_state) do
    %{
      "outcome" => if(classification == "completed", do: "pass", else: "fail"),
      "classification" => classification,
      "public_request_id" => "resp_550e8400-e29b-41d4-a716-446655440014",
      "terminal_count" => 1,
      "terminal_state" => terminal_state
    }
  end

  defp reconcile(classified, durable_state, events \\ nil) do
    request = %{state: durable_state}
    events = events || [%{event_type: "state_transition", state: durable_state}]
    ObservabilityProbe.reconcile_terminal_result(classified, request, events)
  end
end
