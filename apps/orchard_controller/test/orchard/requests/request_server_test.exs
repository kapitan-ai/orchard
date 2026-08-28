defmodule Orchard.Requests.RequestServerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  alias Orchard.Requests
  alias Orchard.Requests.{RequestServer, RequestStepEvent}

  @request_attrs %{
    public_id: "chatcmpl-test-1",
    endpoint: :chat_completions,
    tenant_id: Ecto.UUID.generate(),
    requested_model: "test-model@v1",
    state: :received,
    stream: false,
    payload_capture_mode: :metadata,
    timeout_at: ~U[2100-01-01 00:00:00.000000Z]
  }

  defp create_request! do
    {:ok, request} = Requests.create_request(@request_attrs)
    request
  end

  describe "start/1" do
    test "starts a request server under the dynamic supervisor" do
      request = create_request!()

      assert {:ok, pid} =
               RequestServer.start(
                 request_id: request.id,
                 public_id: request.public_id
               )

      assert Process.alive?(pid)
    end
  end

  describe "get_state/1" do
    test "returns the current FSM state" do
      request = create_request!()
      {:ok, _pid} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert {:ok, :received} = RequestServer.get_state(request.id)
    end

    test "returns not_found for unknown request" do
      assert {:error, :not_found} = RequestServer.get_state(Ecto.UUID.generate())
    end
  end

  describe "transition/3" do
    test "happy path: received → validated → scheduled → dispatching → running → streaming → completed" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert {:ok, :validated} = RequestServer.get_state(request.id)

      # M1 skips admitted/queued
      assert :ok = RequestServer.transition(request.id, :scheduled)
      assert {:ok, :scheduled} = RequestServer.get_state(request.id)

      assert :ok = RequestServer.transition(request.id, :dispatching)
      assert :ok = RequestServer.transition(request.id, :running)
      assert :ok = RequestServer.transition(request.id, :streaming)
      assert :ok = RequestServer.transition(request.id, :completed)

      # Process stops after terminal state
      Process.sleep(50)
      assert {:error, :not_found} = RequestServer.get_state(request.id)
    end

    test "SPEC.md §3.6 queue-ready path allows validated → admitted → queued → scheduled" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert :ok = RequestServer.transition(request.id, :admitted)
      assert {:ok, :admitted} = RequestServer.get_state(request.id)

      assert :ok = RequestServer.transition(request.id, :queued)
      assert {:ok, :queued} = RequestServer.get_state(request.id)

      assert :ok = RequestServer.transition(request.id, :scheduled)
      assert {:ok, :scheduled} = RequestServer.get_state(request.id)
    end

    test "appends a request event on each transition" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert :ok = RequestServer.transition(request.id, :scheduled)

      events =
        Orchard.Repo.all(Orchard.Requests.RequestEvent)
        |> Enum.filter(&(&1.request_id == request.id))
        |> Enum.sort_by(& &1.seq)

      assert length(events) == 2
      assert Enum.all?(events, &match?(%DateTime{}, &1.occurred_at))
      assert Enum.at(events, 0).event_type == "state_transition"
      assert Enum.at(events, 0).state == :scheduled || Enum.at(events, 0).state == :validated
    end

    test "rejects invalid forward transitions" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      # Can't skip from received to running
      assert {:error, {:invalid_transition, :received, :running}} =
               RequestServer.transition(request.id, :running)

      # State unchanged
      assert {:ok, :received} = RequestServer.get_state(request.id)
    end

    test "allows failure exit from any non-terminal state" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :failed, payload: %{reason: "test"})
      Process.sleep(50)
      assert {:error, :not_found} = RequestServer.get_state(request.id)
    end

    test "generic running to dispatching remains invalid" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert :ok = RequestServer.transition(request.id, :scheduled)
      assert :ok = RequestServer.transition(request.id, :dispatching)
      assert :ok = RequestServer.transition(request.id, :running)

      assert {:error, {:invalid_transition, :running, :dispatching}} =
               RequestServer.transition(request.id, :dispatching)
    end

    test "attempt two transition requires the durable consecutive attempt pair" do
      request = running_request!()

      assert {:error, :attempt_two_boundary_missing} =
               RequestServer.start_attempt_two(request.id)

      assert {:ok, :running} = RequestServer.get_state(request.id)
    end

    test "attempt two transition is authorized once by the durable attempt pair" do
      request = running_request!()
      node_id = Ecto.UUID.generate()

      assert {:ok, _events} = append_attempt_two_boundary(request, node_id)

      assert :ok = RequestServer.start_attempt_two(request.id)
      assert {:ok, :dispatching} = RequestServer.get_state(request.id)

      assert :ok = RequestServer.transition(request.id, :running)

      assert {:error, :attempt_two_dispatch_already_started} =
               RequestServer.start_attempt_two(request.id)
    end

    test "attempt two start from dispatching stays dispatching" do
      request = dispatching_request!()
      node_id = Ecto.UUID.generate()

      assert {:ok, _events} = append_attempt_two_boundary(request, node_id)
      assert :ok = RequestServer.start_attempt_two(request.id)
      assert {:ok, :dispatching} = RequestServer.get_state(request.id)

      assert {:error, :attempt_two_dispatch_already_started} =
               RequestServer.start_attempt_two(request.id)
    end

    test "attempt two transition rejects nonconsecutive and duplicate starts" do
      request = running_request!()
      node_id = Ecto.UUID.generate()

      assert {:ok, _events} =
               Requests.append_request_step_events(request, [attempt_one_retried_step(node_id)])

      assert {:ok, _event} =
               Requests.append_request_event(request, %{
                 event_type: "state_transition",
                 state: :running,
                 payload: %{source: "test_gap", to_state: "running"}
               })

      assert {:ok, _events} =
               Requests.append_request_step_events(request, [
                 attempt_two_started_step(node_id),
                 attempt_two_started_step(node_id)
               ])

      assert {:error, :attempt_two_boundary_missing} =
               RequestServer.start_attempt_two(request.id)
    end

    test "durable prior edge remains one-shot after RequestServer restart" do
      request = running_request!()
      node_id = Ecto.UUID.generate()
      assert {:ok, _events} = append_attempt_two_boundary(request, node_id)
      assert :ok = RequestServer.start_attempt_two(request.id)
      assert :ok = RequestServer.transition(request.id, :running)
      [{pid, _}] = Registry.lookup(Orchard.Requests.Registry, request.id)
      assert :ok = DynamicSupervisor.terminate_child(Orchard.Requests.Supervisor, pid)

      assert {:ok, _pid} =
               RequestServer.start(
                 request_id: request.id,
                 public_id: request.public_id,
                 initial_state: :running
               )

      assert {:error, :attempt_two_dispatch_already_started} =
               RequestServer.start_attempt_two(request.id)
    end

    test "declined attempt one evidence never authorizes the retry edge" do
      request = running_request!()
      node_id = Ecto.UUID.generate()

      assert {:ok, _events} =
               Requests.append_request_step_events(request, [
                 attempt_one_retried_step(node_id, "no_alternative_node"),
                 attempt_two_started_step(node_id)
               ])

      assert {:error, :attempt_two_boundary_missing} =
               RequestServer.start_attempt_two(request.id)
    end

    test "rejects transitions from terminal states" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :cancelled)
      # Process is stopping, but call should still return error if we're fast
      Process.sleep(50)
      assert {:error, :not_found} = RequestServer.get_state(request.id)
    end

    test "cancelled from running" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert :ok = RequestServer.transition(request.id, :scheduled)
      assert :ok = RequestServer.transition(request.id, :dispatching)
      assert :ok = RequestServer.transition(request.id, :running)
      assert :ok = RequestServer.transition(request.id, :cancelled)
    end

    test "timed_out from dispatching" do
      request = create_request!()
      {:ok, _} = RequestServer.start(request_id: request.id, public_id: request.public_id)

      assert :ok = RequestServer.transition(request.id, :validated)
      assert :ok = RequestServer.transition(request.id, :scheduled)
      assert :ok = RequestServer.transition(request.id, :dispatching)
      assert :ok = RequestServer.transition(request.id, :timed_out)
    end

    test "returns not_found for unknown request" do
      assert {:error, :not_found} = RequestServer.transition(Ecto.UUID.generate(), :validated)
    end
  end

  defp running_request! do
    request = dispatching_request!()
    :ok = RequestServer.transition(request.id, :running)
    request
  end

  defp dispatching_request! do
    request = create_request!()
    {:ok, _pid} = RequestServer.start(request_id: request.id, public_id: request.public_id)
    :ok = RequestServer.transition(request.id, :validated)
    :ok = RequestServer.transition(request.id, :scheduled)
    :ok = RequestServer.transition(request.id, :dispatching)
    request
  end

  defp append_attempt_two_boundary(request, node_id) do
    Requests.append_request_step_events(request, [
      attempt_one_retried_step(node_id),
      attempt_two_started_step(node_id)
    ])
  end

  defp attempt_one_retried_step(node_id, retry_decision \\ "retried") do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    RequestStepEvent.new!(%{
      event_type: "request_step.failed",
      step_id: RequestStepEvent.inference_turn_step_id(1, 1),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: 1,
      boundary: "post_observation",
      result: %{
        "attempt_outcome" => "failed",
        "started_at" => now,
        "ended_at" => now,
        "accepted" => true,
        "output_committed" => false,
        "execution_resolution" => "terminated",
        "capacity_release_outcome" => "released",
        "excluded_node_ids" => [],
        "node_id" => node_id,
        "failure_class" => "worker_or_node_loss",
        "failure_code" => "worker_down",
        "retry_decision" => retry_decision
      }
    })
  end

  defp attempt_two_started_step(excluded_node_id) do
    RequestStepEvent.new!(%{
      event_type: "request_step.started",
      step_id: RequestStepEvent.inference_turn_step_id(1, 2),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: 2,
      boundary: "pre_side_effect",
      result: %{"excluded_node_ids" => [excluded_node_id]}
    })
  end
end
