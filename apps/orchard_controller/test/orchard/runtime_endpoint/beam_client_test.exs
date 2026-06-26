defmodule Orchard.RuntimeEndpoint.BeamClientTest do
  use ExUnit.Case, async: false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.{BeamClient, ModelRef, Observation, Operation, Target}

  @node_id "550e8400-e29b-41d4-a716-446655440000"

  setup do
    previous_config = Application.get_env(:orchard_controller, :runtime_endpoint)

    on_exit(fn ->
      restore_runtime_endpoint_config(previous_config)
    end)

    :ok
  end

  defmodule Server do
    alias Orchard.RuntimeEndpoint.{Observation, Operation}

    def status(target, _opts) do
      {:ok, Observation.new(endpoint_id: target.id, target: target, availability: :available)}
    end

    def ensure_model_loaded(%Operation.EnsureModelLoadedRequest{}, _opts) do
      {:ok, %Operation.EnsureModelLoadedResult{already_loaded: true, placement_state: :loaded}}
    end

    def unload_model(%Operation.UnloadModelRequest{}, _opts) do
      {:ok, %Operation.Ack{ok: true, message: "unloaded"}}
    end

    def execute_inference(%Operation.ExecuteRequest{} = request, owner, stream_ref, _opts) do
      send(
        owner,
        {:runtime_endpoint_event, stream_ref, request.request_id,
         Orchard.InferenceEvent.accepted(1)}
      )

      send(owner, {:runtime_endpoint_done, stream_ref, :ok})
      {:ok, self()}
    end

    def cancel_inference(%Operation.CancelRequest{}, _opts), do: :ok

    def score_prefix_cache(%Operation.PrefixCacheScoreRequest{}, _opts) do
      {:ok, %Operation.PrefixCacheScoreResult{status_code: "ok", score_tier: "resident"}}
    end
  end

  defmodule RaisingServer do
    def execute_inference(_request, _owner, _stream_ref, _opts), do: raise("boom")
    def score_prefix_cache(_request, _opts), do: raise("boom")
  end

  test "connect rejects unsupported target transports" do
    target = Target.grpc_compat(host: "127.0.0.1", port: 50_071)

    assert {:error, {:unsupported_transport, :grpc_compat}} = BeamClient.connect(target)
  end

  test "SPEC.md §7.5 connect normalizes prebuilt BEAM targets at the client boundary" do
    target = %Target{
      id: "source-dev-node-agent",
      transport: :beam,
      address: Atom.to_string(node()),
      node_id: @node_id,
      metadata: %{server_module: Server}
    }

    assert {:ok, %BeamClient{target: %Target{address: address}}} = BeamClient.connect(target)
    assert address == node()
  end

  test "SPEC.md §7.5 enabled config applies guardrails before local BEAM RPC" do
    put_beam_config(
      enabled: true,
      node_name: "orchard_controller@10.0.0.5",
      cookie_file: "/Library/Application Support/Orchard/secrets/beam.cookie",
      admitted_services: ["orchard_node_agent"],
      allowed_cidrs: ["10.0.0.0/24"],
      listen_host: "10.0.0.5"
    )

    target = Target.beam(@node_id, address: node(), metadata: %{server_module: Server})

    assert {:error, reason} = BeamClient.connect(target)
    assert reason in [:beam_distribution_unavailable, :beam_node_identity_mismatch]
  end

  test "serves Runtime Endpoint operations over the BEAM client contract" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: Server})

    assert {:ok, connection} = BeamClient.connect(target)
    assert {:ok, %Observation{availability: :available}} = BeamClient.status(connection, [])

    load_request = %Operation.EnsureModelLoadedRequest{model_ref: model_ref}

    assert {:ok, %{already_loaded: true, placement_state: :loaded}} =
             BeamClient.ensure_model_loaded(connection, load_request, [])

    unload_request = %Operation.UnloadModelRequest{model_ref: model_ref}

    assert {:ok, %Operation.Ack{ok: true}} =
             BeamClient.unload_model(connection, unload_request, [])

    execute_request = %Operation.ExecuteRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      rendered_prompt_utf8: "hello",
      input_tokens: 1
    }

    assert {:ok, stream_ref} =
             BeamClient.execute_inference(connection, execute_request, owner: self())

    assert_receive {:runtime_endpoint_event, ^stream_ref, "req_1", %InferenceEvent{}}
    assert_receive {:runtime_endpoint_done, ^stream_ref, :ok}

    cancel_request = %Operation.CancelRequest{
      request_id: "req_1",
      controller_session_id: "session_1"
    }

    assert :ok = BeamClient.cancel_inference(connection, cancel_request, [])

    score_request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "ok", score_tier: "resident"}} =
             BeamClient.score_prefix_cache(connection, score_request, [])

    assert :ok = BeamClient.disconnect(connection)
  end

  test "prefix-cache scoring fails open when a BEAM target is unavailable" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: :definitely_missing@localhost)

    request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "unavailable"}} =
             BeamClient.score_prefix_cache(target, request, [])
  end

  test "local BEAM server startup failures send dispatcher-safe completion" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: RaisingServer})
    assert {:ok, connection} = BeamClient.connect(target)

    request = %Operation.ExecuteRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      rendered_prompt_utf8: "hello",
      input_tokens: 1
    }

    assert {:ok, stream_ref} = BeamClient.execute_inference(connection, request, owner: self())

    assert_receive {:runtime_endpoint_done, ^stream_ref,
                    {:error, {:beam_rpc_error, :remote_error}}}
  end

  test "prefix-cache scoring fails open when a local BEAM server raises" do
    model_ref = ModelRef.new!("mlx-community/phi-3", "main")
    target = Target.beam(@node_id, address: node(), metadata: %{server_module: RaisingServer})
    assert {:ok, connection} = BeamClient.connect(target)

    request = %Operation.PrefixCacheScoreRequest{
      request_id: "req_1",
      controller_session_id: "session_1",
      model_ref: model_ref,
      cache_affinity_fingerprint: "fingerprint"
    }

    assert {:ok, %Operation.PrefixCacheScoreResult{status_code: "error"}} =
             BeamClient.score_prefix_cache(connection, request, [])
  end

  defp put_beam_config(config) do
    Application.put_env(:orchard_controller, :runtime_endpoint, beam: config)
  end

  defp restore_runtime_endpoint_config(nil) do
    Application.delete_env(:orchard_controller, :runtime_endpoint)
  end

  defp restore_runtime_endpoint_config(config) do
    Application.put_env(:orchard_controller, :runtime_endpoint, config)
  end
end
