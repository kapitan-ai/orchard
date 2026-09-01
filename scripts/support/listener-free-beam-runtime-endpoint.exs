if System.argv() == ["node"] do
  defmodule Orchard.ListenerFreeBeamRuntimeEndpointValidation.Adapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.{ExecuteInferenceRequest, ModelRef, ScorePrefixCacheResponse}
    alias Orchard.InferenceEvent

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: "", max_concurrency: 1}}
    end

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
      mode = generation_mode(request.metadata_json)

      {:ok, pid} =
        Task.start(fn ->
          if mode == :cancel do
            Process.sleep(:infinity)
          else
            usage = %InferenceEvent.Usage{
              input_tokens: request.input_tokens,
              output_tokens: 2,
              total_tokens: request.input_tokens + 2
            }

            send(
              owner,
              {:runtime_adapter_event, generation_ref,
               InferenceEvent.output_text_delta("orchard ")}
            )

            send(
              owner,
              {:runtime_adapter_event, generation_ref, InferenceEvent.output_text_delta("ready")}
            )

            send(
              owner,
              {:runtime_adapter_event, generation_ref,
               InferenceEvent.completed(:finish_reason_stop, usage)}
            )

            send(owner, {:runtime_adapter_done, generation_ref})
          end
        end)

      generations = Map.put(adapter_state.generations, generation_ref, %{owner: owner, pid: pid})
      {:ok, generation_ref, %{adapter_state | generations: generations}}
    end

    @impl true
    def cancel_generation(adapter_state, generation_ref, _opts) do
      case Map.pop(adapter_state.generations, generation_ref) do
        {nil, _generations} ->
          {:ok, adapter_state}

        {%{owner: owner, pid: pid}, generations} ->
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
      %{adapter_state | generations: Map.delete(adapter_state.generations, generation_ref)}
    end

    def score_prefix_cache(_adapter_state, _request, _opts) do
      {:ok,
       %ScorePrefixCacheResponse{
         status_code: "ok",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint",
         session_started_unix_ms: 1
       }}
    end

    defp generation_mode(metadata_json) do
      case Jason.decode(metadata_json) do
        {:ok, %{"validation_mode" => "cancel"}} -> :cancel
        _other -> :complete
      end
    end
  end
end

