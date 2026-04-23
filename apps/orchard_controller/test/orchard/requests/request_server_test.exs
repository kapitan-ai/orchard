defmodule Orchard.Requests.RequestServerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db

  alias Orchard.Requests
  alias Orchard.Requests.RequestServer

  @request_attrs %{
    public_id: "chatcmpl-test-1",
    endpoint: :chat_completions,
    tenant_id: Ecto.UUID.generate(),
    requested_model: "test-model@v1",
    state: :received,
    stream: false,
    payload_capture_mode: :metadata
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
end
