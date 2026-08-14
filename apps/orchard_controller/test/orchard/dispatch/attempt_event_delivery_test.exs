defmodule Orchard.Dispatch.AttemptEventDeliveryTest do
  use ExUnit.Case, async: true

  alias Orchard.Dispatch.AttemptEventDelivery
  alias Orchard.InferenceEvent

  test "SPEC 5.8 normalizes cancellation and handler failures with partial flush accounting" do
    accepted = InferenceEvent.accepted(1)
    committing = InferenceEvent.tool_call_delta("call-1", "{")
    terminal = InferenceEvent.completed(:finish_reason_tool_calls, nil)

    cases = [
      {:cancel, fn -> :cancel end},
      {:serializer_failed, fn -> {:error, :serializer_failed} end},
      {:event_handler_failed, fn -> :invalid_return end},
      {:event_handler_failed, fn -> raise "handler failed" end},
      {:event_handler_failed, fn -> throw(:handler_failed) end},
      {:event_handler_failed, fn -> exit(:handler_failed) end}
    ]

    for {expected_reason, fail} <- cases do
      handler = fn _request_id, event ->
        if event == accepted, do: :ok, else: fail.()
      end

      failed =
        AttemptEventDelivery.new("request-failure", handler)
        |> AttemptEventDelivery.record(accepted)
        |> AttemptEventDelivery.record(committing)
        |> AttemptEventDelivery.record(terminal)

      assert AttemptEventDelivery.output_committed?(failed)
      assert AttemptEventDelivery.commitment_kind(failed) == :tool_call
      assert AttemptEventDelivery.delivery_state(failed) == :failed
      assert AttemptEventDelivery.delivered_event_count(failed) == 1
      assert AttemptEventDelivery.failure_reason(failed) == expected_reason
      assert AttemptEventDelivery.events(failed) == [accepted, committing, terminal]
    end
  end

  test "SPEC 5.8 selects a final uncommitted attempt or discards it without delivery" do
    owner = self()

    handler = fn request_id, event ->
      send(owner, {:delivered, request_id, event})
      :ok
    end

    events = [InferenceEvent.accepted(1), InferenceEvent.output_text_delta("")]

    pending =
      Enum.reduce(events, AttemptEventDelivery.new("request-select", handler), fn event,
                                                                                  delivery ->
        AttemptEventDelivery.record(delivery, event)
      end)

    selected = AttemptEventDelivery.select(pending)
    assert AttemptEventDelivery.delivery_state(selected) == :selected
    assert AttemptEventDelivery.delivered_event_count(selected) == 2
    assert_receive {:delivered, "request-select", first}
    assert_receive {:delivered, "request-select", second}
    assert [first, second] == events

    pending_discard =
      AttemptEventDelivery.new("request-discard", handler)
      |> AttemptEventDelivery.record(InferenceEvent.progress("prefill", "working"))

    assert {:ok, discarded} = AttemptEventDelivery.discard(pending_discard)
    assert AttemptEventDelivery.delivery_state(discarded) == :discarded
    assert AttemptEventDelivery.delivered_event_count(discarded) == 0
    refute_received {:delivered, "request-discard", _}

    committed =
      AttemptEventDelivery.new("request-committed", handler)
      |> AttemptEventDelivery.record(InferenceEvent.output_text_delta("committed"))

    assert {:error, :output_committed} = AttemptEventDelivery.discard(committed)
    assert AttemptEventDelivery.select(committed) == committed
  end

  @tag timeout: 2_000
  test "selected delivery records a long stream without rescanning delivered history" do
    first = InferenceEvent.output_text_delta("first")
    next = InferenceEvent.output_text_delta("next")

    delivery =
      AttemptEventDelivery.new("request-long-stream", nil)
      |> AttemptEventDelivery.record(first)

    final =
      Enum.reduce(1..50_000, delivery, fn _index, state ->
        AttemptEventDelivery.record(state, next)
      end)

    assert AttemptEventDelivery.delivered_event_count(final) == 50_001
    assert length(AttemptEventDelivery.events(final)) == 50_001
    assert hd(AttemptEventDelivery.events(final)) == first
    assert List.last(AttemptEventDelivery.events(final)) == next
  end

  test "SPEC 5.8 buffers pre-commit events and flushes them before the committing event" do
    owner = self()

    handler = fn request_id, event ->
      send(owner, {:delivered, request_id, event})
      :ok
    end

    accepted = InferenceEvent.accepted(1)
    empty_text = InferenceEvent.output_text_delta("")
    committing_text = InferenceEvent.output_text_delta("hello")

    delivery =
      AttemptEventDelivery.new("request-1", handler)
      |> AttemptEventDelivery.record(accepted)
      |> AttemptEventDelivery.record(empty_text)

    assert AttemptEventDelivery.events(delivery) == [accepted, empty_text]
    refute AttemptEventDelivery.output_committed?(delivery)
    assert AttemptEventDelivery.delivery_state(delivery) == :pending
    refute_received {:delivered, _, _}

    committed = AttemptEventDelivery.record(delivery, committing_text)

    assert AttemptEventDelivery.events(committed) == [accepted, empty_text, committing_text]
    assert AttemptEventDelivery.output_committed?(committed)
    assert AttemptEventDelivery.commitment_kind(committed) == :text
    assert AttemptEventDelivery.delivery_state(committed) == :selected
    assert AttemptEventDelivery.delivered_event_count(committed) == 3

    assert_receive {:delivered, "request-1", ^accepted}
    assert_receive {:delivered, "request-1", ^empty_text}
    assert_receive {:delivered, "request-1", ^committing_text}
  end
end
