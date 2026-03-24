defmodule Orchard.InferenceTest do
  use ExUnit.Case, async: false
  import Orchard.TestSupport.RepoHelpers

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
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
  end

  test "default scheduler and runtime seam use configured runtime target" do
    request = canonical_request()

    assert {:ok, schedule} = SingleNode.schedule(request)
    assert schedule.strategy == :single_node
    assert schedule.request_id == request.public_id
    assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
    assert schedule.request_timeout_ms == 5_000
    assert schedule.model_load_timeout_ms == 5_000

    assert Client.mode() == :fake

    assert String.ends_with?(
             Client.executable(),
             "/native/orchard_tokenizer/bin/orchard-tokenizer"
           )
  end

  test "tokenizer and scheduler seams are injectable" do
    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(Application.fetch_env!(:orchard_controller, :inference),
        tokenizer_client_impl: FakeTokenizer,
        scheduler_impl: FakeScheduler
      )
    )

    request = canonical_request()

    assert {:ok, %{public_id: "req_inference_test", tokenizer: :fake}} =
             Client.tokenize(request, source: :test)

    assert {:ok, %{scheduled_public_id: "req_inference_test", scheduler: :fake}} =
             SingleNode.schedule(request)
  end

  describe "scheduler repo-off fallback" do
    test "SingleNode.schedule/1 returns node_id: nil when Repo is unavailable" do
      request = canonical_request()

      with_repo_unregistered(fn ->
        assert {:ok, schedule} = SingleNode.schedule(request)
        assert schedule.strategy == :single_node
        assert schedule.runtime_client_target == [host: "127.0.0.1", port: 50_071]
        assert schedule.request_timeout_ms == 5_000
        assert schedule.model_load_timeout_ms == 5_000
        assert schedule.node_id == nil
      end)
    end
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
