defmodule Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference

  @scheduled_node_id "00000000-0000-4000-a000-000000000099"

  def scheduled_node_id, do: @scheduled_node_id

  def schedule(%CanonicalRequest{} = request) do
    {:ok,
     %{
       strategy: :multi_node,
       request_id: request.public_id,
       runtime_client_target: Inference.runtime_client_target(),
       request_timeout_ms: Inference.request_timeout_ms(),
       model_load_timeout_ms: Inference.model_load_timeout_ms(),
       node_id: @scheduled_node_id,
       candidate_count: 2,
       selected_tier: :loaded
     }}
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubUnreachableScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference

  def schedule(%CanonicalRequest{} = request) do
    {:ok,
     %{
       strategy: :single_node,
       request_id: request.public_id,
       runtime_client_target: [host: "127.0.0.1", port: 1],
       request_timeout_ms: Inference.request_timeout_ms(),
       model_load_timeout_ms: 2_000
     }}
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.CapturingRuntimeAdapter do
  @behaviour Orchard.Node.RuntimeAdapter

  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.InferenceEvent

  @impl true
  def get_status(_adapter_state, _opts),
    do: {:ok, %{ready: true, health_code: "", health_message: ""}}

  @impl true
  def load_model(%ModelRef{} = model_ref, _opts), do: {:ok, %{model_ref: model_ref}}

  @impl true
  def unload_model(_adapter_state, _opts), do: :ok

  @impl true
  def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
    if pid = Process.whereis(:request_orchestrator_test_pid) do
      send(pid, {:captured_execute_request, request})
    end

    owner = Keyword.fetch!(opts, :owner)
    generation_ref = make_ref()

    send(
      owner,
      {:runtime_adapter_event, generation_ref,
       InferenceEvent.completed(
         :finish_reason_stop,
         %InferenceEvent.Usage{
           input_tokens: request.input_tokens,
           output_tokens: 0,
           total_tokens: request.input_tokens
         }
       )}
    )

    send(owner, {:runtime_adapter_done, generation_ref})

    {:ok, generation_ref, adapter_state}
  end

  @impl true
  def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

  @impl true
  def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
end

