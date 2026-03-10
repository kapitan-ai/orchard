defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: false

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

  setup do
    :ok = NodeStatus.reset()
    wait_until(fn -> worker_count() == 0 end)
    :ok
  end

  test "node agent version is exposed" do
    assert Orchard.NodeAgent.version() == "0.1.0"
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(NodeSupervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = NodeSupervisor.start_link([])
  end

  test "node supervisor boots the model manager, worker supervisor, and gRPC server child" do
    assert is_pid(Process.whereis(NodeSupervisor))
    assert is_pid(Process.whereis(ModelManager))
    assert is_pid(Process.whereis(WorkerSupervisor))

    child_ids =
      Supervisor.which_children(NodeSupervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert NodeSupervisor.grpc_server_id() in child_ids
    assert ModelManager in child_ids
    assert WorkerSupervisor in child_ids
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
    assert runtime[:worker_shutdown_timeout_ms] == 1_000

    assert Node.listen_host() == "127.0.0.1"
    assert Node.listen_port() == 50_071
    assert Node.fake_runtime?()
    assert Node.runtime_adapter_impl() == Orchard.Node.FakeRuntimeAdapter
    assert Node.worker_backend() == "stub"
    assert Node.worker_ready_timeout_ms() == 5_000
    assert Node.worker_shutdown_timeout_ms() == 1_000
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

  test "ensure_model_loaded is idempotent and does not create duplicate workers" do
    request = ensure_model_loaded_request()

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

      assert loaded_model.model_id == "mlx-community/phi-3"
      assert loaded_model.version == "main"
      assert worker_count() == 1
    end)
  end

  test "execute_inference streams accepted, deterministic deltas, and terminal completion" do
    request = execute_inference_request("req-r3-execute")

    with_channel(fn channel ->
      assert {:ok, _response} =
               NodeRuntimeStub.ensure_model_loaded(channel, ensure_model_loaded_request())

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

  test "real worker runtime adapter streams stub worker events and unload cleans up the socket" do
    with_real_worker_runtime(fn ->
      ensure_test_model_dir!()
      socket_path = real_worker_socket_path()
      request = execute_inference_request("req-r5-real-runtime")

      refute File.exists?(socket_path)

      with_channel(fn channel ->
        assert {:ok,
                %EnsureModelLoadedResponse{
                  already_loaded: false,
                  placement_state: :PLACEMENT_STATE_LOADED
                }} = NodeRuntimeStub.ensure_model_loaded(channel, ensure_model_loaded_request())

        wait_until(fn -> File.exists?(socket_path) end)

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
                     model_id: "mlx-community/phi-3",
                     version: "main",
                     force: false,
                     evict: false
                   }
                 )
      end)

      wait_until(fn -> worker_count() == 0 end)
      refute File.exists?(socket_path)
    end)
  end

  test "real worker runtime adapter worker death emits a terminal failure and clears runtime state" do
    with_real_worker_runtime(fn ->
      ensure_test_model_dir!()
      socket_path = real_worker_socket_path()

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request())

      request =
        execute_inference_request("req-r5-worker-down")
        |> Map.put(:metadata_json, ~s({"worker_delay_ms":2000,"worker_chunks":["mlx ","worker"]}))

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      # Wait for the first streamed delta to confirm the worker is mid-generation,
      # then kill it. With the generator-based stub backend, each chunk is yielded
      # individually with a delay between them, so the worker is still alive and
      # sleeping before the second chunk when we send SIGKILL.
      assert_receive {:node_runtime_event, "req-r5-worker-down",
                      %Orchard.InferenceEvent{event: %Orchard.InferenceEvent.OutputTextDelta{}}},
                     5_000

      # Kill the entire process tree: `uv run` spawns the Python worker as a
      # child process. Killing only the `uv run` parent leaves the child alive
      # (holding the port's stdout pipe open), so the BEAM port driver never
      # sends `{port, {:exit_status, _}}`. Kill children first, then parent.
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

  test "worker death during a running request emits a terminal failure and clears runtime state" do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request())

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

  test "force unload during a running request emits a terminal failure and clears runtime state" do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request())

      request = execute_inference_request("req-r3-force-unload")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)

      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: "mlx-community/phi-3",
                 version: "main",
                 force: true,
                 evict: false
               })

      assert_receive {:node_runtime_event, "req-r3-force-unload",
                      %Orchard.InferenceEvent{event: %{code: "worker_unloaded"}}},
                     1_000

      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "subscriber disconnect before start_request does not leave stale prepared runtime state" do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request())

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
                 model_id: "mlx-community/phi-3",
                 version: "main",
                 force: false,
                 evict: false
               })
    end)
  end

  test "cancelling a prepared request prevents later start_request from launching it" do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request())

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

  defp with_channel(fun) when is_function(fun, 1) do
    target = "#{Node.listen_host()}:#{Node.listen_port()}"

    {:ok, channel} = GRPC.Stub.connect(target)

    try do
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
    end
  end

  defp ensure_model_loaded_request do
    %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: "mlx-community/phi-3",
      version: "main",
      artifact_sha256: "sha256:test",
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp execute_inference_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-1",
      model_id: "mlx-community/phi-3",
      version: "main",
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

  defp ensure_test_model_dir! do
    model_path = Path.join([Node.models_root(), "mlx-community", "phi-3", "main"])
    File.mkdir_p!(model_path)
    model_path
  end

  defp real_worker_socket_path do
    Node.worker_socket_path("mlx-community/phi-3", "main")
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
    # `uv run` spawns the Python worker as a child process. Killing only
    # the parent leaves the child alive (holding the port's stdout pipe open),
    # so the BEAM port driver never delivers `{port, {:exit_status, _}}`.
    # Kill children first (recursively), then the parent.
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
