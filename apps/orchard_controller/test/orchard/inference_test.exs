defmodule Orchard.InferenceTest do
  use ExUnit.Case, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Dispatch.NodeRuntimeClient
  alias Orchard.Inference
  alias Orchard.Scheduler.SingleNode
  alias Orchard.Tokenizer.Client

  defmodule FakeTokenizer do
    @behaviour Orchard.Tokenizer.Client

    def tokenize(%CanonicalRequest{} = request, opts) do
      {:ok, %{public_id: request.public_id, opts: opts, tokenizer: :fake}}
    end
  end

  defmodule FakeScheduler do
    @behaviour Orchard.Scheduler.SingleNode

    def schedule(%CanonicalRequest{} = request) do
      {:ok, %{scheduled_public_id: request.public_id, scheduler: :fake}}
    end
  end

  defmodule FakeNodeRuntimeClient do
    @behaviour Orchard.Dispatch.NodeRuntimeClient

    def status, do: {:ok, %{status: :fake}}
    def ensure_model_loaded(_request), do: {:ok, %{loaded: true}}

    def execute_inference(%CanonicalRequest{} = request) do
      {:ok, %{executed_public_id: request.public_id, client: :fake}}
    end

    def cancel_inference(request_id, controller_session_id) do
      {:ok,
       %{request_id: request_id, controller_session_id: controller_session_id, cancelled: true}}
    end
  end

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end)

    :ok
  end

  test "inference module exposes configured seams and subtree" do
    assert is_pid(Process.whereis(Orchard.Inference))
    assert is_pid(Process.whereis(Orchard.Requests.Supervisor))

    assert Inference.request_supervisor() == Orchard.Requests.Supervisor
    assert Inference.tokenizer_client() == Orchard.Tokenizer.Client
    assert Inference.scheduler() == Orchard.Scheduler.SingleNode
    assert Inference.node_runtime_client() == Orchard.Dispatch.NodeRuntimeClient
  end

  test "default scheduler and runtime seam use configured runtime target" do
    request = canonical_request()

    assert {:ok, schedule} = SingleNode.schedule(request)
    assert schedule.strategy == :single_node
    assert schedule.request_id == request.public_id
    assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
    assert schedule.request_timeout_ms == 5_000

    assert {:ok, status} = NodeRuntimeClient.status()
    assert status.target == [host: "127.0.0.1", port: 50_071]
    assert status.status == :not_connected

    assert Client.mode() == :fake

    assert String.ends_with?(
             Client.executable(),
             "/native/orchard_tokenizer/bin/orchard-tokenizer"
           )
  end

  test "tokenizer, scheduler, and node client seams are injectable" do
    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(Application.fetch_env!(:orchard_controller, :inference),
        tokenizer_client_impl: FakeTokenizer,
        scheduler_impl: FakeScheduler,
        node_runtime_client_impl: FakeNodeRuntimeClient
      )
    )

    request = canonical_request()

    assert {:ok, %{public_id: "req_inference_test", tokenizer: :fake}} =
             Client.tokenize(request, source: :test)

    assert {:ok, %{scheduled_public_id: "req_inference_test", scheduler: :fake}} =
             SingleNode.schedule(request)

    assert {:ok, %{executed_public_id: "req_inference_test", client: :fake}} =
             NodeRuntimeClient.execute_inference(request)

    assert {:ok, %{request_id: "req_inference_test", cancelled: true}} =
             NodeRuntimeClient.cancel_inference("req_inference_test", "controller-session-1")
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "req_internal_test",
      public_id: "req_inference_test",
      endpoint: :chat_completions,
      tenant_id: "tenant_test",
      model_ref: %ModelRef{model_id: "mlx-community/phi-3", version: "main"}
    })
  end
end
