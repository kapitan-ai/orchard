defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef, as: CanonicalModelRef
  alias Orchard.Cluster.V1.Accepted
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.Completed
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Cluster.V1.InferenceEvent, as: RPCInferenceEvent
  alias Orchard.Cluster.V1.ModelRef, as: RPCModelRef
  alias Orchard.Cluster.V1.NodeRuntimeService.Stub, as: NodeRuntimeStub
  alias Orchard.Cluster.V1.OutputTextDelta
  alias Orchard.Cluster.V1.StatusRequest
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.TokenUsage
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.InferenceEvent, as: OrchardInferenceEvent
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.RuntimeRequirements
  alias Orchard.ModelManifest.Tokenizer
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Node.SharedContract
  alias Orchard.Node.Status, as: NodeStatus
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.Node.WorkerSupervisor
  alias Orchard.NodeAgent.Supervisor, as: NodeAgentSupervisor

  @test_model_id "mlx-community/phi-3"
  @test_version "main"

  defmodule BlockingRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.InferenceEvent

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
      owner = Keyword.fetch!(opts, :owner)
      generation_ref = make_ref()

      {:ok, pid} =
        Task.start(fn ->
          receive do
            {:release, ^generation_ref} ->
              usage = %InferenceEvent.Usage{
                input_tokens: request.input_tokens,
                output_tokens: 1,
                total_tokens: request.input_tokens + 1
              }

              send(
                owner,
                {:runtime_adapter_event, generation_ref,
                 InferenceEvent.output_text_delta("released")}
              )

              send(
                owner,
                {:runtime_adapter_event, generation_ref,
                 InferenceEvent.completed(:finish_reason_stop, usage)}
              )

              send(owner, {:runtime_adapter_done, generation_ref})
          after
            30_000 -> :ok
          end
        end)

      generations =
        Map.put(adapter_state.generations, generation_ref, %{pid: pid, owner: owner})

      {:ok, generation_ref, %{adapter_state | generations: generations}}
    end

    @impl true
    def cancel_generation(adapter_state, generation_ref, _opts) do
      case Map.pop(adapter_state.generations, generation_ref) do
        {nil, _generations} ->
          {:ok, adapter_state}

        {%{pid: pid, owner: owner}, generations} ->
          Process.exit(pid, :kill)

          send(
            owner,
            {:runtime_adapter_event, generation_ref,
             InferenceEvent.failed("cancelled", "request cancelled", false)}
          )

          send(owner, {:runtime_adapter_done, generation_ref})
          {:ok, %{adapter_state | generations: generations}}
      end
    end

    @impl true
    def finish_generation(adapter_state, generation_ref, _opts) do
      generations = Map.delete(adapter_state.generations, generation_ref)
      %{adapter_state | generations: generations}
    end
  end

  defmodule LoadTimeoutCapturingAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.InferenceEvent

    @impl true
    def load_model(%ModelRef{} = model_ref, opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:captured_load_timeout_ms, Keyword.get(opts, :load_timeout_ms)})
      end

      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule SlowLoadAdapter do
    @moduledoc false
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      # Block long enough for single-flight and cancel tests
      receive do
        :finish_load -> {:ok, %{model_ref: model_ref, generations: %{}}}
      after
        30_000 -> {:error, :load_timeout}
      end
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  setup do
    :ok = NodeStatus.reset()
    wait_until(fn -> worker_count() == 0 end)

    # Create a real test bundle at both the cache path and a source path.
    # The async ModelManager pipeline runs acquisition which checks cache hash.
    bundle = stage_test_bundle!()

    # Register the test process so adapters can send messages back.
    if Process.whereis(:load_timeout_test_pid), do: Process.unregister(:load_timeout_test_pid)
    Process.register(self(), :load_timeout_test_pid)

    on_exit(fn ->
      File.rm_rf(bundle.cache_path)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  test "node agent version is exposed" do
    assert Orchard.NodeAgent.version() == "0.1.0"
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(NodeSupervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = NodeSupervisor.start_link([])
  end

  test "node supervisor boots the model manager, worker supervisor, task supervisor, and gRPC server child" do
    assert is_pid(Process.whereis(NodeSupervisor))
    assert is_pid(Process.whereis(ModelManager))
    assert is_pid(Process.whereis(WorkerSupervisor))
    assert is_pid(Process.whereis(Orchard.Node.ModelLoadTaskSupervisor))

    child_ids =
      Supervisor.which_children(NodeSupervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert NodeSupervisor.grpc_server_id() in child_ids
    assert ModelManager in child_ids
    assert WorkerSupervisor in child_ids
    assert Orchard.Node.ModelLoadTaskSupervisor in child_ids
  end

  test "node agent application supervisor is running" do
    assert is_pid(Process.whereis(NodeAgentSupervisor))
  end

  test "node agent references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %CanonicalModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = OrchardInferenceEvent.progress("loading", "warming model")

    manifest =
      ModelManifest.new(%{
        model_id: "mlx-community/phi-3",
        version: "main",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{
          adapter: "mlx_lm",
          min_agent_capability: "mlx"
        }
      })

    assert request.endpoint == :responses
    assert SharedContract.request_model_ref(request).model_id == "mlx-community/phi-3"
    assert SharedContract.event_kind(event) == :progress
    assert %Orchard.Cluster.V1.ModelRef{} = SharedContract.manifest_proto_model_ref(manifest)
  end

  test "test environment config uses fake runtime and local worker paths" do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    assert runtime[:fake_runtime?]
    assert runtime[:listen_address] == [host: "127.0.0.1", port: 50_071]
    assert Path.type(runtime[:models_root]) == :absolute
    assert Path.type(runtime[:worker_socket_dir]) == :absolute
    assert Path.type(runtime[:worker_executable]) == :absolute
    assert String.ends_with?(runtime[:models_root], "/tmp/test/models")
    assert String.ends_with?(runtime[:worker_socket_dir], "/tmp/test/data/worker-sockets")

    assert String.ends_with?(
             runtime[:worker_executable],
             "/native/orchard_worker_mlx/bin/orchard-worker-mlx"
           )

    assert runtime[:worker_backend] == "stub"
    assert runtime[:worker_ready_timeout_ms] == 5_000
    assert runtime[:worker_load_timeout_ms] == 5_000
    assert runtime[:worker_shutdown_timeout_ms] == 1_000

    assert Node.listen_host() == "127.0.0.1"
    assert Node.listen_port() == 50_071
    assert Node.fake_runtime?()
    assert Node.runtime_adapter_impl() == Orchard.Node.FakeRuntimeAdapter
    assert Node.worker_backend() == "stub"
    assert Node.worker_ready_timeout_ms() == 5_000
    assert Node.worker_load_timeout_ms() == 5_000
    assert Node.worker_shutdown_timeout_ms() == 1_000
  end

  test "ensure_model_loaded passes remaining deadline budget as load_timeout_ms to adapter", %{
    bundle: bundle
  } do
    with_runtime_adapter(LoadTimeoutCapturingAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert_receive {:captured_load_timeout_ms, timeout_ms}, 1_000
      # The remaining deadline budget is approximately 5000ms minus acquisition time.
      # Acquisition is a cache-hit (fast), so timeout should be close to 5000.
      assert is_integer(timeout_ms)
      assert timeout_ms > 0
      assert timeout_ms <= 5_000
    end)
  end

  test "get_status responds over gRPC" do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.worker_state == :WORKER_STATE_IDLE
      assert response.loaded_models == []
      assert response.active_request_count == 0
    end)
  end

  test "ensure_model_loaded is idempotent and does not create duplicate workers", %{
    bundle: bundle
  } do
    request = ensure_model_loaded_request(bundle)

    with_channel(fn channel ->
      assert {:ok,
              %EnsureModelLoadedResponse{
                already_loaded: false,
                placement_state: :PLACEMENT_STATE_LOADED
              }} = NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %EnsureModelLoadedResponse{already_loaded: true}} =
               NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %StatusResponse{loaded_models: [%RPCModelRef{} = loaded_model]}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert loaded_model.model_id == @test_model_id
      assert loaded_model.version == @test_version
      assert worker_count() == 1
    end)
  end

  test "execute_inference streams accepted, deterministic deltas, and terminal completion", %{
    bundle: bundle
  } do
    request = execute_inference_request("req-r3-execute")

    with_channel(fn channel ->
      assert {:ok, _response} =
               NodeRuntimeStub.ensure_model_loaded(
                 channel,
                 ensure_model_loaded_request(bundle)
               )

      assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

      assert [
               {:ok,
                %RPCInferenceEvent{
                  event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event: {:output_text_delta, %OutputTextDelta{delta: "orchard "}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event: {:output_text_delta, %OutputTextDelta{delta: "ready"}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event:
                    {:completed,
                     %Completed{
                       finish_reason: :FINISH_REASON_STOP,
                       usage: %TokenUsage{input_tokens: 2, output_tokens: 2, total_tokens: 4}
                     }}
                }}
             ] = Enum.to_list(event_stream)

      assert is_integer(accepted_at)
      assert accepted_at > 0

      assert {:ok, %StatusResponse{active_request_count: 0}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      worker_state = :sys.get_state(worker_pid())
      assert worker_state.adapter_state.generations == %{}
    end)
  end

  test "real worker runtime adapter streams stub worker events and unload cleans up the socket",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      socket_path = real_worker_socket_path()

      refute File.exists?(socket_path)

      with_channel(fn channel ->
        assert {:ok,
                %EnsureModelLoadedResponse{
                  already_loaded: false,
                  placement_state: :PLACEMENT_STATE_LOADED
                }} =
                 NodeRuntimeStub.ensure_model_loaded(
                   channel,
                   ensure_model_loaded_request(bundle)
                 )

        wait_until(fn -> File.exists?(socket_path) end)

        request = execute_inference_request("req-r5-real-runtime")
        assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

        assert [
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:output_text_delta, %OutputTextDelta{delta: "mlx "}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:output_text_delta, %OutputTextDelta{delta: "ready"}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event:
                      {:completed,
                       %Completed{
                         finish_reason: :FINISH_REASON_STOP,
                         usage: %TokenUsage{input_tokens: 2, output_tokens: 2, total_tokens: 4}
                       }}
                  }}
               ] = Enum.to_list(event_stream)

        assert is_integer(accepted_at)
        assert accepted_at > 0

        assert {:ok, %{ok: true, message: "unload accepted"}} =
                 NodeRuntimeStub.unload_model(
                   channel,
                   %UnloadModelRequest{
                     model_id: @test_model_id,
                     version: @test_version,
                     force: false,
                     evict: false
                   }
                 )
      end)

      wait_until(fn -> worker_count() == 0 end)
      refute File.exists?(socket_path)
    end)
  end

  test "real worker runtime adapter worker death emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      socket_path = real_worker_socket_path()

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request =
        execute_inference_request("req-r5-worker-down")
        |> Map.put(:metadata_json, ~s({"worker_delay_ms":2000,"worker_chunks":["mlx ","worker"]}))

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      assert_receive {:node_runtime_event, "req-r5-worker-down",
                      %Orchard.InferenceEvent{event: %Orchard.InferenceEvent.OutputTextDelta{}}},
                     5_000

      os_pid = worker_os_pid()
      kill_process_tree(os_pid)

      assert_receive {:node_runtime_event, "req-r5-worker-down",
                      %Orchard.InferenceEvent{event: %{code: "worker_down"}}},
                     5_000

      wait_until(fn -> worker_count() == 0 end)
      refute File.exists?(socket_path)
      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "worker death during a running request emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-worker-down")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)
      Process.exit(worker_pid(), :kill)

      assert_receive {:node_runtime_event, "req-r3-worker-down",
                      %Orchard.InferenceEvent{event: %{code: "worker_down"}}},
                     1_000

      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "force unload during a running request emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-force-unload")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)

      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: true,
                 evict: false
               })

      assert_receive {:node_runtime_event, "req-r3-force-unload",
                      %Orchard.InferenceEvent{event: %{code: "worker_unloaded"}}},
                     1_000

      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "subscriber disconnect before start_request does not leave stale prepared runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      subscriber =
        spawn(fn ->
          receive do
          end
        end)

      request = execute_inference_request("req-r3-prepared-disconnect")

      assert :ok = NodeStatus.prepare_request(request, subscriber)
      Process.exit(subscriber, :kill)

      wait_until(fn -> NodeStatus.current().active_request_count == 0 end)

      assert %StatusResponse{active_request_count: 0} = NodeStatus.current()

      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: false,
                 evict: false
               })
    end)
  end

  test "cancelling a prepared request prevents later start_request from launching it", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-prepared-cancel")

      assert :ok = NodeStatus.prepare_request(request, self())

      assert %{ok: true, message: "cancel accepted"} =
               NodeStatus.cancel_request(request.request_id, request.controller_session_id)

      assert {:error, :request_not_prepared} = NodeStatus.start_request(request)
      assert %StatusResponse{active_request_count: 0} = NodeStatus.current()
      refute_receive {:node_runtime_event, "req-r3-prepared-cancel", _event}, 100
    end)
  end

  test "cancel_inference is accepted over gRPC" do
    with_channel(fn channel ->
      request = %CancelInferenceRequest{
        request_id: "req-r2-cancel",
        controller_session_id: "controller-session-2"
      }

      assert {:ok, %{ok: true, message: "cancel accepted"}} =
               NodeRuntimeStub.cancel_inference(channel, request)
    end)
  end

  test "prepare_request rejects second request for same model with model_busy", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request1 = execute_inference_request("req-busy-first")
      request2 = execute_inference_request("req-busy-second")

      assert :ok = NodeStatus.prepare_request(request1, self())

      # Second request for same model should be rejected as model_busy.
      assert {:error, :model_busy} = NodeStatus.prepare_request(request2, self())

      # Clean up: cancel the first request so the model is released.
      assert %{ok: true} = NodeStatus.cancel_request(request1.request_id)
    end)
  end

  test "gRPC execute_inference streams model_busy failure without Accepted when model is busy",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      # Start a blocking first request via direct API (not gRPC) to hold the model.
      request1 = execute_inference_request("req-grpc-busy-first")
      assert :ok = NodeStatus.prepare_request(request1, self())
      assert :ok = NodeStatus.start_request(request1)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)

      # Second request via gRPC should get a failed event with model_busy, no Accepted.
      with_channel(fn channel ->
        request2 = execute_inference_request("req-grpc-busy-second")
        assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request2)
        events = Enum.to_list(event_stream)

        # Should have exactly one event: a failed with model_busy
        assert [{:ok, %RPCInferenceEvent{event: {:failed, failed}}}] = events
        assert failed.code == "model_busy"

        # No accepted event
        accepted_events =
          Enum.filter(events, fn
            {:ok, %RPCInferenceEvent{event: {:accepted, _}}} -> true
            _ -> false
          end)

        assert accepted_events == []
      end)

      # Release the blocking request.
      generation_ref = get_blocking_generation_ref()
      send_release(generation_ref)

      assert_receive {:node_runtime_event, "req-grpc-busy-first",
                      %OrchardInferenceEvent{event: %OrchardInferenceEvent.OutputTextDelta{}}},
                     1_000

      assert_receive {:node_runtime_event, "req-grpc-busy-first",
                      %OrchardInferenceEvent{event: %OrchardInferenceEvent.Completed{}}},
                     1_000
    end)
  end

  # -- Acquisition-specific tests ---------------------------------------------

  test "ensure_model_loaded with missing source and no cache returns FAILED", %{bundle: bundle} do
    # Remove the pre-staged cache so acquisition must fetch from source
    File.rm_rf!(bundle.cache_path)

    request = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: @test_model_id,
      version: @test_version,
      artifact_sha256: bundle.hash,
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: ""
    }

    assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_FAILED} =
             NodeStatus.ensure_model_loaded(request)
  end

  test "ensure_model_loaded acquires from file:// source when cache is missing", %{
    bundle: bundle
  } do
    # Remove the pre-staged cache so acquisition must fetch from source
    File.rm_rf!(bundle.cache_path)

    assert %EnsureModelLoadedResponse{
             already_loaded: false,
             placement_state: :PLACEMENT_STATE_LOADED
           } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

    # Cache should now exist
    assert File.dir?(bundle.cache_path)
    expected_hash = bundle.hash
    assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(bundle.cache_path)
  end

  test "ensure_model_loaded hash mismatch returns FAILED", %{bundle: bundle} do
    # Remove cache and request with wrong hash
    File.rm_rf!(bundle.cache_path)

    request = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: @test_model_id,
      version: @test_version,
      artifact_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: bundle.source_uri
    }

    assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_FAILED} =
             NodeStatus.ensure_model_loaded(request)

    # Staging directory should be cleaned up
    staging_dir = Path.join([Node.models_root(), ".staging"])

    if File.exists?(staging_dir) do
      assert File.ls!(staging_dir) == []
    end
  end

  test "concurrent ensure_model_loaded calls single-flight to one acquisition task", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      request = ensure_model_loaded_request(bundle)

      # Spawn two concurrent ensure calls
      task1 =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(request)
        end)

      task2 =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(request)
        end)

      # Both should succeed
      result1 = Task.await(task1, 10_000)
      result2 = Task.await(task2, 10_000)

      assert result1.placement_state == :PLACEMENT_STATE_LOADED
      assert result2.placement_state == :PLACEMENT_STATE_LOADED

      # Only one worker should exist
      assert worker_count() == 1
    end)
  end

  test "reset cancels inflight ensure_model_loaded and replies FAILED", %{bundle: bundle} do
    with_runtime_adapter(SlowLoadAdapter, fn ->
      # Start an ensure that will block in load_model
      ensure_task =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
        end)

      # Wait until we see the inflight load in progress
      wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)

      # Reset should cancel the inflight load
      :ok = NodeStatus.reset()

      # The blocked caller should receive FAILED
      result = Task.await(ensure_task, 5_000)
      assert result.placement_state == :PLACEMENT_STATE_FAILED

      # State should be clean
      assert %StatusResponse{worker_state: :WORKER_STATE_IDLE, loaded_models: []} =
               NodeStatus.current()
    end)
  end

  test "unload cancels inflight ensure_model_loaded for that model", %{bundle: bundle} do
    with_runtime_adapter(SlowLoadAdapter, fn ->
      # Start an ensure that will block in load_model
      ensure_task =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
        end)

      # Wait until we see the inflight load in progress
      wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)

      # Unload should cancel the inflight load
      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: false,
                 evict: false
               })

      # The blocked caller should receive FAILED
      result = Task.await(ensure_task, 5_000)
      assert result.placement_state == :PLACEMENT_STATE_FAILED
    end)
  end

  # -- Opt-in MLX real generation smoke test ----------------------------------

  # Set ORCHARD_MLX_SMOKE_MODEL_PATH to a real Orchard bundle directory.
  @mlx_smoke_model_path System.get_env("ORCHARD_MLX_SMOKE_MODEL_PATH")

  if @mlx_smoke_model_path do
    @tag :mlx_smoke
    test "opt-in MLX real generation through full node-agent path" do
      mlx_bundle_path = unquote(@mlx_smoke_model_path)

      # Read manifest from the real bundle
      manifest_json = File.read!(Path.join(mlx_bundle_path, "manifest.json"))
      manifest_data = Jason.decode!(manifest_json)
      model_id = manifest_data["model_id"]
      version = manifest_data["version"]

      # Compute hash for the real bundle
      {:ok, hash} = ArtifactBundle.tree_sha256(mlx_bundle_path)

      source_uri = "file://#{mlx_bundle_path}"

      with_runtime_config(
        [
          runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
          fake_runtime?: false,
          worker_backend: "mlx",
          worker_load_timeout_ms: 120_000,
          worker_ready_timeout_ms: 30_000
        ],
        fn ->
          with_channel(fn channel ->
            # Ensure model loaded via file:// acquisition
            ensure_req = %EnsureModelLoadedRequest{
              node_id: "node-local",
              model_id: model_id,
              version: version,
              artifact_sha256: hash,
              preload: true,
              deadline_unix_ms: System.system_time(:millisecond) + 120_000,
              artifact_source_uri: source_uri
            }

            assert {:ok,
                    %EnsureModelLoadedResponse{
                      placement_state: :PLACEMENT_STATE_LOADED
                    }} = NodeRuntimeStub.ensure_model_loaded(channel, ensure_req)

            # Execute real generation
            gen_req = %ExecuteInferenceRequest{
              request_id: "req-mlx-smoke-gen",
              controller_session_id: "mlx-smoke-session",
              model_id: model_id,
              version: version,
              rendered_prompt_utf8: "The capital of France is",
              input_tokens: 6,
              params: %GenerationParams{max_output_tokens: 8, temperature: 0.0},
              deadline_unix_ms: System.system_time(:millisecond) + 60_000,
              metadata_json: ~s({"source":"mlx_smoke"})
            }

            assert {:ok, event_stream} =
                     NodeRuntimeStub.execute_inference(channel, gen_req)

            events = Enum.to_list(event_stream)
            assert length(events) >= 3, "Expected accepted + delta(s) + completed"

            # First event: Accepted from node (not worker)
            assert {:ok, %RPCInferenceEvent{event: {:accepted, %Accepted{}}}} =
                     hd(events)

            # At least one output_text_delta
            deltas =
              Enum.filter(events, fn
                {:ok, %RPCInferenceEvent{event: {:output_text_delta, _}}} -> true
                _ -> false
              end)

            assert length(deltas) >= 1, "Expected at least one output_text_delta"

            # Terminal: completed with valid usage
            {:ok, %RPCInferenceEvent{event: {:completed, %Completed{} = completed}}} =
              List.last(events)

            assert completed.finish_reason in [
                     :FINISH_REASON_STOP,
                     :FINISH_REASON_LENGTH
                   ]

            usage = completed.usage
            assert usage.input_tokens == 6
            assert usage.output_tokens > 0
            assert usage.total_tokens == usage.input_tokens + usage.output_tokens

            # Unload
            assert {:ok, %{ok: true}} =
                     NodeRuntimeStub.unload_model(channel, %UnloadModelRequest{
                       model_id: model_id,
                       version: version,
                       force: false,
                       evict: false
                     })
          end)
        end
      )
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp get_blocking_generation_ref do
    pid = worker_pid()
    state = :sys.get_state(pid)

    state.requests
    |> Map.values()
    |> hd()
    |> Map.fetch!(:generation_ref)
  end

  defp send_release(generation_ref) do
    pid = worker_pid()
    state = :sys.get_state(pid)

    gen_state =
      Enum.find_value(state.adapter_state.generations, fn {ref, gen} ->
        if ref == generation_ref, do: gen
      end)

    send(gen_state.pid, {:release, generation_ref})
  end

  defp with_channel(fun) when is_function(fun, 1) do
    target = "#{Node.listen_host()}:#{Node.listen_port()}"

    {:ok, channel} = GRPC.Stub.connect(target)

    try do
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
    end
  end

  defp stage_test_bundle! do
    models_root = Node.models_root()
    cache_path = Path.join([models_root, @test_model_id, @test_version])
    source_path = Path.join([models_root, ".test-source", "bundle"])

    # Clean previous
    File.rm_rf(cache_path)
    File.rm_rf(source_path)

    # Create source bundle with dummy files
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    # Compute hash
    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    # Pre-stage at cache location (cache hit path)
    File.mkdir_p!(cache_path)
    :ok = ArtifactBundle.copy_directory(source_path, cache_path)

    source_uri = "file://#{source_path}"

    %{cache_path: cache_path, source_path: source_path, source_uri: source_uri, hash: hash}
  end

  defp ensure_model_loaded_request(bundle) do
    %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: @test_model_id,
      version: @test_version,
      artifact_sha256: bundle.hash,
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: bundle.source_uri
    }
  end

  defp execute_inference_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-1",
      model_id: @test_model_id,
      version: @test_version,
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2,
      params: %GenerationParams{max_output_tokens: 16},
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      metadata_json: ~s({"source":"test"})
    }
  end

  defp worker_count do
    DynamicSupervisor.which_children(WorkerSupervisor)
    |> Enum.count(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
  end

  defp worker_pid do
    DynamicSupervisor.which_children(WorkerSupervisor)
    |> Enum.find_value(fn {_id, pid, _type, _modules} -> if is_pid(pid), do: pid end)
  end

  defp with_runtime_adapter(adapter, fun) when is_function(fun, 0) do
    with_runtime_config([runtime_adapter_impl: adapter], fun)
  end

  defp with_real_worker_runtime(fun) when is_function(fun, 0) do
    with_runtime_config(
      [runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter, fake_runtime?: false],
      fun
    )
  end

  defp with_runtime_config(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    updated_runtime = Keyword.merge(previous_runtime, overrides)

    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)
    :ok = NodeStatus.reset()
    wait_until(fn -> worker_count() == 0 end)

    try do
      fun.()
    after
      :ok = NodeStatus.reset()
      wait_until(fn -> worker_count() == 0 end)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end
  end

  defp real_worker_socket_path do
    Node.worker_socket_path(@test_model_id, @test_version)
  end

  defp worker_os_pid do
    %{adapter_state: %{os_pid: os_pid}} = :sys.get_state(worker_pid())
    os_pid
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not reached before timeout")

  defp kill_process_tree(os_pid) when is_integer(os_pid) do
    {children_output, _} =
      System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

    children_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.each(fn child_pid_str ->
      case Integer.parse(child_pid_str) do
        {child_pid, _} -> kill_process_tree(child_pid)
        :error -> :ok
      end
    end)

    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end
end