defmodule Orchard.Inference.RequestOrchestratorTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  alias Orchard.ArtifactBundle
  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestrator
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Requests
  alias Orchard.Requests.Idempotency

  setup do
    ModelManager.reset()
    bundle = stage_test_bundle!()
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    if Process.whereis(:request_orchestrator_test_pid) do
      Process.unregister(:request_orchestrator_test_pid)
    end

    Process.register(self(), :request_orchestrator_test_pid)

    on_exit(fn ->
      if Process.whereis(:request_orchestrator_test_pid) == self() do
        Process.unregister(:request_orchestrator_test_pid)
      end

      Application.put_env(:orchard_controller, :inference, previous_inference)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
      ModelManager.reset()
      Enum.each(bundle.cache_paths, &File.rm_rf/1)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  test "execute/3 persists canonical endpoint instead of hardcoding chat", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-endpoint")

    canonical =
      canonical_request("request-orchestrator-endpoint", endpoint: :responses, stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.endpoint == :responses
    assert request.canonical_request["endpoint"] == "responses"
  end

  test "execute/3 persists multi-node schedule metadata and scheduler-selected node attribution",
       %{bundle: bundle} do
    put_multi_node_scheduler_config()

    model = create_active_model!(bundle, "request-orchestrator-multi-node")
    canonical = canonical_request("request-orchestrator-multi-node", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert request.scheduler_decision["strategy"] == "multi_node"
    assert request.scheduler_decision["candidate_count"] == 2
    assert request.scheduler_decision["selected_tier"] == "loaded"
    assert request.scheduler_decision["node_id"] == scheduled_node_id()
  end

  test "execute/3 overwrites scheduler-selected node attribution with runtime-resolved node id",
       %{bundle: bundle} do
    put_multi_node_scheduler_config()

    runtime_node_id = Orchard.Node.node_id()
    refute runtime_node_id == scheduled_node_id()

    model = create_active_model!(bundle, "request-orchestrator-multi-node")
    canonical = canonical_request("request-orchestrator-multi-node", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert request.scheduler_decision["node_id"] == scheduled_node_id()
    assert request.node_id == runtime_node_id
    refute request.node_id == request.scheduler_decision["node_id"]
  end

  test "execute/3 persists success payload attrs for completed non-stream requests", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-success")
    canonical = canonical_request("request-orchestrator-success", stream?: false)

    success_persistence = fn canonical_request, events ->
      %{
        response_payload: %{id: canonical_request.public_id},
        response_preview: joined_preview(events)
      }
    end

    assert {:ok, ^canonical, _events} =
             RequestOrchestrator.execute(canonical, model,
               success_persistence: success_persistence
             )

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :completed
    assert request.response_payload == %{"id" => canonical.public_id}
    assert request.response_preview != nil
  end

  test "execute/3 skips success payload persistence for streaming requests", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-stream")
    canonical = canonical_request("request-orchestrator-stream", stream?: true)

    success_persistence = fn canonical_request, _events ->
      %{
        response_payload: %{id: canonical_request.public_id},
        response_preview: "should-not-persist"
      }
    end

    assert {:ok, ^canonical, _events} =
             RequestOrchestrator.execute(canonical, model,
               success_persistence: success_persistence
             )

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.stream == true
    assert request.response_payload == nil
    assert request.response_preview == nil
  end

  test "execute/3 returns an error before insert when canonical serialization fails", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-serialization")

    canonical =
      canonical_request("request-orchestrator-serialization",
        stream?: false,
        metadata: %{bad: %URI{scheme: "file", path: "/tmp/test"}}
      )

    assert {:error, {:canonical_request_serialization_failed, _message}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 replays an existing completed request after idempotency insert conflict", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-idem-replay")
    tenant_id = Ecto.UUID.generate()
    key = "req-orch-replay"
    params = %{"model" => "request-orchestrator-idem-replay@v1"}
    {:ok, idempotency} = Idempotency.build_context(tenant_id, key, params)

    existing =
      create_request!(%{
        public_id: "req_existing_replay",
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: idempotency.body_hash,
        stream: false,
        state: :completed,
        requested_model: "request-orchestrator-idem-replay@v1",
        response_payload: %{"id" => "req_existing_replay"}
      })

    existing_id = existing.id

    canonical =
      canonical_request("request-orchestrator-idem-replay",
        tenant_id: tenant_id,
        public_id: "req_new_replay"
      )

    assert {:replay, %{id: ^existing_id}} =
             RequestOrchestrator.execute(canonical, model, idempotency: idempotency)

    assert length(Orchard.Repo.all(Orchard.Requests.Request)) == 1
  end

  test "execute/3 returns idempotency conflict after insert race with active request", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-idem-active")
    tenant_id = Ecto.UUID.generate()
    key = "req-orch-active"
    params = %{"model" => "request-orchestrator-idem-active@v1"}
    {:ok, idempotency} = Idempotency.build_context(tenant_id, key, params)

    create_request!(%{
      public_id: "req_existing_active",
      tenant_id: tenant_id,
      idempotency_key: key,
      body_hash: idempotency.body_hash,
      state: :running,
      requested_model: "request-orchestrator-idem-active@v1"
    })

    canonical =
      canonical_request("request-orchestrator-idem-active",
        tenant_id: tenant_id,
        public_id: "req_new_active"
      )

    assert {:error, {:idempotency_conflict, :request_in_progress}} =
             RequestOrchestrator.execute(canonical, model, idempotency: idempotency)

    assert length(Orchard.Repo.all(Orchard.Requests.Request)) == 1
  end

  test "execute/3 persists first_token_at for successful requests with output", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-success")
    canonical = canonical_request("request-orchestrator-success", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :completed
    assert request.first_token_at != nil
    assert request.completed_at != nil
    assert DateTime.compare(request.completed_at, request.first_token_at) in [:gt, :eq]
  end

  test "execute/3 leaves first_token_at nil when dispatch fails before any output delta", %{
    bundle: bundle
  } do
    put_unreachable_scheduler_config()

    model = create_active_model!(bundle, "request-orchestrator-start-failure")
    canonical = canonical_request("request-orchestrator-start-failure", stream?: false)

    assert {:error, {:model_load_failed, _}} = RequestOrchestrator.execute(canonical, model)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request != nil
    assert request.state == :failed
    assert request.first_token_at == nil
  end

  test "execute/3 persists tooling provenance while forwarding resolved tool params only", %{
    bundle: bundle
  } do
    put_capturing_runtime_adapter_config()

    model =
      create_active_model!(bundle, "request-orchestrator-tooling",
        capabilities: ["chat", "tool_calling"]
      )

    tools = [
      %{
        "type" => "function",
        "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
      }
    ]

    requested_tools = [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}]

    tool_id = Ecto.UUID.generate()

    registry_snapshot = %{
      entries: [
        %{
          tool_id: tool_id,
          ref: "tool://lookup_weather@2026-04-10",
          name: "lookup_weather",
          version: "2026-04-10",
          execution_mode: "client_only",
          source_kind: "manual",
          source_ref: nil
        }
      ]
    }

    canonical =
      canonical_request("request-orchestrator-tooling",
        stream?: false,
        stop: ["</tool_call>"],
        max_output_tokens: 24,
        tooling: %{
          tools: tools,
          requested_tools: requested_tools,
          tool_choice: "auto",
          registry_snapshot: registry_snapshot
        }
      )

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}
    assert execute_request.params.max_output_tokens == 24
    assert execute_request.params.stop_sequences == ["</tool_call>"]
    assert Jason.decode!(execute_request.params.tools_json) == tools
    assert Jason.decode!(execute_request.params.tool_choice_json) == "auto"

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert request.canonical_request["tooling"] == %{
             "tools" => tools,
             "requested_tools" => requested_tools,
             "tool_choice" => "auto",
             "registry_snapshot" => %{
               "entries" => [
                 %{
                   "tool_id" => tool_id,
                   "ref" => "tool://lookup_weather@2026-04-10",
                   "name" => "lookup_weather",
                   "version" => "2026-04-10",
                   "execution_mode" => "client_only",
                   "source_kind" => "manual",
                   "source_ref" => nil
                 }
               ]
             }
           }
  end

  test "execute/3 rejects unresolved requested tool refs before insert", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-unresolved-requested-tools")

    canonical =
      canonical_request("request-orchestrator-unresolved-requested-tools",
        stream?: false,
        tooling: %{
          tools: [],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          tool_choice: "auto",
          registry_snapshot: %{entries: []}
        }
      )

    assert {:error,
            {:invalid_canonical_tooling, "tool registry refs must be resolved before execute/3"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects unresolved ref-only runtime tools before insert", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-unresolved-runtime-tools")

    canonical =
      canonical_request("request-orchestrator-unresolved-runtime-tools",
        stream?: false,
        tooling: %{
          tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "tooling.tools must contain resolved function definitions only"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects runtime tools that include both function and ref before insert", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-mixed-runtime-tools")

    canonical =
      canonical_request("request-orchestrator-mixed-runtime-tools",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "ref" => "tool://lookup_weather@2026-04-10",
              "function" => %{"name" => "lookup_weather"}
            }
          ],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "tooling.tools must contain resolved function definitions only"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects requested tool refs with mismatched registry snapshots before insert",
       %{
         bundle: bundle
       } do
    model = create_active_model!(bundle, "request-orchestrator-mismatched-registry-snapshot")

    canonical =
      canonical_request("request-orchestrator-mismatched-registry-snapshot",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://other_weather@2026-04-10",
                name: "other_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling, "tool registry refs must be resolved before execute/3"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects ref-backed requests with matching snapshot but empty runtime tools before insert",
       %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-empty-runtime-tools")

    canonical =
      canonical_request("request-orchestrator-empty-runtime-tools",
        stream?: false,
        tooling: %{
          tools: [],
          requested_tools: [%{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "requested_tools, registry_snapshot, and tooling.tools must stay aligned"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects incomplete runtime tools when requested_tools is present before insert",
       %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-incomplete-runtime-tools")

    canonical =
      canonical_request("request-orchestrator-incomplete-runtime-tools",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          requested_tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            },
            %{"type" => "function", "ref" => "tool://summarize_text@2026-04-10"}
          ],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://summarize_text@2026-04-10",
                name: "summarize_text",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "requested_tools, registry_snapshot, and tooling.tools must stay aligned"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects wrong-order runtime tools when requested_tools is present before insert",
       %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-wrong-order-runtime-tools")

    canonical =
      canonical_request("request-orchestrator-wrong-order-runtime-tools",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "summarize_text", "description" => "Summarize text"}
            },
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          requested_tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            },
            %{"type" => "function", "ref" => "tool://summarize_text@2026-04-10"}
          ],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://summarize_text@2026-04-10",
                name: "summarize_text",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "requested_tools, registry_snapshot, and tooling.tools must stay aligned"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects inline-only requested tools with registry snapshot provenance before insert",
       %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-inline-only-snapshot")

    canonical =
      canonical_request("request-orchestrator-inline-only-snapshot",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          requested_tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "requested_tools, registry_snapshot, and tooling.tools must stay aligned"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects malformed mixed requested tool entries before insert", %{
    bundle: bundle
  } do
    model = create_active_model!(bundle, "request-orchestrator-mixed-requested-tool")

    canonical =
      canonical_request("request-orchestrator-mixed-requested-tool",
        stream?: false,
        tooling: %{
          tools: [
            %{
              "type" => "function",
              "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
            }
          ],
          requested_tools: [
            %{
              "type" => "function",
              "ref" => "tool://lookup_weather@2026-04-10",
              "function" => %{}
            }
          ],
          tool_choice: "auto",
          registry_snapshot: %{
            entries: [
              %{
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                tool_id: Ecto.UUID.generate()
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "requested_tools, registry_snapshot, and tooling.tools must stay aligned"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 preserves legacy runtime-only tooling when requested_tools is empty", %{
    bundle: bundle
  } do
    put_capturing_runtime_adapter_config()

    model =
      create_active_model!(bundle, "request-orchestrator-legacy-runtime-tools",
        capabilities: ["chat", "tool_calling"]
      )

    tools = [
      %{
        "type" => "function",
        "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
      }
    ]

    canonical =
      canonical_request("request-orchestrator-legacy-runtime-tools",
        stream?: false,
        tooling: %{
          tools: tools,
          requested_tools: [],
          tool_choice: "auto",
          registry_snapshot: %{entries: []}
        }
      )

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}
    assert Jason.decode!(execute_request.params.tools_json) == tools
    assert Jason.decode!(execute_request.params.tool_choice_json) == "auto"
  end

  test "execute/3 keeps tooling fields empty for non-tool requests", %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-no-tooling")
    canonical = canonical_request("request-orchestrator-no-tooling", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}
    assert execute_request.params.tools_json == ""
    assert execute_request.params.tool_choice_json == ""
  end

  defp put_multi_node_scheduler_config do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.merge(
        runtime_client_targets: [
          [host: "127.0.0.1", port: 50_071],
          [host: "127.0.0.2", port: 50_072]
        ],
        scheduler_impl: Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp put_unreachable_scheduler_config do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.merge(
        scheduler_impl: Orchard.Inference.RequestOrchestratorTest.StubUnreachableScheduler
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp scheduled_node_id do
    StubMultiNodeScheduler.scheduled_node_id()
  end

  defp canonical_request(model_id, overrides) do
    endpoint = Keyword.get(overrides, :endpoint, :chat_completions)
    stream? = Keyword.get(overrides, :stream?, false)
    metadata = Keyword.get(overrides, :metadata, %{})
    tenant_id = Keyword.get(overrides, :tenant_id, Ecto.UUID.generate())
    public_id = Keyword.get(overrides, :public_id, "req_#{System.unique_integer([:positive])}")
    stop = Keyword.get(overrides, :stop, [])
    max_output_tokens = Keyword.get(overrides, :max_output_tokens)
    tooling = Keyword.get(overrides, :tooling, %{})

    CanonicalRequest.new(%{
      internal_id: Ecto.UUID.generate(),
      public_id: public_id,
      endpoint: endpoint,
      tenant_id: tenant_id,
      api_key_id: Ecto.UUID.generate(),
      model_ref: %{model_id: model_id, version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 1,
      stream?: stream?,
      sampling: %{temperature: 1.0, top_p: 1.0, stop: stop, max_output_tokens: max_output_tokens},
      response_format: %{type: :text},
      tooling: tooling,
      metadata: metadata
    })
  end

  defp joined_preview(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map_join("", & &1.event.delta)
  end

  defp create_active_model!(bundle, model_id, overrides \\ []) do
    attrs =
      %{
        model_id: model_id,
        version: "v1",
        display_name: model_id,
        artifact_uri: "file:///tmp/#{model_id}",
        artifact_sha256: bundle.hash,
        artifact_source_uri: "file://#{bundle.source_path}",
        state: :active,
        format: "mlx",
        backend: "mlx",
        capabilities: ["chat"],
        artifact_size_bytes: 1024,
        resident_memory_bytes: 2048,
        kv_cache_bytes_per_token: 128,
        prefill_workspace_bytes_per_token: 64,
        max_context_tokens: 131_072
      }
      |> Map.merge(Enum.into(overrides, %{}))

    {:ok, model} = Orchard.Models.create_model(attrs)
    model
  end

  defp put_capturing_runtime_adapter_config do
    runtime =
      Application.fetch_env!(:orchard_node_agent, :runtime)
      |> Keyword.merge(
        runtime_adapter_impl: Orchard.Inference.RequestOrchestratorTest.CapturingRuntimeAdapter
      )

    Application.put_env(:orchard_node_agent, :runtime, runtime)
    ModelManager.reset()
  end

  defp stage_test_bundle! do
    models_root = Node.models_root()
    source_path = Path.join([models_root, ".test-source", "request-orchestrator-bundle"])

    File.rm_rf(source_path)
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    model_ids = [
      {"request-orchestrator-endpoint", "v1"},
      {"request-orchestrator-multi-node", "v1"},
      {"request-orchestrator-success", "v1"},
      {"request-orchestrator-stream", "v1"},
      {"request-orchestrator-serialization", "v1"},
      {"request-orchestrator-start-failure", "v1"},
      {"request-orchestrator-idem-replay", "v1"},
      {"request-orchestrator-idem-active", "v1"}
    ]

    cache_paths =
      Enum.map(model_ids, fn {model_id, version} ->
        cache_path = Path.join([models_root, model_id, version])
        File.rm_rf(cache_path)
        File.mkdir_p!(cache_path)
        :ok = ArtifactBundle.copy_directory(source_path, cache_path)
        cache_path
      end)

    %{hash: hash, source_path: source_path, cache_paths: cache_paths}
  end
end
