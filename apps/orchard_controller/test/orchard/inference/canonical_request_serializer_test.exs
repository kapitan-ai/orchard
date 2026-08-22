defmodule Orchard.Inference.CanonicalRequestSerializerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.CanonicalRequestSerializer

  test "serialize/1 emits string-keyed endpoint-aware canonical data" do
    tool_id = Ecto.UUID.generate()

    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "resp_123",
        endpoint: :responses,
        tenant_id: Ecto.UUID.generate(),
        principal_id: "principal_1",
        api_key_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        input_items: [%{"role" => "user", meta: %{turn: 1}}],
        rendered_prompt: "hello",
        input_token_count: 12,
        prompt_token_ids: Enum.to_list(1..12),
        stream?: false,
        stream_include_usage: false,
        sampling: %{temperature: 0.7, top_p: 0.9, stop: ["END"], seed: 7},
        response_format: %{type: :text},
        tooling: %{
          tools: [%{name: "calculator"}],
          requested_tools: [%{"type" => "function", "ref" => "tool://calculator@2026-04-10"}],
          tool_choice: %{type: "auto"},
          registry_snapshot: %{
            entries: [
              %{
                tool_id: tool_id,
                name: "calculator",
                version: "2026-04-10",
                execution_mode: :client_only
              }
            ]
          },
          execution_snapshot: %{
            entries: [
              %{
                name: "calculator",
                provenance: :registry,
                disposition: :client_passthrough,
                execution_mode: :client_only
              }
            ]
          }
        },
        metadata: %{trace_id: "trace-1", tags: [:a, :b]},
        admission: %{timeout_ms: 10_000, queue_wait_ms: 50, max_cold_start_ms: 500},
        resolved_policy: %{
          quota_id: "quota_1",
          routing_policy_id: "route_1",
          allowed_pool_ids: ["pool_1"],
          max_active_requests: 2,
          residency_preference: :prefer_loaded
        }
      })

    serialized = CanonicalRequestSerializer.serialize(canonical)

    assert serialized["endpoint"] == "responses"
    assert serialized["model_ref"] == %{"model_id" => "test-model", "version" => "v1"}
    assert serialized["input_items"] == [%{"role" => "user", "meta" => %{"turn" => 1}}]
    assert serialized["metadata"] == %{"trace_id" => "trace-1", "tags" => ["a", "b"]}
    assert serialized["sampling"]["stop"] == ["END"]
    assert serialized["resolved_policy"]["residency_preference"] == "prefer_loaded"
    assert serialized["resolved_policy"]["max_active_requests"] == 2

    assert serialized["tooling"] == %{
             "tools" => [%{"name" => "calculator"}],
             "requested_tools" => [
               %{"type" => "function", "ref" => "tool://calculator@2026-04-10"}
             ],
             "tool_choice" => %{"type" => "auto"},
             "registry_snapshot" => %{
               "entries" => [
                 %{
                   "tool_id" => tool_id,
                   "name" => "calculator",
                   "version" => "2026-04-10",
                   "execution_mode" => "client_only"
                 }
               ]
             },
             "execution_snapshot" => %{
               "entries" => [
                 %{
                   "name" => "calculator",
                   "provenance" => "registry",
                   "disposition" => "client_passthrough",
                   "execution_mode" => "client_only"
                 }
               ]
             }
           }

    refute Map.has_key?(serialized, :endpoint)
    refute Map.has_key?(serialized, "prompt_token_ids")
  end

  test "serialize/1 rejects embedded structs in plain data fields" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "resp_struct",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        input_items: [%{payload: %URI{scheme: "file", path: "/tmp/test"}}],
        stream?: false
      })

    assert_raise ArgumentError, ~r/expected plain map data/, fn ->
      CanonicalRequestSerializer.serialize(canonical)
    end
  end

  test "serialize/1 rejects an unresolved admission timeout" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "resp_unresolved_timeout",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        admission: %{timeout_ms: nil}
      })

    assert_raise ArgumentError, ~r/admission timeout must be a positive integer/, fn ->
      CanonicalRequestSerializer.serialize(canonical)
    end
  end
end
