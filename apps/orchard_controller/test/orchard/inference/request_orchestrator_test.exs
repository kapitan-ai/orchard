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

defmodule Orchard.Inference.RequestOrchestratorTest.StubCacheAffinityScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.merge(schedule, %{
         cache_affinity_enabled: true,
         cache_affinity_key: "hmac-sha256:#{String.duplicate("c", 64)}",
         cache_affinity_hint_available: true,
         cache_affinity_selected_match: true,
         cache_affinity_source: "recent_completed_request",
         cache_affinity_candidate_count: 1,
         selected_cache_tier: "warm_prefix"
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.merge(schedule, %{
         prefix_cache_status: %{
           model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
           implementation: "kv",
           enabled: true,
           entry_count: 3,
           total_bytes: 32_768,
           hits: 12,
           misses: 4,
           failures: 99,
           stores: 8,
           evictions: 1,
           configured_max_entries: 16,
           configured_max_bytes: 0,
           status_code: "ok",
           status_message: "active",
           session_started_unix_ms: 1_713_726_400_000,
           prefix_cache_fingerprints: ["hmac-sha256:#{String.duplicate("a", 64)}"],
           prompt_fingerprint: "must-not-persist"
         },
         prefix_cache_fingerprint_match?: true,
         selected_prefix_cache_status_code: "leaked",
         selected_prefix_cache_prompt_fingerprint: "must-not-persist"
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubMemoryScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.merge(schedule, %{
         memory_admission_enabled: true,
         memory_admission_tier: "headroom_unknown",
         memory_budget: %{
           model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "active",
           target_working_set_bytes: 32_768,
           resident_memory_bytes: 16_384,
           estimated_headroom_bytes: 16_384,
           kv_cache_bytes_per_token: 2,
           prefill_workspace_bytes_per_token: 3,
           overhead_bytes: 99
         },
         selected_memory_status_code: "leaked",
         selected_memory_status_message: "must-not-persist"
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubMemoryUnavailableScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.merge(schedule, %{
         memory_admission_enabled: true,
         memory_admission_tier: "headroom_unavailable",
         memory_budget: %{
           model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
           mode: "observe",
           budget_available: true,
           headroom_available: false,
           status_code: "resident_memory_unavailable",
           target_working_set_bytes: 32_768,
           resident_memory_bytes: 0,
           estimated_headroom_bytes: 0
         }
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubMemoryTierOnlyScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.merge(schedule, %{
         memory_admission_enabled: true,
         memory_admission_tier: "headroom_ok"
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheUnavailableScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.put(schedule, :prefix_cache_status, %{
         model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
         implementation: "kv",
         enabled: true,
         entry_count: 3,
         total_bytes: 32_768,
         status_code: "unavailable",
         session_started_unix_ms: 1_713_726_400_000
       })}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScoreScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       schedule
       |> Map.put(:prefix_cache_score, %{
         status_code: "ok",
         status_message:
           "request req_123 hmac-sha256:#{String.duplicate("d", 64)} /tmp/orchard tokens: [1,2,3]",
         resident_fingerprint_match: true,
         score_tier: "no_match",
         session_started_unix_ms: 1_713_726_400_123
       })
       |> Map.put("prefix_cache_score", %{
         "status_code" => "ok",
         "status_message" => "must not persist",
         "resident_fingerprint_match" => true,
         "score_tier" => "resident_fingerprint",
         "session_started_unix_ms" => 999
       })
       |> Map.put(:selected_prefix_cache_score_tier, "leaked")
       |> Map.put(:selected_prefix_cache_score_status_message, "must-not-persist")}
    end
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubPromotedPrefixCacheScoreScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference

  @promoted_node_id "00000000-0000-4000-a000-000000000222"

  def promoted_node_id, do: @promoted_node_id

  def schedule(%CanonicalRequest{} = request) do
    {:ok,
     %{
       strategy: :multi_node,
       request_id: request.public_id,
       runtime_client_target: Inference.runtime_client_target(),
       request_timeout_ms: Inference.request_timeout_ms(),
       model_load_timeout_ms: Inference.model_load_timeout_ms(),
       node_id: @promoted_node_id,
       candidate_count: 2,
       selected_tier: "cold",
       cache_affinity_enabled: true,
       cache_affinity_key: "hmac-sha256:#{String.duplicate("f", 64)}",
       cache_affinity_hint_available: false,
       cache_affinity_selected_match: false,
       cache_affinity_source: "none",
       cache_affinity_candidate_count: 0,
       selected_cache_tier: "no_hint",
       prefix_cache_fingerprint_match?: false,
       prefix_cache_status: %{
         model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
         implementation: "kv",
         enabled: true,
         entry_count: 77,
         total_bytes: 7_700,
         hits: 7,
         misses: 0,
         stores: 3,
         evictions: 0,
         status_code: "ok",
         session_started_unix_ms: 1_713_726_400_222,
         prefix_cache_fingerprints: []
       },
       memory_admission_enabled: true,
       memory_admission_tier: "headroom_unavailable",
       memory_budget: %{
         model_ref: %{model_id: request.model_ref.model_id, version: request.model_ref.version},
         mode: "observe",
         budget_available: true,
         headroom_available: false,
         status_code: "resident_memory_unavailable",
         target_working_set_bytes: 32_768,
         resident_memory_bytes: 0,
         estimated_headroom_bytes: 0
       },
       prefix_cache_score: %{
         status_code: "ok",
         status_message: "promoted resident challenger selected",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint",
         session_started_unix_ms: 222
       },
       selected_prefix_cache_score_status_message: "incumbent-selected-score-leak",
       selected_prefix_cache_entry_count: 1,
       selected_memory_status_code: "incumbent-memory-leak"
     }
     |> Map.put("prefix_cache_score", %{
       "status_code" => "ok",
       "status_message" => "incumbent must not persist",
       "resident_fingerprint_match" => false,
       "score_tier" => "no_match",
       "session_started_unix_ms" => 111
     })}
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScoreUnavailableScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    with {:ok, schedule} <- StubMultiNodeScheduler.schedule(request) do
      {:ok,
       Map.put(schedule, :prefix_cache_score, %{
         status_code: "timeout",
         status_message:
           "Traceback req_999 hmac-sha256:#{String.duplicate("e", 64)} /private/tmp/orchard",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint",
         session_started_unix_ms: 1_713_726_400_987
       })}
    end
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

defmodule Orchard.Inference.RequestOrchestratorTest.StubLiveCapacityScheduler do
  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler

  def schedule(%CanonicalRequest{} = request) do
    owner = Application.fetch_env!(:orchard_controller, :request_orchestrator_live_capacity_owner)
    send(owner, {:live_capacity_schedule_attempt, self(), request.public_id})

    receive do
      {:live_capacity_schedule_reply, reply} ->
        reply
    after
      1_000 ->
        {:error, :cluster_busy}
    end
  end

  def schedule_success(%CanonicalRequest{} = request),
    do: StubMultiNodeScheduler.schedule(request)
end

defmodule Orchard.Inference.RequestOrchestratorTest.CapturingRuntimeAdapter do
  @behaviour Orchard.Node.RuntimeAdapter

  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.InferenceEvent

  @impl true
  def get_status(_adapter_state, _opts),
    do:
      {:ok, %{ready: true, health_code: "", health_message: "", supports_prompt_token_ids: true}}

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

    runtime_events =
      Application.get_env(
        :orchard_node_agent,
        :request_orchestrator_test_runtime_events,
        default_runtime_events(request)
      )

    Enum.each(runtime_events, fn event ->
      send(owner, {:runtime_adapter_event, generation_ref, event})
    end)

    send(owner, {:runtime_adapter_done, generation_ref})

    {:ok, generation_ref, adapter_state}
  end

  @impl true
  def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

  @impl true
  def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state

  defp default_runtime_events(request) do
    [
      InferenceEvent.completed(
        :finish_reason_stop,
        %InferenceEvent.Usage{
          input_tokens: request.input_tokens,
          output_tokens: 0,
          total_tokens: request.input_tokens
        }
      )
    ]
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.PreAwaitTerminalQueueManager do
  @moduledoc false

  alias Orchard.Inference.QueueManager
  alias Orchard.Requests
  alias Orchard.Requests.RequestServer

  def acquire(request) do
    queue_key = "#{request.model_id}@#{request.version}"
    queued_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    ticket_ref = make_ref()
    result = pre_await_result(queue_key, queued_at)

    terminalize_request(request.request_id, result)
    Process.put({__MODULE__, ticket_ref}, result.await_result)

    {:queued,
     %QueueManager.Ticket{
       server: __MODULE__,
       ticket_ref: ticket_ref,
       queue_key: queue_key,
       queued_at: queued_at,
       enqueued_monotonic_ms: System.monotonic_time(:millisecond),
       max_wait_ms: 1
     }}
  end

  def await(%QueueManager.Ticket{} = ticket) do
    Process.delete({__MODULE__, ticket.ticket_ref})
  end

  def abandon(%QueueManager.Ticket{} = ticket) do
    Process.delete({__MODULE__, ticket.ticket_ref})
    :ok
  end

  def release(_grant), do: :ok

  defp pre_await_result(queue_key, queued_at) do
    queue_result =
      Application.fetch_env!(
        :orchard_controller,
        :request_orchestrator_pre_await_queue_result
      )

    case queue_result do
      :queue_timeout -> timeout_result(queue_key, queued_at)
      :request_caller_disconnect -> disconnect_result(queue_key, queued_at)
    end
  end

  defp timeout_result(queue_key, queued_at) do
    metadata =
      :queue_timeout
      |> QueueManager.error_metadata(queue_key, 1)
      |> Map.put(:queued_at, queued_at)

    %{
      await_result: {:error, :queue_timeout, metadata},
      metadata: metadata,
      transition: :timed_out,
      terminal_attrs: %{
        state: :timed_out,
        http_status: 504,
        error_code: "queue_timeout",
        error_message: "Request timed out while waiting for admission"
      }
    }
  end

  defp disconnect_result(queue_key, queued_at) do
    metadata =
      :interrupted_before_dispatch
      |> QueueManager.error_metadata(queue_key, 1)
      |> Map.put(:queued_at, queued_at)

    %{
      await_result: {:error, :request_caller_disconnect, metadata},
      metadata: metadata,
      transition: :cancelled,
      terminal_attrs: %{
        state: :cancelled,
        error_code: "request_caller_disconnect",
        error_message: "Caller disconnected before admission"
      }
    }
  end

  defp terminalize_request(request_id, result) do
    {:ok, _request} = Requests.record_schedule(request_id, result.metadata)
    :ok = RequestServer.transition(request_id, result.transition)

    {:ok, _request} =
      request_id |> Requests.get_request!() |> Requests.mark_terminal(result.terminal_attrs)
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.RecordingQueueManager do
  @moduledoc false

  alias Orchard.Inference.QueueManager

  def acquire(request), do: QueueManager.acquire(request)
  def await(ticket), do: QueueManager.await(ticket)
  def abandon(ticket), do: QueueManager.abandon(ticket)
  def release(grant), do: QueueManager.release(grant)
  def requeue(grant, request), do: QueueManager.requeue(grant, request)
  def mark_capacity_source_observed(grant), do: QueueManager.mark_capacity_source_observed(grant)

  def mark_grant_node(grant, node_id) do
    if pid = Process.whereis(:request_orchestrator_test_pid) do
      send(pid, {:recording_queue_mark_grant_node, grant.grant_id, node_id})
    end

    QueueManager.mark_grant_node(grant, node_id)
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.ExitingObservationQueueManager do
  @moduledoc false

  alias Orchard.Inference.QueueManager

  def acquire(request), do: QueueManager.acquire(request)
  def await(ticket), do: QueueManager.await(ticket)
  def abandon(ticket), do: QueueManager.abandon(ticket)
  def release(grant), do: QueueManager.release(grant)
  def requeue(grant, request), do: QueueManager.requeue(grant, request)
  def mark_grant_node(grant, node_id), do: QueueManager.mark_grant_node(grant, node_id)

  def mark_capacity_source_observed(_grant) do
    exit(
      {:noproc,
       {GenServer, :call, [Orchard.Inference.QueueManager, :mark_capacity_source_observed, 5_000]}}
    )
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest.ExitingGrantNodeQueueManager do
  @moduledoc false

  alias Orchard.Inference.QueueManager

  def acquire(request), do: QueueManager.acquire(request)
  def await(ticket), do: QueueManager.await(ticket)
  def abandon(ticket), do: QueueManager.abandon(ticket)
  def release(grant), do: QueueManager.release(grant)
  def requeue(grant, request), do: QueueManager.requeue(grant, request)
  def mark_capacity_source_observed(grant), do: QueueManager.mark_capacity_source_observed(grant)

  def mark_grant_node(_grant, _node_id) do
    exit({:noproc, {GenServer, :call, [Orchard.Inference.QueueManager, :mark_grant_node, 5_000]}})
  end
end

defmodule Orchard.Inference.RequestOrchestratorTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.SentryContextHelpers

  import Orchard.TestSupport.QueueAdmissionAPI,
    only: [assert_queue_metadata: 2, assert_queue_metadata: 3]

  alias Orchard.Inference.RequestOrchestratorTest.StubCacheAffinityScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubLiveCapacityScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubMemoryScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubMemoryTierOnlyScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubMemoryUnavailableScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubMultiNodeScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScheduler
  alias Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheUnavailableScheduler

  alias Orchard.ArtifactBundle
  alias Orchard.CanonicalRequest
  alias Orchard.Inference.CacheAffinity
  alias Orchard.Inference.QueueManager
  alias Orchard.Inference.RequestOrchestrator
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Requests
  alias Orchard.Requests.Idempotency
  alias Orchard.Requests.RequestServer

  setup :setup_sentry_context

  setup do
    ModelManager.reset()
    QueueManager.reset()
    bundle = stage_test_bundle!()
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    previous_runtime_events =
      Application.get_env(:orchard_node_agent, :request_orchestrator_test_runtime_events)

    previous_pre_await_queue_result =
      Application.get_env(:orchard_controller, :request_orchestrator_pre_await_queue_result)

    previous_live_capacity_owner =
      Application.get_env(:orchard_controller, :request_orchestrator_live_capacity_owner)

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
      restore_runtime_events(previous_runtime_events)
      restore_pre_await_queue_result(previous_pre_await_queue_result)
      restore_live_capacity_owner(previous_live_capacity_owner)
      QueueManager.reset()
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

  test "Sentry controller enrichment records request lifecycle breadcrumbs and public request extra",
       %{bundle: bundle} do
    put_multi_node_scheduler_config()
    enable_controller_sentry()

    model = create_active_model!(bundle, "request-orchestrator-sentry-lifecycle")

    canonical =
      canonical_request("request-orchestrator-sentry-lifecycle",
        endpoint: :responses,
        stream?: true,
        tooling: %{tools: [lookup_weather_tool_definition()], tool_choice: "auto"}
      )

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    context = sentry_context()

    assert context.extra.orchard_request_id == request.public_id
    assert context.extra.orchard_db_request_id == request.public_id
    assert context.extra.orchard_endpoint == :responses
    assert context.extra.orchard_stream == true
    assert context.extra.orchard_tooling == true
    assert context.extra.orchard_model_id == "request-orchestrator-sentry-lifecycle"
    assert context.extra.orchard_model_version == "v1"

    assert context.tags.orchard_app == "controller"
    assert context.tags.orchard_surface == "api"
    assert context.tags.orchard_endpoint == "responses"
    assert context.tags.stream == "true"
    assert context.tags.tooling == "true"
    assert context.tags.scheduler_strategy == "multi_node"

    assert breadcrumb_messages() == [
             "request.validated",
             "request.persisted",
             "request.scheduled",
             "node.resolved",
             "ensure_model_load.started",
             "ensure_model_load.completed",
             "first_delta.received"
           ]

    scheduled = Enum.find(context.breadcrumbs, &(&1.message == "request.scheduled"))

    assert scheduled.data == %{
             scheduler_strategy: :multi_node,
             node_hash: Orchard.SentryContext.hash_id(scheduled_node_id())
           }

    resolved = Enum.find(context.breadcrumbs, &(&1.message == "node.resolved"))
    assert is_binary(resolved.data.node_hash)
    refute inspect(context) =~ scheduled_node_id()
  end

  test "execute/3 does not emit Sentry persisted breadcrumb for idempotency replay", %{
    bundle: bundle
  } do
    enable_controller_sentry()
    model = create_active_model!(bundle, "request-orchestrator-idem-replay")
    tenant_id = Ecto.UUID.generate()
    key = "req-orch-replay-sentry"
    params = %{"model" => "request-orchestrator-idem-replay@v1"}
    {:ok, idempotency} = Idempotency.build_context(tenant_id, key, params)

    existing =
      create_request!(%{
        public_id: "req_existing_replay_sentry",
        tenant_id: tenant_id,
        idempotency_key: key,
        body_hash: idempotency.body_hash,
        stream: false,
        state: :completed,
        requested_model: "request-orchestrator-idem-replay@v1",
        response_payload: %{"id" => "req_existing_replay_sentry"}
      })

    canonical =
      canonical_request("request-orchestrator-idem-replay",
        tenant_id: tenant_id,
        public_id: "req_new_replay_sentry"
      )

    existing_id = existing.id

    assert {:replay, %{id: ^existing_id}} =
             RequestOrchestrator.execute(canonical, model, idempotency: idempotency)

    assert "request.validated" in breadcrumb_messages()
    refute "request.persisted" in breadcrumb_messages()
    refute Map.has_key?(sentry_context().extra, :orchard_request_id)
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

  test "execute/3 persists sanitized prefix-cache scheduler fields only when enabled", %{
    bundle: bundle
  } do
    put_prefix_cache_scheduler_config(enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-multi-node")
    canonical = canonical_request("request-orchestrator-multi-node", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["selected_prefix_cache_status_code"] == "ok"
    assert decision["selected_prefix_cache_enabled"] == true
    assert decision["selected_prefix_cache_implementation"] == "kv"
    assert decision["selected_prefix_cache_entry_count"] == 3
    assert decision["selected_prefix_cache_total_bytes"] == 32_768
    assert decision["selected_prefix_cache_hits"] == 12
    assert decision["selected_prefix_cache_misses"] == 4
    assert decision["selected_prefix_cache_stores"] == 8
    assert decision["selected_prefix_cache_evictions"] == 1
    assert decision["selected_prefix_cache_session_started_unix_ms"] == 1_713_726_400_000
    assert decision["selected_prefix_cache_fingerprint_count"] == 1
    assert decision["selected_prefix_cache_warmth_indicator"] == true
    assert decision["selected_prefix_cache_fingerprint_match"] == true

    refute Map.has_key?(decision, "prefix_cache_status")
    refute Map.has_key?(decision, "selected_prefix_cache_failures")
    refute Map.has_key?(decision, "selected_prefix_cache_status_message")
    refute Map.has_key?(decision, "selected_prefix_cache_configured_max_entries")
    refute Map.has_key?(decision, "selected_prefix_cache_prompt_fingerprint")
    refute Map.has_key?(decision, "selected_prefix_cache_fingerprints")
    refute inspect(decision) =~ "prompt_fingerprint"
    refute inspect(decision) =~ "hmac-sha256"
  end

  test "execute/3 strips prefix-cache scheduler metadata when introspection disabled", %{
    bundle: bundle
  } do
    put_prefix_cache_scheduler_config(enabled: false)

    model = create_active_model!(bundle, "request-orchestrator-multi-node")
    canonical = canonical_request("request-orchestrator-multi-node", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    refute Map.has_key?(decision, "prefix_cache_status")
    refute Enum.any?(Map.keys(decision), &String.starts_with?(&1, "selected_prefix_cache_"))
  end

  test "execute/3 persists only status and enabled for non-ok prefix-cache status", %{
    bundle: bundle
  } do
    put_prefix_cache_unavailable_scheduler_config(enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-multi-node")
    canonical = canonical_request("request-orchestrator-multi-node", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["selected_prefix_cache_status_code"] == "unavailable"
    assert decision["selected_prefix_cache_enabled"] == true
    refute Map.has_key?(decision, "selected_prefix_cache_entry_count")
    refute Map.has_key?(decision, "selected_prefix_cache_total_bytes")
    refute Map.has_key?(decision, "selected_prefix_cache_session_started_unix_ms")
  end

  test "execute/3 persists sanitized selected-prefix-cache-score fields when both gates are enabled",
       %{
         bundle: bundle
       } do
    put_prefix_cache_score_scheduler_config(
      cache_introspection_enabled: true,
      prefix_cache_scoring_enabled: true
    )

    model = create_active_model!(bundle, "request-orchestrator-prefix-cache-score")
    canonical = canonical_request("request-orchestrator-prefix-cache-score", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["selected_prefix_cache_score_status_code"] == "ok"
    assert decision["selected_prefix_cache_score_tier"] == "unknown"
    assert decision["selected_prefix_cache_score_resident_fingerprint_match"] == false
    assert decision["selected_prefix_cache_score_session_started_unix_ms"] == 1_713_726_400_123
    assert decision["selected_prefix_cache_score_source"] == "score_prefix_cache_rpc"

    refute Map.has_key?(decision, "prefix_cache_score")
    assert is_binary(decision["selected_prefix_cache_score_status_message"])
    refute decision["selected_prefix_cache_score_status_message"] == "must-not-persist"

    refute inspect(decision) =~ "hmac-sha256"
    refute inspect(decision) =~ "/tmp/orchard"
    refute inspect(decision) =~ "req_123"
  end

  test "execute/3 strips selected-prefix-cache-score fields when scoring gate is disabled", %{
    bundle: bundle
  } do
    put_prefix_cache_score_scheduler_config(
      cache_introspection_enabled: true,
      prefix_cache_scoring_enabled: false
    )

    model = create_active_model!(bundle, "request-orchestrator-prefix-cache-score-disabled")

    canonical =
      canonical_request("request-orchestrator-prefix-cache-score-disabled", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    refute Map.has_key?(decision, "prefix_cache_score")

    refute Enum.any?(
             Map.keys(decision),
             &String.starts_with?(&1, "selected_prefix_cache_score_")
           )
  end

  test "execute/3 persists promoted winner metadata and final selected score only", %{
    bundle: bundle
  } do
    promoted_scheduler =
      Orchard.Inference.RequestOrchestratorTest.StubPromotedPrefixCacheScoreScheduler

    put_prefix_cache_score_scheduler_config(
      scheduler: promoted_scheduler,
      cache_introspection_enabled: true,
      prefix_cache_scoring_enabled: true,
      memory_admission_enabled: true
    )

    model = create_active_model!(bundle, "request-orchestrator-promoted-score")
    canonical = canonical_request("request-orchestrator-promoted-score", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["strategy"] == "multi_node"
    assert decision["node_id"] == promoted_scheduler.promoted_node_id()
    assert decision["runtime_client_target"] == %{"host" => "127.0.0.1", "port" => 50_071}
    assert decision["selected_tier"] == "cold"
    assert decision["selected_cache_tier"] == "no_hint"
    assert decision["cache_affinity_selected_match"] == false
    assert decision["selected_prefix_cache_status_code"] == "ok"
    assert decision["selected_prefix_cache_entry_count"] == 77
    assert decision["selected_prefix_cache_total_bytes"] == 7_700
    assert decision["selected_prefix_cache_fingerprint_match"] == false
    assert decision["memory_admission_tier"] == "headroom_unavailable"
    assert decision["selected_memory_status_code"] == "resident_memory_unavailable"
    assert decision["selected_memory_headroom_available"] == false
    refute Map.has_key?(decision, "selected_memory_resident_memory_bytes")
    assert decision["selected_prefix_cache_score_status_code"] == "ok"
    assert decision["selected_prefix_cache_score_tier"] == "resident_fingerprint"
    assert decision["selected_prefix_cache_score_resident_fingerprint_match"] == true
    assert decision["selected_prefix_cache_score_session_started_unix_ms"] == 222
    assert decision["selected_prefix_cache_score_source"] == "score_prefix_cache_rpc"

    refute Map.has_key?(decision, "prefix_cache_score")
    refute Map.has_key?(decision, "prefix_cache_status")
    refute Map.has_key?(decision, "memory_budget")
    refute inspect(decision) =~ "incumbent must not persist"
    refute inspect(decision) =~ "incumbent-selected-score-leak"
    refute inspect(decision) =~ "incumbent-memory-leak"
  end

  test "execute/3 persists bounded non-ok selected-prefix-cache-score diagnostics only", %{
    bundle: bundle
  } do
    put_prefix_cache_score_scheduler_config(
      scheduler:
        Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScoreUnavailableScheduler,
      cache_introspection_enabled: true,
      prefix_cache_scoring_enabled: true
    )

    model = create_active_model!(bundle, "request-orchestrator-prefix-cache-score-timeout")

    canonical =
      canonical_request("request-orchestrator-prefix-cache-score-timeout", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["selected_prefix_cache_score_status_code"] == "timeout"
    assert decision["selected_prefix_cache_score_tier"] == "unknown"

    assert decision["selected_prefix_cache_score_status_message"] ==
             "prefix cache scoring timed out"

    assert decision["selected_prefix_cache_score_source"] == "score_prefix_cache_rpc"
    refute Map.has_key?(decision, "selected_prefix_cache_score_resident_fingerprint_match")
    refute Map.has_key?(decision, "selected_prefix_cache_score_session_started_unix_ms")
    refute inspect(decision) =~ "hmac-sha256"
    refute inspect(decision) =~ "/private/tmp"
    refute inspect(decision) =~ "req_999"
  end

  test "execute/3 derives memory-admission tier from raw budget before persistence", %{
    bundle: bundle
  } do
    put_memory_scheduler_config(enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-memory-admission")
    canonical = canonical_request("request-orchestrator-memory-admission", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["memory_admission_enabled"] == true
    # The scheduler stub deliberately supplies a stale/incorrect tier; persistence must trust
    # the raw memory budget normalization instead.
    assert decision["memory_admission_tier"] == "headroom_ok"
    assert decision["selected_memory_status_code"] == "ok"
    assert decision["selected_memory_budget_available"] == true
    assert decision["selected_memory_headroom_available"] == true
    assert decision["selected_memory_target_working_set_bytes"] == 32_768
    assert decision["selected_memory_resident_memory_bytes"] == 16_384
    assert decision["selected_memory_estimated_headroom_bytes"] == 16_384
    assert decision["selected_memory_kv_cache_bytes_per_token"] == 2
    assert decision["selected_memory_prefill_workspace_bytes_per_token"] == 3

    refute Map.has_key?(decision, "memory_budget")
    refute Map.has_key?(decision, "memory_headroom_ok?")
    refute Map.has_key?(decision, "selected_memory_status_message")
    refute Map.has_key?(decision, "selected_memory_overhead_bytes")
    refute inspect(decision) =~ "must-not-persist"
  end

  test "execute/3 does not trust scheduler-supplied memory tier without raw budget", %{
    bundle: bundle
  } do
    put_memory_scheduler_config(StubMemoryTierOnlyScheduler, enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-memory-admission")
    canonical = canonical_request("request-orchestrator-memory-admission", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["memory_admission_enabled"] == true
    assert decision["memory_admission_tier"] == "headroom_unknown"
    refute Enum.any?(Map.keys(decision), &String.starts_with?(&1, "selected_memory_"))
  end

  test "execute/3 strips memory-admission scheduler metadata when disabled", %{
    bundle: bundle
  } do
    put_memory_scheduler_config(enabled: false)

    model = create_active_model!(bundle, "request-orchestrator-memory-admission")
    canonical = canonical_request("request-orchestrator-memory-admission", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    refute Map.has_key?(decision, "memory_budget")
    refute Map.has_key?(decision, "memory_admission_enabled")
    refute Map.has_key?(decision, "memory_admission_tier")
    refute Enum.any?(Map.keys(decision), &String.starts_with?(&1, "selected_memory_"))
  end

  test "execute/3 persists only status and booleans for non-ok memory status", %{
    bundle: bundle
  } do
    put_memory_unavailable_scheduler_config(enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-memory-admission")
    canonical = canonical_request("request-orchestrator-memory-admission", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert decision["memory_admission_enabled"] == true
    assert decision["memory_admission_tier"] == "headroom_unavailable"
    assert decision["selected_memory_status_code"] == "resident_memory_unavailable"
    assert decision["selected_memory_budget_available"] == true
    assert decision["selected_memory_headroom_available"] == false
    refute Map.has_key?(decision, "selected_memory_target_working_set_bytes")
    refute Map.has_key?(decision, "selected_memory_resident_memory_bytes")
    refute Map.has_key?(decision, "selected_memory_estimated_headroom_bytes")
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

  test "execute/3 reconciles queue grant from scheduler node before dispatch", %{
    bundle: bundle
  } do
    put_multi_node_scheduler_config()
    put_queue_admission_config(enabled: true, capacity: 1, max_wait_ms: 1_000)
    put_recording_queue_manager()

    model = create_active_model!(bundle, "request-orchestrator-queue-schedule-node")
    canonical = canonical_request("request-orchestrator-queue-schedule-node", stream?: false)
    scheduled_node_id = scheduled_node_id()

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)
    assert_received {:recording_queue_mark_grant_node, _grant_id, ^scheduled_node_id}
  end

  test "execute/3 assigns resolved node when queue grant reconciliation exits", %{
    bundle: bundle
  } do
    put_multi_node_scheduler_config()
    put_queue_admission_config(enabled: true, capacity: 1, max_wait_ms: 1_000)
    put_exiting_grant_node_queue_manager()

    runtime_node_id = Orchard.Node.node_id()
    model = create_active_model!(bundle, "request-orchestrator-node-reconcile-exit")
    canonical = canonical_request("request-orchestrator-node-reconcile-exit", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.node_id == runtime_node_id
  end

  test "execute/3 forwards Accepted event when source observation exits", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, capacity: 1, max_wait_ms: 1_000)
    put_exiting_observation_queue_manager()

    model = create_active_model!(bundle, "request-orchestrator-accepted-observation-exit")
    canonical = canonical_request("request-orchestrator-accepted-observation-exit", stream?: true)
    test_pid = self()

    handler = fn _request_id, event ->
      send(test_pid, {:downstream_event, InferenceEvent.kind(event)})
      :ok
    end

    assert {:ok, ^canonical, events} =
             RequestOrchestrator.execute(canonical, model, event_handler: handler)

    assert Enum.any?(events, &(InferenceEvent.kind(&1) == :accepted))
    assert_receive {:downstream_event, :accepted}
  end

  test "queue admission disabled preserves legacy validated to scheduled flow", %{bundle: bundle} do
    put_queue_admission_config(enabled: false)

    model = create_active_model!(bundle, "request-orchestrator-queue-legacy")
    canonical = canonical_request("request-orchestrator-queue-legacy", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert :validated in states
    assert :scheduled in states
    refute :admitted in states
    refute :queued in states
    refute Map.has_key?(request.scheduler_decision, "queueing_enabled")
  end

  test "queue admission enabled records immediate grant metadata before dispatch", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true)

    model = create_active_model!(bundle, "request-orchestrator-queue-immediate")
    canonical = canonical_request("request-orchestrator-queue-immediate", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert state_before?(states, :validated, :admitted)
    assert state_before?(states, :admitted, :scheduled)
    refute :queued in states

    assert_queue_metadata(request, "immediate", granted?: true)
  end

  test "granted queue admission persists queue and cache-affinity scheduler metadata", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true)
    put_cache_affinity_scheduler_config()

    model = create_active_model!(bundle, "request-orchestrator-queue-cache-affinity")
    canonical = canonical_request("request-orchestrator-queue-cache-affinity", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    decision = request.scheduler_decision

    assert_queue_metadata(request, "immediate", granted?: true)
    assert decision["cache_affinity_enabled"] == true
    assert decision["cache_affinity_hint_available"] == true
    assert decision["cache_affinity_selected_match"] == true
    assert decision["cache_affinity_source"] == "recent_completed_request"
    assert decision["cache_affinity_candidate_count"] == 1
    assert decision["selected_cache_tier"] == "warm_prefix"
  end

  test "queue admission acquire restart does not leave orchestrator admitted", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true)
    put_capturing_runtime_adapter_config()

    manager_pid = GenServer.whereis(QueueManager)
    model = create_active_model!(bundle, "request-orchestrator-queue-acquire-restart")
    canonical = canonical_request("request-orchestrator-queue-acquire-restart", stream?: false)

    :ok = :sys.suspend(QueueManager)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)
    assert wait_until(fn -> request_state(canonical.public_id) == :admitted end)

    Process.exit(manager_pid, :kill)
    assert wait_until(fn -> manager_restarted?(QueueManager, manager_pid) end)

    assert {:error, :request_controller_restarted} = Task.await(task, 2_000)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert request.state == :interrupted
    assert request.error_code == "request_controller_restarted"
    refute :scheduled in states
    assert_queue_metadata(request, "interrupted_controller_restarted")
  end

  test "queue admission enabled waits in queued state then schedules after grant", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, max_wait_ms: 1_000)

    model = create_active_model!(bundle, "request-orchestrator-queue-wait")
    canonical = canonical_request("request-orchestrator-queue-wait", stream?: false)

    assert {:ok, held_grant} = hold_queue_lane(canonical)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)
    assert wait_until(fn -> request_state(canonical.public_id) == :queued end)

    queued_request = Requests.get_request_by_public_id(canonical.public_id)
    assert_queue_metadata(queued_request, "queued", queued?: true)

    assert :ok = QueueManager.release(held_grant)
    assert {:ok, ^canonical, events} = Task.await(task, 2_000)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert state_before?(states, :admitted, :queued)
    assert state_before?(states, :queued, :scheduled)
    assert_queue_metadata(request, "queued", queued?: true, granted?: true)
  end

  test "queue admission capacity two schedules two active requests and queues overflow", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, capacity: 2, max_wait_ms: 1_000)

    model = create_active_model!(bundle, "request-orchestrator-queue-capacity-two")
    canonical = canonical_request("request-orchestrator-queue-capacity-two", stream?: false)

    assert {:ok, first_grant} = hold_queue_lane(canonical)
    assert {:ok, second_grant} = hold_queue_lane(canonical)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)

    try do
      assert wait_until(fn -> request_state(canonical.public_id) == :queued end)

      queued_request = Requests.get_request_by_public_id(canonical.public_id)
      assert_queue_metadata(queued_request, "queued", queued?: true)

      assert :ok = QueueManager.release(first_grant)
      assert {:ok, ^canonical, events} = Task.await(task, 2_000)
      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      request = Requests.get_request_by_public_id(canonical.public_id)
      states = request_event_states(request)

      assert state_before?(states, :admitted, :queued)
      assert state_before?(states, :queued, :scheduled)
      assert_queue_metadata(request, "queued", queued?: true, granted?: true)
    after
      QueueManager.release(first_grant)
      QueueManager.release(second_grant)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "SPEC.md §5.3 tenant active cap queues despite spare model lane capacity", %{
    bundle: bundle
  } do
    put_queue_admission_config(
      enabled: true,
      capacity: 2,
      max_active_per_tenant: 1,
      max_wait_ms: 1_000
    )

    model = create_active_model!(bundle, "request-orchestrator-tenant-active-cap")
    canonical = canonical_request("request-orchestrator-tenant-active-cap", stream?: false)

    assert {:ok, held_grant} = hold_queue_lane(canonical)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)

    try do
      assert wait_until(fn -> request_state(canonical.public_id) == :queued end)

      queued_request = Requests.get_request_by_public_id(canonical.public_id)
      assert_queue_metadata(queued_request, "queued", queued?: true)
      refute :scheduled in request_event_states(queued_request)

      assert :ok = QueueManager.release(held_grant)
      assert {:ok, ^canonical, events} = Task.await(task, 2_000)
      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      request = Requests.get_request_by_public_id(canonical.public_id)
      states = request_event_states(request)

      assert state_before?(states, :queued, :scheduled)
      assert_queue_metadata(request, "queued", queued?: true, granted?: true)
    after
      QueueManager.release(held_grant)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "SPEC.md §5.3 resolved tenant active policy limits queue admission", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, capacity: 2, max_wait_ms: 1_000)

    model = create_active_model!(bundle, "request-orchestrator-policy-tenant-active-cap")

    canonical =
      canonical_request("request-orchestrator-policy-tenant-active-cap",
        stream?: false,
        resolved_policy: %{max_active_requests: 1}
      )

    assert {:ok, held_grant} = hold_queue_lane(canonical)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)

    try do
      assert wait_until(fn -> request_state(canonical.public_id) == :queued end)

      queued_request = Requests.get_request_by_public_id(canonical.public_id)
      assert_queue_metadata(queued_request, "queued", queued?: true)
      refute :scheduled in request_event_states(queued_request)

      assert :ok = QueueManager.release(held_grant)
      assert {:ok, ^canonical, events} = Task.await(task, 2_000)
      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      request = Requests.get_request_by_public_id(canonical.public_id)
      states = request_event_states(request)

      assert state_before?(states, :queued, :scheduled)
      assert_queue_metadata(request, "queued", queued?: true, granted?: true)
    after
      QueueManager.release(held_grant)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "queue admission returns queue_full before scheduling when tenant cap is exhausted", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, max_queued_per_tenant: 0)

    model = create_active_model!(bundle, "request-orchestrator-queue-full")
    canonical = canonical_request("request-orchestrator-queue-full", stream?: false)

    assert {:ok, held_grant} = hold_queue_lane(canonical)
    assert {:error, :queue_full} = RequestOrchestrator.execute(canonical, model)
    assert :ok = QueueManager.release(held_grant)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :failed
    assert request.http_status == 429
    assert request.error_code == "queue_full"
    assert_queue_metadata(request, "queue_full")
    refute :scheduled in request_event_states(request)
  end

  test "queue admission returns queue_timeout from queued state without scheduling", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true, max_wait_ms: 10)

    model = create_active_model!(bundle, "request-orchestrator-queue-timeout")
    canonical = canonical_request("request-orchestrator-queue-timeout", stream?: false)

    assert {:ok, held_grant} = hold_queue_lane(canonical)
    assert {:error, :queue_timeout} = RequestOrchestrator.execute(canonical, model)
    assert :ok = QueueManager.release(held_grant)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :timed_out
    assert request.http_status == 504
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)
    refute :scheduled in request_event_states(request)

    refute Enum.any?(
             Map.keys(request.scheduler_decision || %{}),
             &String.starts_with?(&1, "selected_prefix_cache_score_")
           )
  end

  test "pre-await queue terminalization surfaces original queue outcome", %{bundle: bundle} do
    put_queue_admission_config(enabled: true)
    put_pre_await_terminal_queue_manager()
    put_capturing_runtime_adapter_config()

    cases = [
      {:queue_timeout, :timed_out, "queue_timeout", "queue_timeout"},
      {:request_caller_disconnect, :cancelled, "request_caller_disconnect",
       "interrupted_before_dispatch"}
    ]

    Enum.each(cases, fn {result, state, error_code, queue_result} ->
      Application.put_env(
        :orchard_controller,
        :request_orchestrator_pre_await_queue_result,
        result
      )

      model_id = "request-orchestrator-pre-await-#{result}"
      model = create_active_model!(bundle, model_id)
      canonical = canonical_request(model_id, stream?: false)

      assert {:error, ^result} = RequestOrchestrator.execute(canonical, model)
      refute_receive {:captured_execute_request, _request}

      request = Requests.get_request_by_public_id(canonical.public_id)
      assert request.state == state
      assert request.error_code == error_code
      assert_queue_metadata(request, queue_result, queued?: true)
      refute :scheduled in request_event_states(request)
    end)
  end

  test "post-grant pre-schedule caller disconnect releases grant and never dispatches", %{
    bundle: bundle
  } do
    put_queue_admission_config(enabled: true)
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-queue-disconnect")
    canonical = canonical_request("request-orchestrator-queue-disconnect", stream?: false)

    caller = spawn(fn -> :ok end)
    assert wait_until(fn -> not Process.alive?(caller) end)

    assert {:error, :request_caller_disconnect} =
             RequestOrchestrator.execute(canonical, model, caller: caller)

    refute_receive {:captured_execute_request, _request}

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :cancelled
    assert request.error_code == "request_caller_disconnect"
    assert_queue_metadata(request, "interrupted_before_dispatch", granted?: true)
    refute :scheduled in request_event_states(request)

    assert {:ok, next_grant} = hold_queue_lane(canonical)
    assert :ok = QueueManager.release(next_grant)
  end

  test "queue admission requeues post-grant cluster_busy then schedules when live capacity returns",
       %{bundle: bundle} do
    put_queue_admission_config(enabled: true, max_wait_ms: 2_000, poll_interval_ms: 500)
    put_live_capacity_scheduler_config()
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-live-capacity-requeue")
    canonical = canonical_request("request-orchestrator-live-capacity-requeue", stream?: false)
    public_id = canonical.public_id

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)

    assert {:live_capacity_schedule_attempt, scheduler_pid, ^public_id} = live_capacity_attempt()

    send(scheduler_pid, {:live_capacity_schedule_reply, {:error, :cluster_busy}})
    assert wait_until(fn -> request_state(canonical.public_id) == :queued end)
    refute_receive {:captured_execute_request, _request}, 50

    queued_request = Requests.get_request_by_public_id(canonical.public_id)
    assert_queue_metadata(queued_request, "queued", queued?: true)
    refute Map.has_key?(queued_request.scheduler_decision || %{}, "queue_grant_id")

    assert {:live_capacity_schedule_attempt, retry_scheduler_pid, ^public_id} =
             live_capacity_attempt(1_500)

    assert {:ok, schedule} = StubLiveCapacityScheduler.schedule_success(canonical)

    send(retry_scheduler_pid, {:live_capacity_schedule_reply, {:ok, schedule}})

    assert_receive {:captured_execute_request, _request}, 500
    assert {:ok, ^canonical, events} = Task.await(task, 2_000)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert state_before?(states, :admitted, :queued)
    assert state_before?(states, :queued, :scheduled)
    assert_queue_metadata(request, "queued", queued?: true, granted?: true)

    assert {:ok, next_grant} = hold_queue_lane(canonical)
    assert :ok = QueueManager.release(next_grant)
  end

  test "queue admission requeues post-grant model_busy then schedules when live capacity returns",
       %{bundle: bundle} do
    put_queue_admission_config(enabled: true, max_wait_ms: 2_000, poll_interval_ms: 500)
    put_live_capacity_scheduler_config()
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-single-node-capacity-requeue")

    canonical =
      canonical_request("request-orchestrator-single-node-capacity-requeue", stream?: false)

    public_id = canonical.public_id

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)

    assert {:live_capacity_schedule_attempt, scheduler_pid, ^public_id} = live_capacity_attempt()

    send(scheduler_pid, {:live_capacity_schedule_reply, {:error, :model_busy}})
    assert wait_until(fn -> request_state(canonical.public_id) == :queued end)
    refute_receive {:captured_execute_request, _request}, 50

    queued_request = Requests.get_request_by_public_id(canonical.public_id)
    assert_queue_metadata(queued_request, "queued", queued?: true)
    refute Map.has_key?(queued_request.scheduler_decision || %{}, "queue_grant_id")

    assert {:live_capacity_schedule_attempt, retry_scheduler_pid, ^public_id} =
             live_capacity_attempt(1_500)

    assert {:ok, schedule} = StubLiveCapacityScheduler.schedule_success(canonical)

    send(retry_scheduler_pid, {:live_capacity_schedule_reply, {:ok, schedule}})

    assert_receive {:captured_execute_request, _request}, 500
    assert {:ok, ^canonical, events} = Task.await(task, 2_000)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    states = request_event_states(request)

    assert state_before?(states, :admitted, :queued)
    assert state_before?(states, :queued, :scheduled)
    assert_queue_metadata(request, "queued", queued?: true, granted?: true)

    assert {:ok, next_grant} = hold_queue_lane(canonical)
    assert :ok = QueueManager.release(next_grant)
  end

  test "queue admission times out post-grant cluster_busy without dispatching", %{bundle: bundle} do
    put_queue_admission_config(enabled: true, max_wait_ms: 60, poll_interval_ms: 10)
    put_live_capacity_scheduler_config()
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-live-capacity-timeout")
    canonical = canonical_request("request-orchestrator-live-capacity-timeout", stream?: false)

    task = Task.async(fn -> RequestOrchestrator.execute(canonical, model) end)
    assert {:error, :queue_timeout} = reply_cluster_busy_until_done(task, canonical.public_id)
    refute_receive {:captured_execute_request, _request}

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert request.state == :timed_out
    assert request.http_status == 504
    assert request.error_code == "queue_timeout"
    assert_queue_metadata(request, "queue_timeout", queued?: true)
    refute :scheduled in request_event_states(request)

    assert {:ok, next_grant} = hold_queue_lane(canonical)
    assert :ok = QueueManager.release(next_grant)
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

  test "execute/3 persists inference-turn started and completed request_step events around dispatch",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-step-success")
    canonical = canonical_request("request-orchestrator-step-success", stream?: false)
    step_event_appender = started_only_step_event_appender(self())

    assert {:ok, ^canonical, events} =
             RequestOrchestrator.execute(canonical, model,
               step_event_appender: step_event_appender
             )

    assert Enum.any?(events, &InferenceEvent.terminal?/1)
    refute_receive {:unexpected_terminal_step_appender_call, _step_events}

    request = Requests.get_request_by_public_id(canonical.public_id)
    step_events = Requests.list_request_step_events(request)

    assert Enum.map(step_events, &{&1.event_type, &1.step_type, &1.boundary, &1.step_id}) == [
             {"request_step.started", "inference_turn", "pre_side_effect",
              "inference_turn:t1:a1"},
             {"request_step.completed", "inference_turn", "post_observation",
              "inference_turn:t1:a1"}
           ]

    assert Enum.map(step_events, & &1.result) == [
             %{},
             %{
               "finish_reason" => "stop",
               "http_status" => 200,
               "input_tokens" => 1,
               "output_tokens" => 0
             }
           ]
  end

  test "execute/3 aborts before dispatch side effects when request_step.started persistence fails",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-step-start-failure")
    canonical = canonical_request("request-orchestrator-step-start-failure", stream?: false)

    step_event_appender = fn _request, _step_events -> {:error, :request_not_found} end

    assert {:error, {:request_step_start_failed, :request_not_found}} =
             RequestOrchestrator.execute(canonical, model,
               step_event_appender: step_event_appender
             )

    refute_receive {:captured_execute_request, _request}

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request != nil
    assert request.state == :failed
    assert Requests.list_request_step_events(request) == []
  end

  test "execute/3 persists terminal inference-turn step mappings distinctly for failed, cancelled, timed_out, and interrupted terminals",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    cases = [
      {"tool_choice_not_satisfied", "tool choice not satisfied", :failed, "request_step.failed"},
      {"request_cancelled", "request was cancelled", :cancelled, "request_step.cancelled"},
      {"deadline_exceeded", "request timed out", :timed_out, "request_step.timed_out"},
      {"request_client_disconnect", "caller disconnected", :interrupted,
       "request_step.interrupted"}
    ]

    Enum.each(cases, fn {code, message, expected_state, expected_event_type} ->
      put_runtime_events([InferenceEvent.failed(code, message, false)])

      model = create_active_model!(bundle, "request-orchestrator-terminal-#{expected_state}")

      canonical =
        canonical_request("request-orchestrator-terminal-#{expected_state}", stream?: false)

      step_event_appender = started_only_step_event_appender(self())

      assert {:ok, ^canonical, events} =
               RequestOrchestrator.execute(canonical, model,
                 step_event_appender: step_event_appender
               )

      assert match?(%{event: %InferenceEvent.Failed{code: ^code}}, List.last(events))
      refute_receive {:unexpected_terminal_step_appender_call, _step_events}

      request = Requests.get_request_by_public_id(canonical.public_id)
      assert request.state == expected_state

      step_events = Requests.list_request_step_events(request)

      assert Enum.map(step_events, & &1.event_type) == [
               "request_step.started",
               expected_event_type
             ]

      terminal_step = List.last(step_events)
      assert terminal_step.result["error_code"] == request.error_code
      assert terminal_step.result["error_message"] == request.error_message
      assert terminal_step.result["http_status"] == request.http_status
    end)
  end

  test "execute/3 persists passive tool-call proposal steps in first-seen assembled order only",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    put_runtime_events([
      InferenceEvent.tool_call_delta(
        "call_b",
        Jason.encode!(%{
          index: 1,
          type: "function",
          function: %{name: "lookup_weather", arguments_delta: "{\"city\":\"Singapore\"}"}
        })
      ),
      InferenceEvent.tool_call_delta(
        "call_a",
        Jason.encode!(%{
          index: 0,
          type: "function",
          function: %{name: "lookup_time", arguments_delta: "{\"timezone\":\"Asia/Singapore\"}"}
        })
      ),
      InferenceEvent.completed(
        :finish_reason_tool_calls,
        %InferenceEvent.Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}
      )
    ])

    model =
      create_active_model!(bundle, "request-orchestrator-tool-proposals",
        capabilities: ["chat", "tool_calling"]
      )

    canonical = canonical_request("request-orchestrator-tool-proposals", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)
    step_events = Requests.list_request_step_events(request)

    assert Enum.map(step_events, &{&1.event_type, &1.step_type, &1.step_id}) == [
             {"request_step.started", "inference_turn", "inference_turn:t1:a1"},
             {"request_step.proposed", "tool_call", "tool_call:t1:ccall_b"},
             {"request_step.proposed", "tool_call", "tool_call:t1:ccall_a"},
             {"request_step.completed", "inference_turn", "inference_turn:t1:a1"}
           ]

    assert Enum.map(step_events, & &1.call_id) == [nil, "call_b", "call_a", nil]
    assert Enum.map(step_events, & &1.tool_name) == [nil, "lookup_weather", "lookup_time", nil]

    assert Enum.map(step_events, & &1.arguments_json) == [
             nil,
             "{\"city\":\"Singapore\"}",
             "{\"timezone\":\"Asia/Singapore\"}",
             nil
           ]

    refute Enum.any?(step_events, &(&1.step_type == "tool_execution"))
  end

  test "execute/3 skips request_step.proposed persistence when tool-call reconstruction is malformed without changing execution result",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    put_runtime_events([
      InferenceEvent.tool_call_delta("call_0", "not-json"),
      InferenceEvent.completed(
        :finish_reason_tool_calls,
        %InferenceEvent.Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}
      )
    ])

    model =
      create_active_model!(bundle, "request-orchestrator-malformed-tool-proposals",
        capabilities: ["chat", "tool_calling"]
      )

    canonical = canonical_request("request-orchestrator-malformed-tool-proposals", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started",
             "request_step.completed"
           ]
  end

  test "execute/3 surfaces terminal persistence failures after successful dispatch and leaves FSM non-terminal",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-terminal-persist-success-failure")

    canonical =
      canonical_request("request-orchestrator-terminal-persist-success-failure", stream?: false)

    terminal_persister = fn _request, _terminal_attrs, _step_events ->
      {:error, :terminal_write_failed}
    end

    assert {:error, {:terminal_persist_failed, :terminal_write_failed}} =
             RequestOrchestrator.execute(canonical, model, terminal_persister: terminal_persister)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :running

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started"
           ]

    assert {:ok, :running} = RequestServer.get_state(request.id)
  end

  test "execute/3 does not route observed terminal persistence failures back through fail_request/4",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-terminal-persist-no-refallback")

    canonical =
      canonical_request("request-orchestrator-terminal-persist-no-refallback", stream?: false)

    test_pid = self()

    terminal_persister = fn request, terminal_attrs, step_events ->
      case terminal_attrs.state do
        :completed ->
          {:error, :observed_terminal_write_failed}

        :failed ->
          send(test_pid, {:unexpected_fail_request_terminalization, request.id, step_events})
          Requests.mark_terminal_with_step_events(request, terminal_attrs, step_events)
      end
    end

    assert {:error, {:terminal_persist_failed, :observed_terminal_write_failed}} =
             RequestOrchestrator.execute(canonical, model, terminal_persister: terminal_persister)

    refute_receive {:unexpected_fail_request_terminalization, _, _}

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :running

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started"
           ]

    assert {:ok, :running} = RequestServer.get_state(request.id)
  end

  test "execute/3 terminalizes via fail_request when success_persistence fails before terminal writes",
       %{bundle: bundle} do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-success-persistence-failure")

    canonical =
      canonical_request("request-orchestrator-success-persistence-failure", stream?: false)

    step_event_appender = started_only_step_event_appender(self())

    assert {:error, {:invalid_success_persistence, :not_a_map}} =
             RequestOrchestrator.execute(canonical, model,
               success_persistence: fn _canonical_request, _events -> :not_a_map end,
               step_event_appender: step_event_appender
             )

    refute_receive {:unexpected_terminal_step_appender_call, _step_events}

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :failed

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started",
             "request_step.failed"
           ]
  end

  test "execute/3 surfaces terminal persistence failures on dispatch-error failure paths and leaves FSM non-terminal",
       %{bundle: bundle} do
    put_unreachable_scheduler_config()

    model = create_active_model!(bundle, "request-orchestrator-terminal-persist-failure-path")

    canonical =
      canonical_request("request-orchestrator-terminal-persist-failure-path", stream?: false)

    terminal_persister = fn _request, _terminal_attrs, _step_events ->
      {:error, :terminal_write_failed}
    end

    assert {:error, {:terminal_persist_failed, :terminal_write_failed}} =
             RequestOrchestrator.execute(canonical, model, terminal_persister: terminal_persister)

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :dispatching

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started"
           ]

    assert {:ok, :dispatching} = RequestServer.get_state(request.id)
  end

  test "execute/3 persists failed terminal inference-turn steps on dispatch-error paths without using step_event_appender",
       %{bundle: bundle} do
    put_unreachable_scheduler_config()

    model = create_active_model!(bundle, "request-orchestrator-dispatch-error-terminal-step")

    canonical =
      canonical_request("request-orchestrator-dispatch-error-terminal-step", stream?: false)

    step_event_appender = started_only_step_event_appender(self())

    assert {:error, {:model_load_failed, _}} =
             RequestOrchestrator.execute(canonical, model,
               step_event_appender: step_event_appender
             )

    refute_receive {:unexpected_terminal_step_appender_call, _step_events}

    request = Requests.get_request_by_public_id(canonical.public_id)
    assert request.state == :failed

    assert Enum.map(Requests.list_request_step_events(request), & &1.event_type) == [
             "request_step.started",
             "request_step.failed"
           ]
  end

  test "execute/3 persists tooling provenance while forwarding resolved tool params only", %{
    bundle: bundle
  } do
    put_capturing_runtime_adapter_config()

    model =
      create_active_model!(bundle, "request-orchestrator-tooling",
        capabilities: ["chat", "tool_calling"]
      )

    tool_id = Ecto.UUID.generate()

    tools = [lookup_weather_tool_definition()]
    requested_tools = [lookup_weather_requested_ref()]
    registry_snapshot = lookup_weather_registry_snapshot(tool_id)
    execution_snapshot = lookup_weather_execution_snapshot()

    canonical =
      canonical_request("request-orchestrator-tooling",
        stream?: false,
        stop: ["</tool_call>"],
        max_output_tokens: 24,
        tooling: %{
          tools: tools,
          requested_tools: requested_tools,
          tool_choice: "auto",
          registry_snapshot: registry_snapshot,
          execution_snapshot: execution_snapshot
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
             },
             "execution_snapshot" => %{
               "entries" => [
                 %{
                   "name" => "lookup_weather",
                   "provenance" => "registry",
                   "disposition" => "client_passthrough",
                   "execution_mode" => "client_only"
                 }
               ]
             }
           }
  end

  test "execute/3 accepts tool_choice none with empty execution snapshot and empty runtime tool payloads",
       %{
         bundle: bundle
       } do
    put_capturing_runtime_adapter_config()

    model = create_active_model!(bundle, "request-orchestrator-tooling-none")
    tool_id = Ecto.UUID.generate()

    tools = [lookup_weather_tool_definition()]
    requested_tools = [lookup_weather_requested_ref()]
    registry_snapshot = lookup_weather_registry_snapshot(tool_id)

    canonical =
      canonical_request("request-orchestrator-tooling-none",
        stream?: false,
        tooling: %{
          tools: tools,
          requested_tools: requested_tools,
          tool_choice: "none",
          registry_snapshot: registry_snapshot,
          execution_snapshot: %{entries: []}
        }
      )

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}
    assert execute_request.params.tools_json == ""
    assert execute_request.params.tool_choice_json == ""

    request = Requests.get_request_by_public_id(canonical.public_id)

    assert request.canonical_request["tooling"] == %{
             "tools" => tools,
             "requested_tools" => requested_tools,
             "tool_choice" => "none",
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
             },
             "execution_snapshot" => %{"entries" => []}
           }
  end

  test "execute/3 rejects stale non-empty execution snapshots for tool_choice none before insert",
       %{
         bundle: bundle
       } do
    model = create_active_model!(bundle, "request-orchestrator-tooling-none-drift")

    canonical =
      canonical_request("request-orchestrator-tooling-none-drift",
        stream?: false,
        tooling: %{
          tools: [lookup_weather_tool_definition()],
          requested_tools: [lookup_weather_requested_ref()],
          tool_choice: "none",
          registry_snapshot: lookup_weather_registry_snapshot(Ecto.UUID.generate()),
          execution_snapshot: lookup_weather_execution_snapshot()
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "execution_snapshot must stay aligned with requested_tools, registry_snapshot, and tooling.tools"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
  end

  test "execute/3 rejects drifted execution snapshots before insert", %{bundle: bundle} do
    model = create_active_model!(bundle, "request-orchestrator-drifted-execution-snapshot")

    canonical =
      canonical_request("request-orchestrator-drifted-execution-snapshot",
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
                ref: "tool://lookup_weather@2026-04-10",
                name: "lookup_weather",
                version: "2026-04-10",
                execution_mode: "client_only",
                tool_id: Ecto.UUID.generate()
              }
            ]
          },
          execution_snapshot: %{
            entries: [
              %{
                name: "lookup_weather",
                provenance: "inline",
                disposition: "client_passthrough",
                execution_mode: "client_only"
              }
            ]
          }
        }
      )

    assert {:error,
            {:invalid_canonical_tooling,
             "execution_snapshot must stay aligned with requested_tools, registry_snapshot, and tooling.tools"}} =
             RequestOrchestrator.execute(canonical, model)

    assert Requests.get_request_by_public_id(canonical.public_id) == nil
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

  test "execute/3 includes controller prompt token ids in execute request", %{bundle: bundle} do
    put_capturing_runtime_adapter_config()
    put_tokenizer_safe_mode(:on)

    model = create_active_model!(bundle, "request-orchestrator-prompt-token-ids")

    canonical =
      "request-orchestrator-prompt-token-ids"
      |> canonical_request(stream?: false)
      |> CanonicalRequest.with_tokenization("hello token ids", 3, [101, 102, 103])

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}
    assert execute_request.prompt_token_ids == [101, 102, 103]
  end

  test "execute/3 injects cache-affinity fingerprint only when live matching is enabled", %{
    bundle: bundle
  } do
    put_capturing_runtime_adapter_config()

    put_cache_affinity_config(
      enabled: true,
      live_fingerprint_match_enabled: true,
      hmac_secret: "request-orchestrator-fingerprint-secret"
    )

    model = create_active_model!(bundle, "request-orchestrator-live-fingerprint")
    canonical = canonical_request("request-orchestrator-live-fingerprint", stream?: false)

    assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
    assert Enum.any?(events, &InferenceEvent.terminal?/1)

    assert_receive {:captured_execute_request, execute_request}

    assert {:ok, expected_fingerprint} =
             CacheAffinity.derive_key(canonical, Orchard.Inference.cache_affinity_config())

    assert execute_request.cache_affinity_fingerprint == expected_fingerprint
  end

  test "execute/3 omits cache-affinity fingerprint when parent or child flag is disabled", %{
    bundle: bundle
  } do
    put_capturing_runtime_adapter_config()

    [
      [enabled: false, live_fingerprint_match_enabled: true],
      [enabled: true, live_fingerprint_match_enabled: false]
    ]
    |> Enum.with_index()
    |> Enum.each(fn {cache_affinity, index} ->
      put_cache_affinity_config(
        Keyword.put(cache_affinity, :hmac_secret, "request-orchestrator-fingerprint-secret")
      )

      model_id = "request-orchestrator-live-fingerprint-disabled-#{index}"
      model = create_active_model!(bundle, model_id)
      canonical = canonical_request(model_id, stream?: false)

      assert {:ok, ^canonical, events} = RequestOrchestrator.execute(canonical, model)
      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      assert_receive {:captured_execute_request, execute_request}
      assert execute_request.cache_affinity_fingerprint in [nil, ""]
    end)
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

  defp put_live_capacity_scheduler_config do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.merge(scheduler_impl: StubLiveCapacityScheduler)

    Application.put_env(:orchard_controller, :inference, inference)
    Application.put_env(:orchard_controller, :request_orchestrator_live_capacity_owner, self())
  end

  defp put_cache_affinity_scheduler_config do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.merge(scheduler_impl: StubCacheAffinityScheduler)

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp put_cache_affinity_config(overrides) do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    cache_affinity =
      Orchard.Inference.cache_affinity_config()
      |> Keyword.merge(overrides)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :cache_affinity, cache_affinity)
    )
  end

  defp put_tokenizer_safe_mode(mode) do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    inference = Keyword.put(previous_inference, :tokenizer_safe_mode, mode)

    Application.put_env(:orchard_controller, :inference, inference)
    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous_inference) end)
  end

  defp put_prefix_cache_scheduler_config(overrides) do
    put_prefix_cache_scheduler_config(StubPrefixCacheScheduler, overrides)
  end

  defp put_prefix_cache_unavailable_scheduler_config(overrides) do
    put_prefix_cache_scheduler_config(StubPrefixCacheUnavailableScheduler, overrides)
  end

  defp put_memory_scheduler_config(overrides) do
    put_memory_scheduler_config(StubMemoryScheduler, overrides)
  end

  defp put_memory_unavailable_scheduler_config(overrides) do
    put_memory_scheduler_config(StubMemoryUnavailableScheduler, overrides)
  end

  defp put_prefix_cache_score_scheduler_config(overrides) do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    scheduler =
      Keyword.get(
        overrides,
        :scheduler,
        Orchard.Inference.RequestOrchestratorTest.StubPrefixCacheScoreScheduler
      )

    cache_affinity =
      Orchard.Inference.cache_affinity_config()
      |> Keyword.merge(enabled: true, live_fingerprint_match_enabled: true)

    cache_introspection =
      [enabled: Keyword.get(overrides, :cache_introspection_enabled, false)]

    prefix_cache_scoring =
      [enabled: Keyword.get(overrides, :prefix_cache_scoring_enabled, false), timeout_ms: 150]

    memory_admission = [enabled: Keyword.get(overrides, :memory_admission_enabled, false)]

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        scheduler_impl: scheduler,
        cache_affinity: cache_affinity,
        cache_introspection: cache_introspection,
        prefix_cache_scoring: prefix_cache_scoring,
        memory_admission: memory_admission
      )
    )
  end

  defp put_memory_scheduler_config(scheduler, overrides) do
    inference = Application.fetch_env!(:orchard_controller, :inference)
    memory_admission = Keyword.merge([enabled: false], overrides)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        scheduler_impl: scheduler,
        memory_admission: memory_admission
      )
    )
  end

  defp put_prefix_cache_scheduler_config(scheduler, overrides) do
    inference = Application.fetch_env!(:orchard_controller, :inference)
    cache_introspection = Keyword.merge([enabled: false], overrides)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        scheduler_impl: scheduler,
        cache_introspection: cache_introspection
      )
    )
  end

  defp put_queue_admission_config(overrides) do
    inference = Application.fetch_env!(:orchard_controller, :inference)
    overrides = acknowledge_single_controller_when_enabled(overrides)
    queue_config = Keyword.merge(Orchard.Inference.queue_admission_config(), overrides)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :queue_admission, queue_config)
    )
  end

  defp put_pre_await_terminal_queue_manager do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.put(
        :queue_manager_impl,
        Orchard.Inference.RequestOrchestratorTest.PreAwaitTerminalQueueManager
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp put_recording_queue_manager do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.put(
        :queue_manager_impl,
        Orchard.Inference.RequestOrchestratorTest.RecordingQueueManager
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp put_exiting_observation_queue_manager do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.put(
        :queue_manager_impl,
        Orchard.Inference.RequestOrchestratorTest.ExitingObservationQueueManager
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp put_exiting_grant_node_queue_manager do
    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.put(
        :queue_manager_impl,
        Orchard.Inference.RequestOrchestratorTest.ExitingGrantNodeQueueManager
      )

    Application.put_env(:orchard_controller, :inference, inference)
  end

  defp acknowledge_single_controller_when_enabled(overrides) do
    if Keyword.get(overrides, :enabled) == true do
      overrides
      |> Keyword.put_new(:single_controller_ack, true)
      |> Keyword.put_new(:owner_runtime, true)
    else
      overrides
    end
  end

  defp hold_queue_lane(canonical) do
    QueueManager.acquire(%{
      request_id: Ecto.UUID.generate(),
      public_id: "held_#{System.unique_integer([:positive])}",
      tenant_id: canonical.tenant_id,
      model_id: canonical.model_ref.model_id,
      version: canonical.model_ref.version,
      caller_pid: self()
    })
  end

  defp request_event_states(request) do
    request
    |> Requests.list_request_events()
    |> Enum.map(& &1.state)
    |> Enum.reject(&is_nil/1)
  end

  defp state_before?(states, first, second) do
    Enum.find_index(states, &(&1 == first)) < Enum.find_index(states, &(&1 == second))
  end

  defp request_state(public_id) do
    case Requests.get_request_by_public_id(public_id) do
      nil -> nil
      request -> request.state
    end
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp live_capacity_attempt(timeout \\ 500) do
    receive do
      {:live_capacity_schedule_attempt, _scheduler_pid, _public_id} = attempt -> attempt
    after
      timeout -> flunk("expected live capacity scheduler attempt")
    end
  end

  defp reply_cluster_busy_until_done(task, public_id) do
    deadline_ms = System.monotonic_time(:millisecond) + 1_000
    reply_cluster_busy_until_done(task, public_id, deadline_ms)
  end

  defp reply_cluster_busy_until_done(task, public_id, deadline_ms) do
    if System.monotonic_time(:millisecond) > deadline_ms do
      flunk("request did not complete while scheduler kept returning cluster_busy")
    end

    case Task.yield(task, 0) do
      {:ok, result} ->
        result

      nil ->
        receive do
          {:live_capacity_schedule_attempt, scheduler_pid, ^public_id} ->
            send(scheduler_pid, {:live_capacity_schedule_reply, {:error, :cluster_busy}})
        after
          20 ->
            :ok
        end

        reply_cluster_busy_until_done(task, public_id, deadline_ms)
    end
  end

  defp manager_restarted?(manager, previous_pid) do
    case GenServer.whereis(manager) do
      pid when is_pid(pid) and pid != previous_pid -> true
      _other -> false
    end
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
    resolved_policy = Keyword.get(overrides, :resolved_policy, %{})

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
      metadata: metadata,
      resolved_policy: resolved_policy
    })
  end

  defp joined_preview(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map_join("", & &1.event.delta)
  end

  defp lookup_weather_tool_definition do
    %{
      "type" => "function",
      "function" => %{"name" => "lookup_weather", "description" => "Lookup weather"}
    }
  end

  defp lookup_weather_requested_ref do
    %{"type" => "function", "ref" => "tool://lookup_weather@2026-04-10"}
  end

  defp lookup_weather_registry_snapshot(tool_id) do
    %{
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
  end

  defp lookup_weather_execution_snapshot do
    %{
      entries: [
        %{
          name: "lookup_weather",
          provenance: :registry,
          disposition: :client_passthrough,
          execution_mode: :client_only
        }
      ]
    }
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

  defp put_runtime_events(events) do
    Application.put_env(:orchard_node_agent, :request_orchestrator_test_runtime_events, events)
  end

  defp started_only_step_event_appender(test_pid) do
    fn request, step_events ->
      case step_events do
        [%{event_type: "request_step.started"}] ->
          Requests.append_request_step_events(request, step_events)

        _other ->
          send(test_pid, {:unexpected_terminal_step_appender_call, step_events})
          {:error, :unexpected_terminal_step_appender_call}
      end
    end
  end

  defp restore_runtime_events(nil),
    do: Application.delete_env(:orchard_node_agent, :request_orchestrator_test_runtime_events)

  defp restore_runtime_events(events),
    do:
      Application.put_env(:orchard_node_agent, :request_orchestrator_test_runtime_events, events)

  defp restore_pre_await_queue_result(nil),
    do: Application.delete_env(:orchard_controller, :request_orchestrator_pre_await_queue_result)

  defp restore_pre_await_queue_result(result),
    do:
      Application.put_env(
        :orchard_controller,
        :request_orchestrator_pre_await_queue_result,
        result
      )

  defp restore_live_capacity_owner(nil),
    do: Application.delete_env(:orchard_controller, :request_orchestrator_live_capacity_owner)

  defp restore_live_capacity_owner(owner),
    do:
      Application.put_env(
        :orchard_controller,
        :request_orchestrator_live_capacity_owner,
        owner
      )

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
      {"request-orchestrator-idem-active", "v1"},
      {"request-orchestrator-queue-legacy", "v1"},
      {"request-orchestrator-queue-immediate", "v1"},
      {"request-orchestrator-queue-cache-affinity", "v1"},
      {"request-orchestrator-queue-wait", "v1"},
      {"request-orchestrator-queue-full", "v1"},
      {"request-orchestrator-queue-timeout", "v1"},
      {"request-orchestrator-queue-disconnect", "v1"}
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
