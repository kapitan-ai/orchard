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

  test "new/1 accepts valid terminal tool_execution indeterminate shapes" do
    attrs = %{
      "event_type" => "request_step.indeterminate",
      "step_id" => RequestStepEvent.tool_execution_step_id(2, "call_7", 3),
      "step_type" => "tool_execution",
      "turn_index" => 2,
      "attempt" => 3,
      "parent_step_id" => RequestStepEvent.tool_call_step_id(2, "call_7"),
      "boundary" => "post_observation",
      "result" => %{
        "error_code" => "tool_execution_indeterminate_controller_restarted",
        "error_message" => "Tool execution became indeterminate after the controller restarted",
        "indeterminate_reason" => "controller_restarted"
      },
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

  test "new/1 accepts tool_execution started rows only with pre_side_effect empty results" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.started",
        boundary: "pre_side_effect"
      })

    assert {:ok, step_event} = RequestStepEvent.new(attrs)
    assert step_event.result == %{}
  end

  test "new/1 rejects tool_execution started rows with non-empty result payloads" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.started",
        boundary: "pre_side_effect",
        result: %{"remote_execution_ref" => "exec_123"}
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "request_step.started result must be an empty map"
  end

  test "new/1 rejects tool_execution indeterminate rows without indeterminate_reason" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.indeterminate",
        result: %{
          "error_code" => "tool_execution_indeterminate",
          "error_message" => "Tool execution became indeterminate"
        }
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "indeterminate outcomes require indeterminate_reason"
  end

  test "new/1 rejects non-completed tool_execution rows missing durable error fields" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.failed",
        result: %{"error_code" => "tool_execution_failed"}
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "tool_execution result requires non-empty error_message"
  end

  test "new/1 rejects tool_execution rows with whitespace-only durable error fields" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.failed",
        result: %{
          "error_code" => "   ",
          "error_message" => "Tool execution failed"
        }
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "tool_execution result requires non-empty error_code"
  end

  test "new/1 rejects completed tool_execution rows that carry indeterminate_reason" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.completed",
        result: %{"indeterminate_reason" => "result_not_observed"}
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "only indeterminate outcomes may include indeterminate_reason"
  end

  test "new/1 rejects tool_execution result keys outside the contract" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.failed",
        result: %{
          "error_code" => "tool_execution_failed",
          "error_message" => "Tool execution failed",
          "unexpected_key" => "oops"
        }
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "contains unexpected keys"
    assert reason =~ "unexpected_key"
  end

  test "new/1 rejects tool_execution result fields with blank optional refs" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.completed",
        result: %{"remote_execution_ref" => "   "}
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "remote_execution_ref must be a non-empty string when present"
  end

  test "new/1 rejects unsupported tool_execution event types" do
    attrs =
      tool_execution_step_attrs(%{
        event_type: "request_step.proposed",
        result: %{"error_code" => "not_allowed"}
      })

    assert {:error, reason} = RequestStepEvent.new(attrs)
    assert reason =~ "tool_execution steps only support"
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

  test "from_request_event!/1 fails loudly for malformed persisted tool_execution payloads" do
    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 5,
      event_type: "request_step.indeterminate",
      state: nil,
      occurred_at: ~U[2026-04-12 08:30:00.000000Z],
      payload: %{
        "step_id" => RequestStepEvent.tool_execution_step_id(2, "call_7", 1),
        "step_type" => "tool_execution",
        "turn_index" => 2,
        "attempt" => 1,
        "parent_step_id" => RequestStepEvent.tool_call_step_id(2, "call_7"),
        "boundary" => "post_observation",
        "result" => %{
          "error_code" => "tool_execution_indeterminate_result_not_observed",
          "error_message" => "Tool execution result was not observed"
        },
        "call_id" => "call_7",
        "tool_name" => "lookup_weather",
        "arguments_json" => "{\"city\":\"Singapore\"}"
      }
    }

    assert_raise ArgumentError, ~r/indeterminate outcomes require indeterminate_reason/, fn ->
      RequestStepEvent.from_request_event!(request_event)
    end
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

  test "new/1 accepts only the supported inference-turn identities" do
    assert {:ok, _step_event} =
             RequestStepEvent.new(
               inference_turn_step_attrs(%{
                 event_type: "request_step.started",
                 boundary: "pre_side_effect",
                 result: %{}
               })
             )

    assert {:ok, _step_event} =
             RequestStepEvent.new(
               inference_turn_step_attrs(%{
                 event_type: "request_step.started",
                 step_id: RequestStepEvent.inference_turn_step_id(1, 2),
                 attempt: 2,
                 boundary: "pre_side_effect",
                 result: %{}
               })
             )

    for {turn_index, attempt} <- [{2, 1}, {1, 3}] do
      assert {:error, "only turn 1 attempts 1 and 2 are supported"} =
               RequestStepEvent.new(
                 inference_turn_step_attrs(%{
                   event_type: "request_step.started",
                   step_id: RequestStepEvent.inference_turn_step_id(turn_index, attempt),
                   turn_index: turn_index,
                   attempt: attempt,
                   boundary: "pre_side_effect",
                   result: %{}
                 })
               )
    end
  end

  test "enriched terminal attempts validate while sparse historical rows remain readable" do
    node_1 = "00000000-0000-4000-a000-000000000001"
    node_2 = "00000000-0000-4000-a000-000000000002"

    for {attempt, node_id, exclusions, decision} <- [
          {1, node_1, [], "retried"},
          {2, node_2, [node_1], "retry_exhausted"}
        ] do
      attrs =
        inference_terminal_attrs(attempt, %{
          "node_id" => node_id,
          "excluded_node_ids" => exclusions,
          "retry_decision" => decision
        })

      assert {:ok, step_event} = RequestStepEvent.new(attrs)
      assert step_event.result["excluded_node_ids"] == exclusions
    end

    assert {:ok, _step_event} =
             RequestStepEvent.new(%{
               event_type: "request_step.failed",
               step_id: RequestStepEvent.inference_turn_step_id(1, 1),
               step_type: "inference_turn",
               turn_index: 1,
               attempt: 1,
               boundary: "post_observation",
               result: %{"error_code" => "internal_error"}
             })

    assert {:error, _reason} =
             RequestStepEvent.new(%{
               event_type: "request_step.failed",
               step_id: RequestStepEvent.inference_turn_step_id(1, 1),
               step_type: "inference_turn",
               turn_index: 1,
               attempt: 1,
               boundary: "post_observation",
               result: %{"accepted" => false}
             })
  end

  test "SPEC.md §§3.7.1 and 5.3 reads next-format persisted attempt usage evidence" do
    attrs =
      inference_terminal_attrs(1, %{
        "excluded_node_ids" => [],
        "retry_decision" => "not_retryable",
        "output_tokens" => 7,
        "output_usage_status" => "lower_bound"
      })

    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 1,
      event_type: attrs.event_type,
      state: nil,
      occurred_at: ~U[2026-04-11 09:15:00.000000Z],
      payload: Map.drop(attrs, [:event_type])
    }

    assert {:ok, step_event} = RequestStepEvent.from_request_event(request_event)
    assert step_event.result["output_tokens"] == 7
    assert step_event.result["output_usage_status"] == "lower_bound"
  end

  test "from_request_event/1 preserves historical inference identities rejected for new writes" do
    request_event = %RequestEvent{
      request_id: Ecto.UUID.generate(),
      seq: 1,
      event_type: "request_step.failed",
      state: nil,
      occurred_at: ~U[2026-04-11 09:15:00.000000Z],
      payload: %{
        "step_id" => RequestStepEvent.inference_turn_step_id(2, 3),
        "step_type" => "inference_turn",
        "turn_index" => 2,
        "attempt" => 3,
        "parent_step_id" => nil,
        "boundary" => "post_observation",
        "result" => %{"error_code" => "internal_error"}
      }
    }

    assert {:ok, step_event} = RequestStepEvent.from_request_event(request_event)
    assert step_event.step_id == "inference_turn:t2:a3"
    assert step_event.attempt == 3
  end

  defp inference_terminal_attrs(attempt, overrides) do
    %{
      event_type: "request_step.failed",
      step_id: RequestStepEvent.inference_turn_step_id(1, attempt),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: attempt,
      boundary: "post_observation",
      result:
        Map.merge(
          %{
            "attempt_outcome" => "failed",
            "started_at" => ~U[2026-08-12 10:00:00.000000Z],
            "ended_at" => ~U[2026-08-12 10:00:01.000000Z],
            "accepted" => false,
            "output_committed" => false,
            "execution_resolution" => "not_started",
            "capacity_release_outcome" => "not_applicable",
            "failure_class" => "runtime_failure",
            "failure_code" => "runtime_unavailable"
          },
          overrides
        )
    }
  end

  defp tool_execution_step_attrs(overrides) do
    Map.merge(
      %{
        event_type: "request_step.completed",
        step_id: RequestStepEvent.tool_execution_step_id(2, "call_7", 1),
        step_type: "tool_execution",
        turn_index: 2,
        attempt: 1,
        parent_step_id: RequestStepEvent.tool_call_step_id(2, "call_7"),
        boundary: "post_observation",
        result: %{},
        call_id: "call_7",
        tool_name: "lookup_weather",
        arguments_json: "{\"city\":\"Singapore\"}"
      },
      overrides
    )
  end
end
