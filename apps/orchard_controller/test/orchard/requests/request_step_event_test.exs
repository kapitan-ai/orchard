defmodule Orchard.Requests.RequestStepEventTest do
  use ExUnit.Case, async: true

  alias Orchard.Requests.{RequestEvent, RequestStepEvent}

  test "new/1 accepts atom-keyed completed inference-turn step attrs and normalizes payload maps" do
    occurred_at = ~U[2026-04-11 09:15:00.000000Z]

    attrs = %{
      event_type: "request_step.completed",
      occurred_at: occurred_at,
      step_id: RequestStepEvent.inference_turn_step_id(1, 1),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: 1,
      parent_step_id: nil,
      boundary: "post_observation",
      result: %{finish_reason: "stop", output_tokens: 12},
      model_id: "mlx-community/phi-3",
      model_version: "main"
    }

    assert {:ok, step_event} = RequestStepEvent.new(attrs)
    assert step_event.event_type == "request_step.completed"
    assert step_event.step_id == "inference_turn:t1:a1"
    assert step_event.result == %{"finish_reason" => "stop", "output_tokens" => 12}
    assert step_event.occurred_at == occurred_at

    assert {:ok, request_event_attrs} = RequestStepEvent.to_request_event_attrs(step_event)

    assert request_event_attrs["state"] == nil
    assert request_event_attrs["occurred_at"] == occurred_at

    assert request_event_attrs["payload"] == %{
             "step_id" => "inference_turn:t1:a1",
             "step_type" => "inference_turn",
             "turn_index" => 1,
             "attempt" => 1,
             "parent_step_id" => nil,
             "boundary" => "post_observation",
             "result" => %{"finish_reason" => "stop", "output_tokens" => 12},
             "model_id" => "mlx-community/phi-3",
             "model_version" => "main"
           }
  end

  test "new/1 accepts string-keyed reserved tool_execution indeterminate shapes" do
    attrs = %{
      "event_type" => "request_step.indeterminate",
      "step_id" => RequestStepEvent.tool_execution_step_id(2, "call_7", 3),
      "step_type" => "tool_execution",
      "turn_index" => 2,
      "attempt" => 3,
      "parent_step_id" => RequestStepEvent.tool_call_step_id(2, "call_7"),
      "boundary" => "post_observation",
      "result" => %{"indeterminate_reason" => "controller_restart"},
      "call_id" => "call_7",
      "tool_name" => "lookup_weather",
      "arguments_json" => "{\"city\":\"Singapore\"}"
    }

    assert {:ok, step_event} = RequestStepEvent.new(attrs)
    assert step_event.step_type == "tool_execution"
    assert step_event.event_type == "request_step.indeterminate"
    assert step_event.call_id == "call_7"
    assert step_event.parent_step_id == "tool_call:t2:ccall_7"
  end

  test "new/1 accepts valid RequestStepEvent structs and revalidates malformed ones" do
    valid_struct =
      inference_turn_step_attrs(%{})
      |> RequestStepEvent.new!()

    assert {:ok, normalized_struct} = RequestStepEvent.new(valid_struct)
    assert normalized_struct == valid_struct

    malformed_struct = %{valid_struct | call_id: "call_bad"}

    assert {:error, reason} = RequestStepEvent.new(malformed_struct)
    assert reason =~ "must not include call_id"
  end

  test "new/1 rejects request_step events that carry non-nil state" do
    attrs =
      inference_turn_step_attrs(%{
        event_type: "request_step.started",
        boundary: "pre_side_effect",
        result: %{},
        state: :running
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "state: nil"
  end

  test "new/1 returns {:error, reason} for malformed inference_turn attrs with call_id" do
    attrs = inference_turn_step_attrs(%{call_id: "call_bad"})

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "must not include call_id"
  end

  test "new!/1 raises ArgumentError for malformed inference_turn attrs with call_id" do
    assert_raise ArgumentError, ~r/must not include call_id/, fn ->
      inference_turn_step_attrs(%{call_id: "call_bad"})
      |> RequestStepEvent.new!()
    end
  end

  test "new!/1 fails loudly for malformed deterministic ids" do
    assert_raise ArgumentError, ~r/step_id must equal/, fn ->
      inference_turn_step_attrs(%{step_id: "inference_turn:t9:a9"})
      |> RequestStepEvent.new!()
    end
  end

  test "from_request_event/1 parses persisted request_step rows into typed structs" do
    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 4,
      event_type: "request_step.proposed",
      state: nil,
      occurred_at: ~U[2026-04-11 10:00:00.000000Z],
      payload: %{
        "step_id" => RequestStepEvent.tool_call_step_id(1, "call_3"),
        "step_type" => "tool_call",
        "turn_index" => 1,
        "attempt" => 1,
        "parent_step_id" => RequestStepEvent.inference_turn_step_id(1, 1),
        "boundary" => "post_observation",
        "result" => %{"finish_reason" => "tool_calls"},
        "call_id" => "call_3",
        "tool_name" => "lookup_weather",
        "arguments_json" => "{\"city\":\"Singapore\"}"
      }
    }

    assert {:ok, step_event} = RequestStepEvent.from_request_event(request_event)
    assert step_event.seq == 4
    assert step_event.request_id == request_event.request_id
    assert step_event.step_id == "tool_call:t1:ccall_3"
    assert step_event.result == %{"finish_reason" => "tool_calls"}
  end

  test "from_request_event/1 returns {:error, reason} for malformed persisted inference_turn payloads with call_id" do
    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 2,
      event_type: "request_step.completed",
      state: nil,
      occurred_at: ~U[2026-04-11 10:15:00.000000Z],
      payload: %{
        "step_id" => RequestStepEvent.inference_turn_step_id(1, 1),
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => 1,
        "parent_step_id" => nil,
        "boundary" => "post_observation",
        "result" => %{},
        "call_id" => "call_bad"
      }
    }

    assert {:error, reason} = RequestStepEvent.from_request_event(request_event)
    assert reason =~ "must not include call_id"
  end

  test "from_request_event!/1 fails loudly for malformed persisted step payloads" do
    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 2,
      event_type: "request_step.completed",
      state: :completed,
      occurred_at: ~U[2026-04-11 10:15:00.000000Z],
      payload: %{
        "step_id" => RequestStepEvent.inference_turn_step_id(1, 1),
        "step_type" => "inference_turn",
        "turn_index" => 1,
        "attempt" => 1,
        "parent_step_id" => nil,
        "boundary" => "post_observation",
        "result" => %{}
      }
    }

    assert_raise ArgumentError, ~r/state: nil/, fn ->
      RequestStepEvent.from_request_event!(request_event)
    end
  end

  defp inference_turn_step_attrs(overrides) do
    Map.merge(
      %{
        event_type: "request_step.completed",
        step_id: RequestStepEvent.inference_turn_step_id(1, 1),
        step_type: "inference_turn",
        turn_index: 1,
        attempt: 1,
        parent_step_id: nil,
        boundary: "post_observation",
        result: %{}
      },
      overrides
    )
  end
end
