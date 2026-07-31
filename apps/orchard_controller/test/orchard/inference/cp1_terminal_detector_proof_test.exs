defmodule Orchard.Inference.CP1TerminalDetectorProofTest do
  use Orchard.DataCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures

  alias Orchard.InferenceEvent
  alias Orchard.Requests
  alias Orchard.Requests.RequestStepEvent
  alias Orchard.TestSupport.TerminalCardinality

  @control_categories [
    {:stop, :completed, "request_step.completed", "stop"},
    {:length, :completed, "request_step.completed", "length"},
    {:tool_calls, :completed, "request_step.completed", "tool_calls"},
    {:failure, :failed, "request_step.failed", nil},
    {:cancellation, :cancelled, "request_step.cancelled", nil},
    {:timeout, :timed_out, "request_step.timed_out", nil},
    {:interruption, :interrupted, "request_step.interrupted", nil}
  ]
  @samples_per_category 15
  @control_count length(@control_categories) * @samples_per_category

  test "issue #120 candidate detector has zero false positives across 105 durable controls" do
    controls =
      for category <- @control_categories,
          sample <- 1..@samples_per_category do
        persist_terminal_control(category, sample)
      end

    category_counts = Enum.frequencies_by(controls, & &1.category)

    assert @control_count == 105
    assert length(controls) == @control_count
    assert category_counts |> Map.values() |> Enum.uniq() == [@samples_per_category]
    assert category_counts |> Map.keys() |> Enum.sort() == expected_categories()

    assert controls |> Enum.map(& &1.durable_result) |> Enum.uniq() |> length() ==
             @control_count

    assert Enum.frequencies(Enum.map(controls, & &1.classification)) ==
             %{{:ok, :not_candidate} => @control_count}

    assert Enum.frequencies(Enum.map(controls, & &1.durable_terminal_steps)) ==
             %{1 => @control_count}

    assert Enum.frequencies(Enum.map(controls, & &1.source_cardinality)) ==
             %{exactly_one: @control_count}

    assert TerminalCardinality.classify([InferenceEvent.accepted(0)]) == :zero

    assert TerminalCardinality.classify([
             InferenceEvent.completed(:finish_reason_stop, nil),
             InferenceEvent.failed("runtime_failed", "failed", false)
           ]) == :multiple
  end

  defp persist_terminal_control(
         {category, request_state, event_type, finish_reason},
         sample
       ) do
    {:ok, request} =
      Requests.create_request(
        request_attrs(%{
          public_id: "cp1-terminal-#{category}-#{sample}",
          state: :running
        })
      )

    source_events = [
      InferenceEvent.accepted(0),
      terminal_event(category)
    ]

    step_result = terminal_step_result(category, finish_reason, sample)

    terminal_step = %{
      event_type: event_type,
      step_id: RequestStepEvent.inference_turn_step_id(1, 1),
      step_type: "inference_turn",
      turn_index: 1,
      attempt: 1,
      parent_step_id: nil,
      boundary: "post_observation",
      result: step_result
    }

    assert {:ok, _request} =
             Requests.mark_terminal_with_step_events(
               request,
               %{state: request_state},
               [terminal_step]
             )

    %{
      category: category,
      classification: Requests.classify_missing_terminal_candidate(request),
      durable_result: durable_terminal_result(request),
      durable_terminal_steps: durable_terminal_step_count(request),
      source_cardinality: TerminalCardinality.classify(source_events)
    }
  end

  defp terminal_step_result(category, nil, sample) do
    %{
      "error_code" => terminal_error_code(category),
      "error_message" => "#{category} control #{sample}",
      "http_status" => 400 + sample
    }
  end

  defp terminal_step_result(_category, finish_reason, sample) do
    %{
      "finish_reason" => finish_reason,
      "http_status" => 200,
      "input_tokens" => sample,
      "output_tokens" => sample * 2
    }
  end

  defp durable_terminal_steps(request) do
    terminal_event_types = RequestStepEvent.terminal_step_event_types()

    request
    |> Requests.list_request_step_events()
    |> Enum.filter(&(&1.step_type == "inference_turn" and &1.event_type in terminal_event_types))
  end

  defp durable_terminal_step_count(request), do: request |> durable_terminal_steps() |> length()

  defp durable_terminal_result(request) do
    request |> durable_terminal_steps() |> Enum.map(& &1.result)
  end

  defp terminal_event(:stop),
    do: InferenceEvent.completed(:finish_reason_stop, nil)

  defp terminal_event(:length),
    do: InferenceEvent.completed(:finish_reason_length, nil)

  defp terminal_event(:tool_calls),
    do: InferenceEvent.completed(:finish_reason_tool_calls, nil)

  defp terminal_event(category) do
    InferenceEvent.failed(terminal_error_code(category), "#{category} control", false)
  end

  defp terminal_error_code(:failure), do: "runtime_failed"
  defp terminal_error_code(:cancellation), do: "request_cancelled"
  defp terminal_error_code(:timeout), do: "deadline_exceeded"
  defp terminal_error_code(:interruption), do: "request_client_disconnect"

  defp expected_categories do
    @control_categories
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
