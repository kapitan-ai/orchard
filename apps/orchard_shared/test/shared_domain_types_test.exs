defmodule OrchardSharedDomainTypesTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest

  alias Orchard.CanonicalRequest.{
    Admission,
    ModelRef,
    ResolvedPolicy,
    ResponseFormat,
    Sampling,
    Tooling
  }

  alias Orchard.Cluster.V1.{InferenceEventMapper, ModelManifestMapper}
  alias Orchard.InferenceEvent
  alias Orchard.InferenceEvent.Usage
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.{ChatTemplate, RuntimeRequirements, Tokenizer}

  test "canonical request stores spec-aligned fields and tokenization" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        principal_id: "principal_123",
        api_key_id: "key_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        input_items: [%{"role" => "user", "content" => "hello"}],
        stream?: true,
        sampling: %Sampling{temperature: 0.7, top_p: 0.95, max_output_tokens: 128, stop: ["</s>"]},
        response_format: %ResponseFormat{type: :text},
        tooling: %Tooling{
          tools: [%{"type" => "function"}],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"}],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [%{"name" => "lookup_weather", "version" => "2026-04-09"}]
          },
          execution_snapshot: %{
            entries: [
              %{
                "name" => "lookup_weather",
                "provenance" => "registry",
                "disposition" => "client_passthrough"
              }
            ]
          }
        },
        metadata: %{"trace_id" => "trace_123"},
        admission: %Admission{timeout_ms: 30_000, queue_wait_ms: 5_000, max_cold_start_ms: 10_000},
        resolved_policy: %ResolvedPolicy{
          allowed_pool_ids: ["pool_1"],
          residency_preference: :prefer_loaded
        }
      })

    updated = CanonicalRequest.with_tokenization(request, "<s>hello</s>", 12)

    assert updated.rendered_prompt == "<s>hello</s>"
    assert updated.input_token_count == 12
    assert updated.model_ref.model_id == "mlx-community/phi-3"
    assert updated.sampling.max_output_tokens == 128

    assert updated.tooling.requested_tools == [
             %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-09"}
           ]

    assert updated.tooling.registry_snapshot == %{
             entries: [%{"name" => "lookup_weather", "version" => "2026-04-09"}]
           }

    assert updated.tooling.execution_snapshot == %{
             entries: [
               %{
                 "name" => "lookup_weather",
                 "provenance" => "registry",
                 "disposition" => "client_passthrough"
               }
             ]
           }

    assert updated.resolved_policy.residency_preference == :prefer_loaded
  end

  test "canonical request spec section 3.4 tooling defaults keep old callers valid" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        tooling: %Tooling{tools: [%{"type" => "function"}], tool_choice: "auto"}
      })

    assert request.tooling.tools == [%{"type" => "function"}]
    assert request.tooling.requested_tools == []
    assert request.tooling.tool_choice == "auto"
    assert request.tooling.registry_snapshot == %{entries: []}
    assert request.tooling.execution_snapshot == %{entries: []}
  end

  test "canonical request normalizes nil defaults to shared nested structs" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        sampling: nil,
        response_format: nil,
        tooling: nil,
        admission: nil,
        resolved_policy: nil
      })

    assert %Sampling{} = request.sampling
    assert %ResponseFormat{} = request.response_format
    assert %Tooling{} = request.tooling
    assert request.tooling.execution_snapshot == %{entries: []}
    assert %Admission{} = request.admission
    assert %ResolvedPolicy{} = request.resolved_policy
  end

  test "canonical request normalizes integer-valued sampling fields to floats" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        sampling: %Sampling{temperature: 1, top_p: 1, max_output_tokens: 128}
      })

    assert request.sampling.temperature == 1.0
    assert request.sampling.top_p == 1.0
  end

  test "shared constructors accept nested keyword lists and consistent tokenization errors" do
    request =
      CanonicalRequest.new(
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: [model_id: "mlx-community/phi-3", version: "main"],
        resolved_policy: [allowed_pool_ids: ["pool_1"], residency_preference: :allow_cold_load]
      )

    manifest =
      ModelManifest.new(
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: [kind: "huggingface_tokenizer_json", path: "tokenizer.json"],
        runtime_requirements: [adapter: "mlx_lm", min_agent_capability: "mlx"]
      )

    assert request.model_ref.version == "main"
    assert manifest.tokenizer.path == "tokenizer.json"

    assert_raise ArgumentError, fn ->
      CanonicalRequest.with_tokenization(request, :invalid, -1)
    end
  end

  test "inference event converts to and from the shared runtime proto" do
    event =
      InferenceEvent.completed(:finish_reason_stop, %Usage{
        input_tokens: 12,
        output_tokens: 8,
        total_tokens: 20
      })

    assert {:ok, ^event} =
             event |> InferenceEventMapper.to_proto() |> InferenceEventMapper.from_proto()

    assert InferenceEvent.kind(event) == :completed
    assert InferenceEvent.terminal?(event)

    usage_event =
      InferenceEvent.usage_update(%Usage{input_tokens: 12, output_tokens: 8, total_tokens: 20})

    assert InferenceEvent.kind(usage_event) == :usage
  end

  test "inference event mapper handles tool-call finish reason bidirectionally" do
    event =
      InferenceEvent.completed(:finish_reason_tool_calls, %Usage{
        input_tokens: 12,
        output_tokens: 8,
        total_tokens: 20
      })

    assert %Orchard.Cluster.V1.InferenceEvent{
             event:
               {:completed,
                %Orchard.Cluster.V1.Completed{finish_reason: :FINISH_REASON_TOOL_CALLS}}
           } = InferenceEventMapper.to_proto(event)

    assert {:ok, ^event} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event:
                 {:completed,
                  %Orchard.Cluster.V1.Completed{
                    finish_reason: :FINISH_REASON_TOOL_CALLS,
                    usage: %Orchard.Cluster.V1.TokenUsage{
                      input_tokens: 12,
                      output_tokens: 8,
                      total_tokens: 20
                    }
                  }}
             })
  end

  test "model manifest converts to the shared model ref proto" do
    manifest =
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        size_bytes: 123,
        resident_memory_bytes: 456,
        kv_cache_bytes_per_token: 16,
        prefill_workspace_bytes_per_token: 8,
        max_context_tokens: 32_768,
        capabilities: ["chat", "json_mode"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        chat_template: %ChatTemplate{path: "chat_template.jinja", sha256: "def456"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })

    assert ModelManifest.identity(manifest) == {"llama-3.1-8b-instruct", "mlx-q4-v1"}

    assert %Orchard.Cluster.V1.ModelRef{model_id: "llama-3.1-8b-instruct", version: "mlx-q4-v1"} =
             ModelManifestMapper.to_model_ref(manifest)
  end

  test "inference event mapper returns errors for malformed proto payloads" do
    assert {:error, :missing_event} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{})

    assert {:error, :missing_usage} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event: {:usage, %Orchard.Cluster.V1.UsageUpdate{usage: nil}}
             })

    assert {:error, {:invalid_usage, %{}}} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event: {:usage, %Orchard.Cluster.V1.UsageUpdate{usage: %{}}}
             })

    assert {:error,
            {:invalid_usage,
             %Orchard.Cluster.V1.TokenUsage{input_tokens: -1, output_tokens: 0, total_tokens: 0}}} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event:
                 {:completed,
                  %Orchard.Cluster.V1.Completed{
                    finish_reason: :FINISH_REASON_STOP,
                    usage: %Orchard.Cluster.V1.TokenUsage{
                      input_tokens: -1,
                      output_tokens: 0,
                      total_tokens: 0
                    }
                  }}
             })

    assert {:error, {:invalid_payload, :accepted, :invalid_scalar_values}} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event: {:accepted, %Orchard.Cluster.V1.Accepted{accepted_at_unix_ms: -1}}
             })

    assert {:error, {:invalid_payload, :progress, :invalid_scalar_values}} =
             InferenceEventMapper.from_proto(%Orchard.Cluster.V1.InferenceEvent{
               event:
                 {:progress, %Orchard.Cluster.V1.Progress{stage: nil, message: "warming model"}}
             })
  end

  test "shared constructors reject invalid enum-like values and malformed nested payloads" do
    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :invalid,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %{model_id: nil, version: nil}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %{model_id: "mlx-community/phi-3"}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        admission: %Admission{timeout_ms: -1, queue_wait_ms: 0, max_cold_start_ms: 0}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        sampling: %Sampling{temperature: -1.0, top_p: 1.5}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        input_items: [42],
        resolved_policy: %ResolvedPolicy{allowed_pool_ids: [nil]}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        rendered_prompt: nil,
        input_token_count: 12
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        tooling: %Tooling{tools: [%{"type" => "function"}], tool_choice: ""}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        tooling: %Tooling{requested_tools: [42]}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        tooling: %Tooling{registry_snapshot: %{entries: [42]}}
      })
    end

    assert_raise ArgumentError, fn ->
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :chat_completions,
        tenant_id: "tenant_123",
        model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"},
        tooling: %Tooling{execution_snapshot: %{entries: [42]}}
      })
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.completed(:invalid_finish_reason, %Usage{})
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.usage_update(%Usage{input_tokens: -1, output_tokens: 0, total_tokens: 0})
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.usage_update(%Usage{input_tokens: 1, output_tokens: 1, total_tokens: 3})
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.progress(nil, "warming model")
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.failed("", "", false)
    end

    assert_raise ArgumentError, fn ->
      InferenceEvent.tool_call_delta("", "{}")
    end

    assert_raise ArgumentError, fn ->
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: nil,
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })
    end

    assert_raise ArgumentError, fn ->
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %{kind: nil, path: nil},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })
    end

    assert_raise ArgumentError, fn ->
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %{kind: "huggingface_tokenizer_json"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })
    end

    assert_raise ArgumentError, fn ->
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat", nil],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })
    end

    assert_raise ArgumentError, fn ->
      ModelManifest.new(%{
        model_id: "llama-3.1-8b-instruct",
        version: "mlx-q4-v1",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        size_bytes: -1,
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{adapter: "mlx_lm", min_agent_capability: "mlx"}
      })
    end
  end
end
