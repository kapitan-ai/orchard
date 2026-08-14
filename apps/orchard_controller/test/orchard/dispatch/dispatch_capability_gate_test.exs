defmodule Orchard.Dispatch.DispatchCapabilityGateTest.StubClient do
  @moduledoc false
  @registry __MODULE__.Registry

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    StatusResponse
  }

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def registry_name, do: @registry

  def connect(_target) do
    send(config().capture_pid, :connect_called)
    {:ok, :stub_channel}
  end

  def status(_channel, _opts \\ []) do
    send(config().capture_pid, :status_called)
    {:ok, %StatusResponse{}}
  end

  def disconnect(_channel), do: :ok
  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{} = request, _opts \\ []) do
    send(config().capture_pid, {:captured_ensure_model_loaded_request, request})

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: config().worker_supports_prompt_token_ids
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
         InferenceEvent.completed(:finish_reason_stop, nil)}
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

defmodule Orchard.Dispatch.DispatchCapabilityGateTest do
  use Orchard.DataCase, async: false

  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.Inference
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.TestSupport.DispatchCapacityFixtures

  @stub_client Orchard.Dispatch.DispatchCapabilityGateTest.StubClient
  @prompt_ids [101, 102, 103]

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @stub_client.registry_name()})
    :ok
  end

  test "safe-mode on keeps prompt_token_ids for capable workers and emits dispatch telemetry" do
    attach_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:on, fn ->
      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               dispatch("req-token-ids-on-capable")
    end)

    assert_receive {^attach_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched],
                    %{token_count: 3}, metadata}

    assert metadata.model_id == "test/model"
    assert metadata.worker_supports_prompt_token_ids == true

    assert_receive {:captured_execute_request,
                    %Operation.ExecuteRequest{prompt_token_ids: @prompt_ids}}
  end

  test "safe-mode on with capable worker strips empty prompt_token_ids silently" do
    dispatched_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    unsafe_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:on, fn ->
      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               dispatch_without_prompt_token_ids("req-token-ids-on-empty-capable")
    end)

    refute_receive {^dispatched_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched], _, _}
    refute_receive {^unsafe_ref, [:orchard, :tokenizer, :unsafe_mode_active], _, _}
    assert_receive {:captured_execute_request, %Operation.ExecuteRequest{prompt_token_ids: []}}
  end

  test "safe-mode on strips prompt_token_ids for legacy workers and emits unsafe fallback telemetry" do
    attach_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])
    configure_stub(worker_supports_prompt_token_ids: false)

    with_tokenizer_safe_mode(:on, fn ->
      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               dispatch("req-token-ids-on-legacy")
    end)

    assert_receive {^attach_ref, [:orchard, :tokenizer, :unsafe_mode_active], %{count: 1},
                    metadata}

    assert metadata.reason == :legacy_worker_no_capability
    assert metadata.model_id == "test/model"
    assert_receive {:captured_execute_request, %Operation.ExecuteRequest{prompt_token_ids: []}}
  end

  test "safe-mode off strips prompt_token_ids silently" do
    dispatched_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    unsafe_ref = attach_telemetry([:orchard, :tokenizer, :unsafe_mode_active])
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:off, fn ->
      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               dispatch("req-token-ids-off")
    end)

    refute_receive {^dispatched_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched], _, _}
    refute_receive {^unsafe_ref, [:orchard, :tokenizer, :unsafe_mode_active], _, _}
    assert_receive {:captured_execute_request, %Operation.ExecuteRequest{prompt_token_ids: []}}
  end

  test "safe-mode reject refuses legacy workers without dispatching execute" do
    configure_stub(worker_supports_prompt_token_ids: false)

    with_tokenizer_safe_mode(:reject, fn ->
      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               events: [],
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error"
               }
             } =
               dispatch("req-token-ids-reject-legacy")
    end)

    refute_receive {:captured_execute_request, %Operation.ExecuteRequest{}}
  end

  test "safe-mode reject refuses requests missing prompt_token_ids before ensure_model_loaded" do
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:reject, fn ->
      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               events: [],
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error"
               }
             } =
               dispatch_without_prompt_token_ids("req-token-ids-reject-missing")
    end)

    refute_receive {:captured_ensure_model_loaded_request, %Operation.EnsureModelLoadedRequest{}},
                   200

    refute_receive {:captured_execute_request, %Operation.ExecuteRequest{}}, 200
  end

  test "safe-mode reject missing prompt_token_ids short-circuits before connect and probe" do
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:reject, fn ->
      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               events: [],
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error"
               }
             } =
               dispatch_without_prompt_token_ids("req-token-ids-reject-short-circuit")
    end)

    refute_receive :connect_called, 200
    refute_receive :status_called, 200

    refute_receive {:captured_ensure_model_loaded_request, %Operation.EnsureModelLoadedRequest{}},
                   200

    refute_receive {:captured_execute_request, %Operation.ExecuteRequest{}}, 200
  end

  test "safe-mode reject keeps prompt_token_ids for capable workers and emits dispatch telemetry" do
    attach_ref = attach_telemetry([:orchard, :tokenizer, :prompt_token_ids_dispatched])
    configure_stub(worker_supports_prompt_token_ids: true)

    with_tokenizer_safe_mode(:reject, fn ->
      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               dispatch("req-token-ids-reject-capable")
    end)

    assert_receive {^attach_ref, [:orchard, :tokenizer, :prompt_token_ids_dispatched],
                    %{token_count: 3}, metadata}

    assert metadata.model_id == "test/model"

    assert_receive {:captured_execute_request,
                    %Operation.ExecuteRequest{prompt_token_ids: @prompt_ids}}
  end

  defp configure_stub(overrides) do
    config =
      Map.merge(
        %{
          worker_supports_prompt_token_ids: false,
          capture_pid: self()
        },
        Map.new(overrides)
      )

    Registry.register(@stub_client.registry_name(), :config, config)
  end

  defp dispatch(request_id) do
    dispatch_with_execute_request(request_id, execute_request(request_id))
  end

  defp dispatch_without_prompt_token_ids(request_id) do
    dispatch_with_execute_request(request_id, %{
      execute_request(request_id)
      | prompt_token_ids: []
    })
  end

  defp dispatch_with_execute_request(request_id, execute_request) do
    RequestDispatcher.dispatch(
      schedule(request_id),
      execute_request,
      model_load_request(),
      client_impl: @stub_client
    )
  end

  defp schedule(request_id) do
    DispatchCapacityFixtures.authorize_unmanaged_schedule(%{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000
    })
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "dispatch-capability-gate-test",
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
