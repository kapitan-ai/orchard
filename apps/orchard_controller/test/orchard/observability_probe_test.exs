Code.require_file("../../../../scripts/support/observability_probe.exs", __DIR__)

defmodule Orchard.ObservabilityProbeTest do
  use Orchard.DataCase, async: true

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.ObservabilityProbe
  alias Orchard.Requests

  @valid_config %{
    "schema_version" => 1,
    "probe_id" => "phase0-test",
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
    "probe_id" => "phase0-test",
    "started_at" => "2026-08-03T01:02:03.000Z",
    "finished_at" => "2026-08-03T01:02:04.000Z",
    "outcome" => "pass",
    "classification" => "completed",
    "public_request_id" => "resp_probe_1",
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
  end

  describe "stream classification" do
    test "classifies exactly one completed terminal event as a pass" do
      body = sse("response.completed", "resp_probe_completed", "completed")

      assert %{
               "outcome" => "pass",
               "classification" => "completed",
               "public_request_id" => "resp_probe_completed",
               "terminal_count" => 1,
               "terminal_state" => "completed"
             } = ObservabilityProbe.classify_http_result(200, body)
    end

    test "classifies a failed terminal event as a probe failure" do
      body = sse("response.failed", "resp_probe_failed", "incomplete")

      assert %{
               "outcome" => "fail",
               "classification" => "response_failed",
               "terminal_count" => 1,
               "terminal_state" => "incomplete"
             } = ObservabilityProbe.classify_http_result(200, body)
    end

    test "rejects missing, duplicate, and malformed terminal events" do
      duplicate =
        sse("response.completed", "resp_probe_duplicate", "completed") <>
          sse("response.completed", "resp_probe_duplicate", "completed")

      malformed = "event: response.completed\ndata: not-json\n\n"

      for body <- ["event: response.created\ndata: {}\n\n", duplicate, malformed] do
        assert %{"outcome" => "fail", "classification" => "invalid_stream"} =
                 ObservabilityProbe.classify_http_result(200, body)
      end
    end

    test "classifies a non-200 response without retaining its body" do
      assert %{
               "outcome" => "fail",
               "classification" => "http_error",
               "public_request_id" => nil
             } = ObservabilityProbe.classify_http_result(401, "secret response body")
    end
  end

  describe "controller-local durable terminal validation" do
    test "requires exactly one terminal state transition matching the request row" do
      request = create_request!(%{public_id: "resp_probe_durable", state: :running})

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
end
