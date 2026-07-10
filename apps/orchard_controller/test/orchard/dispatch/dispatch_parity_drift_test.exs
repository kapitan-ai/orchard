defmodule Orchard.Dispatch.DispatchParityDriftTest.StubClient do
  @moduledoc false
  @registry __MODULE__.Registry

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    RuntimeNodeMetadata,
    StatusResponse
  }

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  @node_id "550e8400-e29b-41d4-a716-446655440000"

  def registry_name, do: @registry

  def connect(_target), do: {:ok, :stub_channel}

  def status(_channel, _opts \\ []) do
    {:ok,
     %StatusResponse{
       node_metadata: %RuntimeNodeMetadata{node_id: @node_id, display_name: "parity-node"}
     }}
  end

  def disconnect(_channel), do: :ok
  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{} = request, _opts \\ []) do
    send(config().capture_pid, {:captured_ensure_model_loaded_request, request})

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()
    send(config().capture_pid, {:captured_execute_request, request})

    spawn(fn ->
      send(owner, {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)})

      send(
        owner,
        {:runtime_endpoint_event, ref, request.request_id,
         InferenceEvent.failed(
           "prompt_token_ids_length_mismatch",
           config().worker_message,
           false
         )}
      )

      send(owner, {:runtime_endpoint_done, ref, :ok})
    end)

    {:ok, ref}
  end

  defp config do
    [{_pid, config}] = Registry.lookup(@registry, :config)
    config
  end
end

defmodule Orchard.Dispatch.DispatchParityDriftTest do
  use Orchard.DataCase, async: false

  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Inference
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  @stub_client Orchard.Dispatch.DispatchParityDriftTest.StubClient
  @event [:orchard, :tokenizer, :parity_drift]
  @node_id "550e8400-e29b-41d4-a716-446655440000"
  @prompt_ids [101, 102]
  @long_worker_message "prompt_token_ids length 2 does not match input_tokens 3 — " <>
                         String.duplicate("界", 140)

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @stub_client.registry_name()})

    Registry.register(@stub_client.registry_name(), :config, %{
      capture_pid: self(),
      worker_message: @long_worker_message
    })

    :ok
  end

  test "emits parity_drift telemetry for streamed prompt token length mismatch" do
    attach_ref = attach_telemetry(@event)

    with_tokenizer_safe_mode(:on, fn ->
      assert {:ok, events} = dispatch("req-parity-drift-stream")

      assert Enum.any?(events, fn
               %InferenceEvent{
                 event: %InferenceEvent.Failed{code: "prompt_token_ids_length_mismatch"}
               } ->
                 true

               _event ->
                 false
             end)
    end)

    assert_receive {^attach_ref, @event, %{count: 1}, metadata}

    assert metadata.request_id == "req-parity-drift-stream"
    assert metadata.model_id == "test/model"
    assert metadata.version == "v1"
    assert metadata.node_id == @node_id
    assert metadata.scheduler_strategy == :single_node
    assert metadata.input_tokens == 3
    assert metadata.code == "prompt_token_ids_length_mismatch"
    assert metadata.worker_message =~ "prompt_token_ids length"
    assert String.valid?(metadata.worker_message)
    assert byte_size(metadata.worker_message) <= 256
    assert byte_size(metadata.worker_message) < byte_size(@long_worker_message)
    refute Map.has_key?(metadata, :worker_id)
    refute Map.has_key?(metadata, :expected_len)
    refute Map.has_key?(metadata, :actual_len)

    assert_receive {:captured_ensure_model_loaded_request, %Operation.EnsureModelLoadedRequest{}}

    assert_receive {:captured_execute_request,
                    %Operation.ExecuteRequest{prompt_token_ids: @prompt_ids}}
  end

  test "does not emit parity_drift telemetry for synthesized terminal mismatch failures" do
    attach_ref = attach_telemetry(@event)

    metrics = metrics("req-parity-drift-synthesized")

    event =
      InferenceEvent.failed(
        "prompt_token_ids_length_mismatch",
        "controller synthesized failure",
        false
      )

    RequestDispatcher.__test_update_metrics_for_terminal__(metrics, event, :synthesized)

    refute_receive {^attach_ref, @event, _measurements, _metadata}, 200
  end

  defp dispatch(request_id) do
    RequestDispatcher.dispatch(
      schedule(request_id),
      execute_request(request_id),
      model_load_request(),
      client_impl: @stub_client
    )
  end

  defp schedule(request_id) do
    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000
    }
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "dispatch-parity-drift-test",
      model_id: "test/model",
      version: "v1",
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 3,
      prompt_token_ids: @prompt_ids
    }
  end

  defp model_load_request do
    %EnsureModelLoadedRequest{
      node_id: "local",
      model_id: "test/model",
      version: "v1"
    }
  end

  defp metrics(request_id) do
    RequestDispatcher.__test_metrics__(%{
      request_id: request_id,
      model_id: "test/model",
      version: "v1",
      input_tokens: 3,
      node_id: "local",
      scheduler_strategy: :single_node
    })
  end

  defp attach_telemetry(event) do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      inspect(ref),
      event,
      fn event_name, measurements, metadata, _config ->
        send(parent, {ref, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
  end

  defp with_tokenizer_safe_mode(mode, fun) do
    previous = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(previous, :tokenizer_safe_mode, mode)
    )

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :inference, previous)
    end
  end
end
