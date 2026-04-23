defmodule Orchard.TestSupport.QueueAdmissionRuntimeAdapter do
  @moduledoc false

  alias Orchard.Cluster.V1.{ExecuteInferenceRequest, ModelRef}
  alias Orchard.InferenceEvent

  def get_status(_adapter_state, _opts),
    do: {:ok, %{ready: true, health_code: "", health_message: ""}}

  def load_model(%ModelRef{} = model_ref, _opts), do: {:ok, %{model_ref: model_ref}}

  def unload_model(_adapter_state, _opts), do: :ok

  def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
    test_owner = Application.fetch_env!(:orchard_controller, :queue_admission_api_runtime_owner)
    runtime_owner = Keyword.fetch!(opts, :owner)
    generation_ref = make_ref()

    send(
      test_owner,
      {:queue_admission_runtime_started, self(), request.request_id, request.model_id}
    )

    receive do
      :queue_admission_runtime_release -> :ok
    after
      5_000 -> send(test_owner, {:queue_admission_runtime_release_timeout, request.request_id})
    end

    Enum.each(runtime_events(request), fn event ->
      send(runtime_owner, {:runtime_adapter_event, generation_ref, event})
    end)

    send(runtime_owner, {:runtime_adapter_done, generation_ref})

    {:ok, generation_ref, adapter_state}
  end

  def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

  def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state

  defp runtime_events(request) do
    [
      InferenceEvent.output_text_delta("queued ok"),
      InferenceEvent.completed(
        :finish_reason_stop,
        %InferenceEvent.Usage{
          input_tokens: request.input_tokens,
          output_tokens: 2,
          total_tokens: request.input_tokens + 2
        }
      )
    ]
  end
end

defmodule Orchard.TestSupport.QueueAdmissionAPI do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions

  alias Orchard.Inference.QueueManager
  alias Orchard.Repo
  alias Orchard.Requests.Request
  alias Orchard.TestSupport.ModelRequestFixtures
  alias Orchard.TestSupport.QueueAdmissionRuntimeAdapter

  def put_queue_admission_config!(overrides \\ []) do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    queue_config =
      Orchard.Inference.queue_admission_config()
      |> Keyword.merge(
        enabled: true,
        single_controller_ack: true,
        max_wait_ms: 1_000,
        max_queued_per_tenant: 32,
        poll_interval_ms: 5,
        capacity: 1,
        owner_runtime: true
      )
      |> Keyword.merge(overrides)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(inference, :queue_admission, queue_config)
    )

    QueueManager.reset()
  end

  def put_blocking_runtime_adapter!(test_owner) do
    runtime =
      Application.fetch_env!(:orchard_node_agent, :runtime)
      |> Keyword.put(:runtime_adapter_impl, QueueAdmissionRuntimeAdapter)

    Application.put_env(:orchard_node_agent, :runtime, runtime)
    Application.put_env(:orchard_controller, :queue_admission_api_runtime_owner, test_owner)
  end

  def create_queue_model!(bundle, model_id) do
    ModelRequestFixtures.create_model!(%{
      model_id: model_id,
      version: "v1",
      display_name: model_id,
      artifact_uri: "file:///tmp/#{model_id}",
      artifact_sha256: bundle.hash,
      artifact_source_uri: "file:///tmp/#{model_id}",
      state: :active,
      format: "mlx",
      backend: "mlx",
      capabilities: ["chat"],
      artifact_size_bytes: 1024,
      resident_memory_bytes: 2048,
      kv_cache_bytes_per_token: 128,
      prefill_workspace_bytes_per_token: 64,
      max_context_tokens: 131_072
    })
  end

  def wait_for_queued_request(requested_model) do
    wait_until(fn ->
      Request
      |> where(
        [request],
        request.requested_model == ^requested_model and request.state == :queued
      )
      |> Repo.exists?()
    end)
  end

  def request_with_queue_result!(requested_model, queue_result) do
    Request
    |> where([request], request.requested_model == ^requested_model)
    |> Repo.all()
    |> Enum.find(fn request ->
      request.scheduler_decision && request.scheduler_decision["queue_result"] == queue_result
    end)
    |> case do
      nil -> flunk("expected #{requested_model} request with queue_result=#{queue_result}")
      request -> request
    end
  end

  def assert_queue_metadata(request, queue_result, opts \\ []) do
    metadata = request.scheduler_decision || %{}

    assert metadata["queueing_enabled"] == true
    assert metadata["queue_key"] == request.requested_model
    assert metadata["queue_result"] == queue_result
    assert is_integer(metadata["queue_wait_ms"])
    assert metadata["queue_wait_ms"] >= 0

    if Keyword.get(opts, :queued?, false) do
      assert is_binary(metadata["queued_at"])
    else
      refute Map.has_key?(metadata, "queued_at")
    end

    if Keyword.get(opts, :granted?, false) do
      assert is_binary(metadata["queue_grant_id"])
      assert is_binary(metadata["queue_granted_at"])
    else
      refute Map.has_key?(metadata, "queue_grant_id")
      refute Map.has_key?(metadata, "queue_granted_at")
    end
  end

  def wait_until(fun, attempts \\ 50)

  def wait_until(fun, attempts) when attempts <= 0, do: fun.()

  def wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
