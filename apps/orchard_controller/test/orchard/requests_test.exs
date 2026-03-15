defmodule Orchard.RequestsTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.Models
  alias Orchard.Requests
  alias Orchard.Requests.Request

  test "create_request/1 supports early lifecycle rows before model resolution and canonicalization" do
    attrs = request_attrs()
    assert {:ok, request} = Requests.create_request(attrs)

    assert request.state == :received
    assert request.model_id == nil
    assert request.canonical_request == nil
    assert request.requested_model == attrs.requested_model
  end

  test "append_request_event/2 auto-assigns per-request sequence numbers" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_test"}))

    assert {:ok, first} =
             Requests.append_request_event(request, %{
               event_type: "request.received",
               state: :received
             })

    assert {:ok, second} =
             Requests.append_request_event(request.id, %{
               event_type: "request.validated",
               state: :validated
             })

    assert first.seq == 1
    assert second.seq == 2

    assert Enum.map(Requests.list_request_events(request), & &1.event_type) == [
             "request.received",
             "request.validated"
           ]
  end

  test "append_request_event/2 ignores caller-supplied sequence numbers" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_override_test"}))

    assert {:ok, first} =
             Requests.append_request_event(request, %{
               seq: 99,
               event_type: "request.received",
               state: :received
             })

    assert {:ok, second} =
             Requests.append_request_event(request, %{
               seq: 7,
               event_type: "request.validated",
               state: :validated
             })

    assert first.seq == 1
    assert second.seq == 2
  end

  test "append_request_event/2 accepts string-keyed event payload attrs without crashing" do
    assert {:ok, request} =
             Requests.create_request(request_attrs(%{public_id: "req_event_string_keys_test"}))

    assert {:ok, event} =
             Requests.append_request_event(request.id, %{
               "event_type" => "request.received",
               "state" => :received,
               "payload" => %{"phase" => "ingress"}
             })

    assert event.seq == 1
    assert event.event_type == "request.received"
    assert event.payload == %{"phase" => "ingress"}
  end

  test "append_request_event/2 returns a handled error for unknown requests" do
    assert {:error, :request_not_found} =
             Requests.append_request_event(Ecto.UUID.generate(), %{
               event_type: "request.received",
               state: :received
             })
  end

  test "mark_terminal/2 only accepts terminal states and stamps completion time" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_test"}
        })
      )

    assert {:error, changeset} = Requests.mark_terminal(request, %{state: :running})
    assert %{state: ["must be terminal"]} = errors_on(changeset)

    assert {:ok, terminal} =
             Requests.mark_terminal(request, %{
               state: :completed,
               output_tokens: 42,
               response_payload: %{"object" => "chat.completion"}
             })

    assert terminal.state == :completed
    assert terminal.output_tokens == 42
    assert terminal.completed_at != nil
  end

  test "mark_terminal/2 does not allow immutable request fields to change" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_immutable_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_immutable_test"}
        })
      )

    assert {:ok, terminal} =
             Requests.mark_terminal(request, %{
               state: :completed,
               public_id: "req_mutated_public_id",
               tenant_id: Ecto.UUID.generate()
             })

    assert terminal.public_id == "req_terminal_immutable_test"
    assert terminal.tenant_id == request.tenant_id
    assert terminal.state == :completed
  end

  test "mark_terminal/2 rejects stale terminal overwrites" do
    {:ok, model} = Models.create_model(model_attrs(%{state: :active}))

    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "req_terminal_stale_test",
          state: :running,
          model_id: model.id,
          canonical_request: %{"public_id" => "req_terminal_stale_test"}
        })
      )

    assert {:ok, terminal} = Requests.mark_terminal(request, %{state: :completed})
    assert terminal.state == :completed

    assert {:error, :already_terminal} =
             Requests.mark_terminal(request, %{state: :failed, error_code: "late_failure"})
  end

  test "active_states/0 returns non-terminal states in canonical order" do
    active = Request.active_states()
    assert active == Request.states() -- Request.terminal_states()
    assert :running in active
    assert :streaming in active
    refute :completed in active
    refute :failed in active
  end

  test "summary/0 returns zero-filled counts when DB is empty" do
    summary = Requests.summary()

    assert summary.total == 0
    assert summary.active == 0
    assert summary.terminal == 0

    for state <- Request.states() do
      assert Map.has_key?(summary.by_state, state), "missing state: #{state}"
      assert summary.by_state[state] == 0
    end
  end

  test "summary/0 returns grouped counts with active/terminal derivation" do
    create_request!(%{public_id: "r1", state: :received})
    create_request!(%{public_id: "r2", state: :running})
    create_request!(%{public_id: "r3", state: :running})
    create_request!(%{public_id: "r4", state: :completed})
    create_request!(%{public_id: "r5", state: :failed})

    summary = Requests.summary()

    assert summary.total == 5
    assert summary.active == 3
    assert summary.terminal == 2
    assert summary.by_state.received == 1
    assert summary.by_state.running == 2
    assert summary.by_state.completed == 1
    assert summary.by_state.failed == 1
    assert summary.by_state.streaming == 0
    assert summary.active + summary.terminal == summary.total
  end
end
