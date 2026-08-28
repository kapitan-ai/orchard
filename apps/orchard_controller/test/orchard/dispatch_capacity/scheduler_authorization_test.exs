defmodule Orchard.DispatchCapacity.SchedulerAuthorizationTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Models
  alias Orchard.NodeHeartbeats
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.RuntimeEndpoint.Target
  alias Orchard.Scheduler.MultiNode
  alias Orchard.Scheduler.SingleNode

  defmodule StatusClient do
    @moduledoc false

    def connect(target), do: {:ok, target}
    def status(_target, _opts), do: {:ok, Process.get(:capacity_status)}
    def disconnect(_channel), do: :ok
  end

  setup do
    ensure_model!()

    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    previous_artifact_provider =
      Application.get_env(:orchard_controller, :scheduler_artifact_acquirable_provider)

    Process.put(:capacity_status, %{
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    })

    Application.put_env(
      :orchard_controller,
      :scheduler_artifact_acquirable_provider,
      fn _request -> true end
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)

      if is_nil(previous_artifact_provider) do
        Application.delete_env(:orchard_controller, :scheduler_artifact_acquirable_provider)
      else
        Application.put_env(
          :orchard_controller,
          :scheduler_artifact_acquirable_provider,
          previous_artifact_provider
        )
      end
    end)

    :ok
  end

  test "SPEC 4.2 admitted SingleNode scheduling uses shared capacity values" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()
    input = enforcing_input(2)

    assert {:ok, schedule} =
             SingleNode.default_schedule(canonical_request(), target(node),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _response, _placement ->
                 {:ok, input}
               end
             )

    assert schedule.node_id == node.id
    assert schedule.queue_lane_capacity == 2
    assert schedule.dispatch_capacity_input == input
    assert schedule.dispatch_capacity_evaluation.authority_decision == :f11_enforcing
  end

  test "SPEC 4.2 admitted SingleNode authorization failure has no direct-schedule fallback" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(canonical_request(), target(node),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _response, _placement ->
                 {:ok, enforcing_input(0)}
               end
             )
  end

  test "SPEC 4.1 MultiNode eligibility and lane contribution use the shared evaluation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()
    configure_target(node)
    put_status(node)
    input = enforcing_input(1)

    assert {:ok, schedule} =
             MultiNode.schedule(canonical_request(),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _observation, _placement ->
                 {:ok, input}
               end
             )

    assert schedule.node_id == node.id
    assert schedule.queue_lane_capacity == 1
    assert schedule.dispatch_capacity_input == input
    assert schedule.dispatch_capacity_evaluation.available_slots == 1
  end

  test "SPEC 4.1 MultiNode does not fall back around a failed shared evaluation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()
    configure_target(node)
    put_status(node)

    assert {:error, :cluster_busy, _decision} =
             MultiNode.schedule(canonical_request(),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _observation, _placement ->
                 {:ok, enforcing_input(0)}
               end
             )
  end

  test "SPEC 4.1 MultiNode never rejects and selects the same candidate" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()
    configure_target(node)
    put_status(node)

    status = Process.get(:capacity_status)
    Process.put(:capacity_status, %{status | active_request_count: 2, max_concurrency: 2})

    assert {:ok, schedule} =
             MultiNode.schedule(canonical_request(),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _observation, _placement ->
                 {:ok, enforcing_input(2)}
               end
             )

    assert schedule.node_id == node.id
    assert schedule.rejected_candidates == []
    assert Enum.all?(schedule.scored_candidates, & &1.eligible)
  end

  test "SPEC 4.1 MultiNode reports a busy cluster when the authority is unavailable" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node = insert_node!()
    configure_target(node)
    put_status(node)
    stop_supervised!(AllocationAuthority)

    assert {:error, :cluster_busy, _decision} =
             MultiNode.schedule(canonical_request(),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               dispatch_capacity_input_provider: fn _node, _observation, _placement ->
                 {:ok, enforcing_input(2)}
               end
             )
  end

  test "SPEC 4.6.2 SingleNode rejects a probe not bound to current authenticated evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    evidence_at = DateTime.add(DateTime.utc_now(), -1, :second)
    observed_at = DateTime.utc_now()
    node = insert_node!(evidence_observed_at: evidence_at)
    put_status(node)

    assert {:error, :model_busy, _decision} =
             SingleNode.default_schedule(canonical_request(), target(node),
               status_client: StatusClient,
               dispatch_capacity_authority: authority,
               observed_at: observed_at
             )
  end

  test "SPEC 4.6.2 MultiNode rejects a production snapshot not bound to current authenticated evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    evidence_at = DateTime.add(DateTime.utc_now(), -1, :second)
    observed_at = DateTime.utc_now()
    node = insert_node!(evidence_observed_at: evidence_at)
    runtime_target = trusted_runtime_target(node)
    append_production_heartbeat!(node, runtime_target, observed_at)

    assert {:error, :cluster_busy, _decision} =
             MultiNode.schedule(canonical_request(),
               dispatch_capacity_authority: authority,
               observed_at: observed_at,
               active_runtime_endpoint_targets_provider: fn -> {:ok, [runtime_target]} end,
               runtime_endpoint_targets_provider: fn
                 {:ok, [^runtime_target]} ->
                   [runtime_target]

                 _inventory ->
                   flunk("production identity rejection must not enter compatibility fallback")
               end
             )
  end

  defp insert_node!(opts \\ []) do
    unique = System.unique_integer([:positive])
    now = DateTime.utc_now()

    node =
      %Node{}
      |> Node.changeset(%{
        id: Ecto.UUID.generate(),
        hostname: "capacity-#{unique}.local",
        display_name: "capacity-#{unique}",
        advertise_addr: "10.44.0.#{rem(unique, 200) + 1}",
        rpc_port: 50_071,
        state: :active,
        health: :healthy,
        capabilities: %{},
        last_heartbeat_at: Keyword.get(opts, :evidence_observed_at, now)
      })
      |> Repo.insert!()

    decision =
      %AdmissionDecision{}
      |> AdmissionDecision.changeset(%{
        node_id: node.id,
        decision: :admitted,
        actor_type: "system",
        actor_id: "scheduler-authorization-test",
        observed_identity: %{},
        metadata: %{},
        decided_at: now
      })
      |> Repo.insert!()

    %Policy{}
    |> Policy.approved_explicit_changeset(%{
      node_id: node.id,
      admission_decision_id: decision.id,
      controller_dispatch_ceiling: 2,
      approved_by_actor_type: "system",
      approved_by_actor_id: "scheduler-authorization-test",
      approved_at: now,
      approval_reason: "scheduler authorization fixture"
    })
    |> Repo.insert!()

    case Keyword.fetch(opts, :evidence_observed_at) do
      {:ok, evidence_observed_at} ->
        {:ok, _evidence} =
          DispatchCapacity.record_capacity_evidence(node.id, %{
            active_request_count: 0,
            observed_at: evidence_observed_at,
            runtime_concurrency_limit: 2,
            validity: :valid
          })

      :error ->
        :ok
    end

    node
  end

  defp target(node), do: [host: node.advertise_addr, port: node.rpc_port]

  defp trusted_runtime_target(node) do
    Target.grpc_compat(
      host: node.advertise_addr,
      port: node.rpc_port,
      node_id: node.id,
      metadata: %{
        source: :trusted_node_inventory,
        authorization: :inference_dispatch,
        certificate_identifier: "certificate-#{node.id}",
        certificate_fingerprint: String.duplicate("a", 64)
      }
    )
  end

  defp append_production_heartbeat!(node, runtime_target, observed_at) do
    observation = %{
      endpoint_id: runtime_target.id,
      availability: :available,
      worker_state: :idle,
      aggregate_active_request_count: 0,
      aggregate_max_concurrency: 2
    }

    {:ok, _heartbeat} =
      Repo.transaction(fn ->
        current_node = Repo.get!(Node, node.id)

        current_node =
          current_node
          |> Node.changeset(%{last_heartbeat_at: observed_at})
          |> Repo.update!()

        {:ok, heartbeat} =
          NodeHeartbeats.append(current_node, runtime_target, observation, observed_at)

        heartbeat
      end)
  end

  defp configure_target(node) do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(inference,
        runtime_client_target: target(node),
        runtime_client_targets: [target(node)],
        runtime_endpoint_targets: []
      )
    )
  end

  defp put_status(node) do
    Process.put(:capacity_status, %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: node.advertise_addr,
        listen_port: node.rpc_port,
        worker_backend: "mlx"
      },
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    })
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "internal-capacity",
      public_id: "public-capacity",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %ModelRef{model_id: "test/model", version: "v1"},
      rendered_prompt: "hello"
    })
  end

  defp ensure_model! do
    Models.get_model_by_identity("test/model", "v1") ||
      case Models.create_model(%{
             model_id: "test/model",
             version: "v1",
             state: :active,
             format: "mlx",
             capabilities: ["text"],
             tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
             artifact_uri: "file:///tmp/dispatch-capacity-test-model",
             artifact_sha256: String.duplicate("a", 64),
             artifact_size_bytes: 1,
             resident_memory_bytes: 1,
             kv_cache_bytes_per_token: 1,
             prefill_workspace_bytes_per_token: 1,
             runtime_requirements: %{}
           }) do
        {:ok, model} -> model
        {:error, changeset} -> raise "failed to create test model: #{inspect(changeset.errors)}"
      end
  end

  defp enforcing_input(ceiling) do
    %Input{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 2},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: {:valid, ceiling},
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end
end