defmodule Orchard.ListenerFreeBeamRuntimeEndpointValidation do
  @grpc_server_id Orchard.Node.GRPCServer

  if System.argv() == ["node"] do
    @adapter Orchard.ListenerFreeBeamRuntimeEndpointValidation.Adapter

    def start_node! do
      root = System.fetch_env!("ORCHARD_BEAM_SMOKE_ROOT")
      ready_file = System.fetch_env!("ORCHARD_LISTENER_FREE_RUNTIME_ENDPOINT_READY_FILE")

      runtime =
        :orchard_node_agent
        |> Application.fetch_env!(:runtime)
        |> Keyword.merge(
          runtime_grpc_listener_enabled: false,
          runtime_adapter_impl: @adapter,
          fake_runtime?: true,
          models_root: Path.join([root, "support", "models"]),
          worker_socket_dir: Path.join([root, "support", "worker-sockets"]),
          worker_log_dir: Path.join([root, "support", "worker-logs"])
        )

      Application.put_env(:orchard_node_agent, :runtime, runtime)

      false = Orchard.Node.runtime_grpc_listener_enabled?()
      {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
      assert_grpc_server_absent!()
      assert_port_closed!(Orchard.Node.listen_port())
      File.write!(ready_file, "listener disabled before supervisor initialization\n")
    end

    defp assert_grpc_server_absent! do
      false =
        Orchard.Node.Supervisor
        |> Supervisor.which_children()
        |> Enum.any?(fn {id, _pid, _type, _modules} -> id == @grpc_server_id end)
    end
  end

  defp assert_port_closed!(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:error, :econnrefused} ->
        :ok

      {:ok, socket} ->
        :gen_tcp.close(socket)
        raise "Node Runtime TCP port #{port} is listening"

      {:error, reason} ->
        raise "Node Runtime TCP port #{port} check failed: #{inspect(reason)}"
    end
  end

  if System.argv() != ["node"] do
    alias Orchard.ArtifactBundle
    alias Orchard.Inference
    alias Orchard.InferenceEvent
    alias Orchard.Repo

    alias Orchard.RuntimeEndpoint.{
      BeamClient,
      ModelRef,
      Observation,
      Operation,
      Target
    }

    @server Orchard.Node.RuntimeEndpoint
    @model_id "validation/listener-free"
    @model_version "v1"
    @timeout 5_000

    def run_controller!(root, node_id, runtime_port) do
      BeamClient = Inference.runtime_endpoint_client()
      target = active_target!(node_id)
      %Target{transport: :beam} = target
      {:ok, %BeamClient{server_module: @server} = connection} = BeamClient.connect(target)

      assert_remote_grpc_server_absent!(connection.node)
      assert_port_closed!(runtime_port)

      {:ok, %Observation{availability: :available}} =
        BeamClient.status(connection, timeout: @timeout)

      assert_port_closed!(runtime_port)

      bundle = stage_bundle!(root)
      model_ref = ModelRef.new!(@model_id, @model_version)

      load_request = %Operation.EnsureModelLoadedRequest{
        model_ref: model_ref,
        node_id: node_id,
        artifact_sha256: bundle.hash,
        preload: true,
        deadline_unix_ms: deadline(),
        artifact_source_uri: bundle.source_uri
      }

      {:ok, %Operation.EnsureModelLoadedResult{placement_state: :loaded}} =
        BeamClient.ensure_model_loaded(connection, load_request, timeout: @timeout)

      assert_port_closed!(runtime_port)
      completion_kinds = run_completion!(connection, model_ref)
      assert_port_closed!(runtime_port)
      cancellation_kinds = run_active_cancellation!(connection, model_ref)
      assert_port_closed!(runtime_port)

      score_request = %Operation.PrefixCacheScoreRequest{
        request_id: "listener-free-score",
        controller_session_id: "listener-free-session",
        model_ref: model_ref,
        cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
        deadline_unix_ms: deadline()
      }

      {:ok,
       %Operation.PrefixCacheScoreResult{
         status_code: "ok",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint"
       }} = BeamClient.score_prefix_cache(connection, score_request, timeout: @timeout)

      assert_port_closed!(runtime_port)

      unload_request = %Operation.UnloadModelRequest{
        model_ref: model_ref,
        force: false,
        evict: false,
        deadline_unix_ms: deadline()
      }

      {:ok, %Operation.Ack{ok: true}} =
        BeamClient.unload_model(connection, unload_request, timeout: @timeout)

      {:ok, %Observation{placements: []}} = BeamClient.status(connection, timeout: @timeout)
      assert_persistence!(node_id)
      assert_port_closed!(runtime_port)
      :ok = BeamClient.disconnect(connection)

      evidence = [
        "listener process absent: true",
        "runtime tcp listener absent at every checkpoint: true",
        "beam server module: #{inspect(@server)}",
        "completion events: #{Enum.join(completion_kinds, ",")}",
        "active cancellation events: #{Enum.join(cancellation_kinds, ",")}",
        "prefix cache score: resident_fingerprint",
        "model unload observed: true",
        "node activation and heartbeat persistence: true",
        "automatic node runtime grpc fallback: false"
      ]

      File.write!(
        Path.join(root, "controller.listener-free.complete"),
        Enum.join(evidence, "\n") <> "\n"
      )

      :ok
    end

    defp run_completion!(connection, model_ref) do
      request =
        execute_request("listener-free-complete", model_ref, ~s({"validation_mode":"complete"}))

      {:ok, stream_ref} = BeamClient.execute_inference(connection, request, owner: self())
      events = collect_stream!(stream_ref, request.request_id, [])
      kinds = Enum.map(events, &InferenceEvent.kind/1)
      true = :accepted in kinds
      true = :output_text_delta in kinds
      :completed = List.last(kinds)
      wait_until!(fn -> active_request_count(connection) == 0 end)
      kinds
    end

    defp run_active_cancellation!(connection, model_ref) do
      request =
        execute_request("listener-free-cancel", model_ref, ~s({"validation_mode":"cancel"}))

      {:ok, stream_ref} = BeamClient.execute_inference(connection, request, owner: self())

      {:runtime_endpoint_event, ^stream_ref, request_id, %InferenceEvent{} = accepted} =
        receive_event!(stream_ref, request.request_id)

      :accepted = InferenceEvent.kind(accepted)
      wait_until!(fn -> active_request_count(connection) == 1 end)

      cancel_request = %Operation.CancelRequest{
        request_id: request_id,
        controller_session_id: request.controller_session_id
      }

      :ok = BeamClient.cancel_inference(connection, cancel_request, timeout: @timeout)
      events = [accepted | collect_stream!(stream_ref, request.request_id, [])]
      wait_until!(fn -> active_request_count(connection) == 0 end)
      kinds = Enum.map(events, &InferenceEvent.kind/1)

      true =
        Enum.any?(events, fn
          %InferenceEvent{event: %InferenceEvent.Failed{code: "cancelled"}} -> true
          _event -> false
        end)

      kinds
    end

    defp execute_request(request_id, model_ref, metadata_json) do
      %Operation.ExecuteRequest{
        request_id: request_id,
        controller_session_id: "listener-free-session",
        model_ref: model_ref,
        rendered_prompt_utf8: "hello orchard",
        input_tokens: 2,
        params: %{max_output_tokens: 16},
        deadline_unix_ms: deadline(),
        metadata_json: metadata_json,
        cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64)
      }
    end

    defp collect_stream!(stream_ref, request_id, events) do
      receive do
        {:runtime_endpoint_event, ^stream_ref, ^request_id, %InferenceEvent{} = event} ->
          collect_stream!(stream_ref, request_id, [event | events])

        {:runtime_endpoint_done, ^stream_ref, :ok} ->
          Enum.reverse(events)

        {:runtime_endpoint_done, ^stream_ref, reason} ->
          raise "Runtime Endpoint stream failed: #{inspect(reason)}"
      after
        @timeout -> raise "Runtime Endpoint stream timed out for #{request_id}"
      end
    end

    defp receive_event!(stream_ref, request_id) do
      receive do
        {:runtime_endpoint_event, ^stream_ref, ^request_id, %InferenceEvent{}} = message ->
          message
      after
        @timeout -> raise "Runtime Endpoint did not accept #{request_id}"
      end
    end

    defp active_request_count(connection) do
      {:ok, observation} = BeamClient.status(connection, timeout: @timeout)
      observation.aggregate_active_request_count
    end

    defp active_target!(node_id) do
      Inference.activation_probe_runtime_endpoint_targets()
      |> Enum.find(&(&1.node_id == node_id))
      |> case do
        nil -> raise "active BEAM Runtime Endpoint target not found for #{node_id}"
        target -> target
      end
    end

    defp stage_bundle!(root) do
      source_path = Path.join(root, "model-source")
      cache_path = Path.join([root, "support", "models", @model_id, @model_version])
      File.mkdir_p!(Path.join(source_path, "weights"))
      File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"validation"}))
      File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
      File.write!(Path.join([source_path, "weights", "model.safetensors"]), "validation")
      {:ok, hash} = ArtifactBundle.tree_sha256(source_path)
      File.rm_rf!(cache_path)
      File.mkdir_p!(cache_path)
      :ok = ArtifactBundle.copy_directory(source_path, cache_path)
      %{hash: hash, source_uri: "file://#{source_path}"}
    end

    defp assert_remote_grpc_server_absent!(remote_node) do
      children =
        :rpc.call(remote_node, Supervisor, :which_children, [Orchard.Node.Supervisor], @timeout)

      false = Enum.any?(children, fn {id, _pid, _type, _modules} -> id == @grpc_server_id end)
    end

    defp assert_persistence!(node_id) do
      %{rows: [["active", true, count]]} =
        Repo.query!(
          "SELECT state::text, last_heartbeat_at IS NOT NULL, " <>
            "(SELECT count(*) FROM node_heartbeats WHERE node_id::text = $1) " <>
            "FROM nodes WHERE id::text = $1",
          [node_id]
        )

      true = count > 0
    end

    defp wait_until!(fun, attempts \\ 50)
    defp wait_until!(_fun, 0), do: raise("condition did not become true")

    defp wait_until!(fun, attempts) do
      if fun.() do
        :ok
      else
        Process.sleep(100)
        wait_until!(fun, attempts - 1)
      end
    end

    defp deadline, do: System.system_time(:millisecond) + 10_000
  end
end

if System.argv() == ["node"] do
  Orchard.ListenerFreeBeamRuntimeEndpointValidation.start_node!()
end
