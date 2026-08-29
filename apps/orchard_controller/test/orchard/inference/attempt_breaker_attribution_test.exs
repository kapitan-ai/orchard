defmodule Orchard.Inference.AttemptBreakerAttributionTest do
  use Orchard.DataCase, async: false

  alias Orchard.Dispatch.AttemptOutcome
  alias Orchard.Inference.AttemptBreakerAttribution
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node

  describe "record/4" do
    test "attributes an eligible Node failure exactly once to its producing attempt" do
      node = insert_node!()
      model = insert_model!()
      request_id = Ecto.UUID.generate()
      outcome = failed_outcome(node.id, "worker_or_node_loss")

      assert {:ok, recorded} =
               AttemptBreakerAttribution.record(request_id, 1, model.id, outcome)

      assert recorded.kind == :node
      assert recorded.node_id == node.id
      assert recorded.delivery == :recorded
      assert recorded.contribution_count == 1

      assert {:ok, duplicate} =
               AttemptBreakerAttribution.record(request_id, 1, model.id, outcome)

      assert duplicate.delivery == :duplicate
      assert duplicate.id == recorded.id
      assert duplicate.contribution_count == 1
    end

    test "attributes a model-load failure to the producing placement" do
      node = insert_node!()
      model = insert_model!()

      assert {:ok, recorded} =
               AttemptBreakerAttribution.record(
                 Ecto.UUID.generate(),
                 1,
                 model.id,
                 failed_outcome(node.id, "model_load_failure")
               )

      assert recorded.kind == :placement
      assert recorded.node_id == node.id
      assert recorded.model_id == model.id
      assert recorded.contribution_count == 1
    end

    test "does not turn post-start capacity scarcity into breaker evidence" do
      assert {:ok, :not_eligible} =
               AttemptBreakerAttribution.record(
                 Ecto.UUID.generate(),
                 1,
                 Ecto.UUID.generate(),
                 failed_outcome(nil, "capacity_rejection")
               )
    end

    test "keeps separate attempts attributed to their producing Nodes" do
      first_node = insert_node!()
      second_node = insert_node!()
      model = insert_model!()
      request_id = Ecto.UUID.generate()

      assert {:ok, first} =
               AttemptBreakerAttribution.record(
                 request_id,
                 1,
                 model.id,
                 failed_outcome(first_node.id, "pre_acceptance_unavailable")
               )

      assert {:ok, second} =
               AttemptBreakerAttribution.record(
                 request_id,
                 2,
                 model.id,
                 failed_outcome(second_node.id, "worker_or_node_loss")
               )

      assert first.node_id == first_node.id
      assert first.contribution_count == 1
      assert second.node_id == second_node.id
      assert second.contribution_count == 1
    end

    test "does not attribute an eligible class without a persistent Node identity" do
      model = insert_model!()

      assert {:ok, :not_eligible} =
               AttemptBreakerAttribution.record(
                 Ecto.UUID.generate(),
                 1,
                 model.id,
                 failed_outcome(nil, "model_load_failure")
               )

      assert Orchard.Repo.aggregate(Orchard.CircuitBreakers.Failure, :count, :id) == 0
    end
  end

  defp failed_outcome(node_id, failure_class) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    model_load? = failure_class == "model_load_failure"

    {:ok, outcome} =
      AttemptOutcome.new(%{
        attempt_outcome: :failed,
        node_id: node_id,
        accepted: failure_class != "pre_acceptance_unavailable",
        events: [],
        failure: %{
          "failure_class" => failure_class,
          "failure_code" => if(model_load?, do: "load_timeout", else: "internal_error")
        },
        execution_resolution: :terminated,
        capacity_release_outcome: :released,
        started_at: DateTime.add(now, -1, :second),
        ended_at: now,
        first_token_at: nil,
        output_committed: false,
        output_commitment_kind: nil,
        delivery_state: :selected,
        delivered_event_count: 0,
        runtime_retryable: true,
        model_load_category: if(model_load?, do: :timeout, else: nil)
      })

    outcome
  end

  defp insert_node! do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "attempt-breaker-node-#{unique}.local",
      display_name: "attempt-breaker-node-#{unique}",
      advertise_addr: "10.253.#{rem(div(unique, 254), 254)}.#{rem(unique, 254) + 1}",
      rpc_port: 9444,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp insert_model! do
    unique = System.unique_integer([:positive])

    %Model{}
    |> Model.changeset(%{
      model_id: "attempt-breaker-model-#{unique}",
      version: "main",
      state: :active,
      format: "mlx",
      capabilities: ["text"],
      tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
      artifact_uri: "file:///tmp/attempt-breaker-model-#{unique}",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      resident_memory_bytes: 1,
      kv_cache_bytes_per_token: 1,
      prefill_workspace_bytes_per_token: 1,
      runtime_requirements: %{}
    })
    |> Repo.insert!()
  end
end
