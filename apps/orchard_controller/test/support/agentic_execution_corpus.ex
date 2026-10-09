defmodule Orchard.TestSupport.AgenticExecutionCorpus do
  @moduledoc false

  @fixture Path.expand("../fixtures/agentic_execution/v1.json", __DIR__)

  @spec load!() :: map()
  def load! do
    %{"version" => 1} = corpus = @fixture |> File.read!() |> Jason.decode!()
    corpus
  end

  @spec observe(binary(), String.t()) :: map()
  def observe(body, "chat_sync") do
    decoded = Jason.decode!(body)
    [choice] = decoded["choices"]

    %{
      text: choice["message"]["content"] || "",
      calls: choice["message"]["tool_calls"] || [],
      usage: chat_usage(decoded["usage"]),
      finish_reasons: [choice["finish_reason"]],
      public_terminals: 1
    }
  end

  def observe(body, "chat_stream") do
    events = sse(body)
    chunks = Enum.reject(events, &(&1 == :done))

    %{
      text: Enum.map_join(chunks, &get_in(&1, ["choices", Access.at(0), "delta", "content"])),
      calls: chat_calls(chunks),
      usage: chunks |> Enum.find_value(& &1["usage"]) |> chat_usage(),
      finish_reasons:
        Enum.flat_map(chunks, fn chunk ->
          case get_in(chunk, ["choices", Access.at(0), "finish_reason"]) do
            nil -> []
            reason -> [reason]
          end
        end),
      public_terminals: Enum.count(events, &(&1 == :done)),
      terminal_last: List.last(events) == :done
    }
  end

  def observe(body, "responses_sync"), do: body |> Jason.decode!() |> response_observation()

  def observe(body, "responses_stream") do
    events = sse(body)
    terminals = Enum.filter(events, &(&1["type"] in ["response.completed", "response.failed"]))
    response = List.last(terminals)["response"]

    response
    |> response_observation()
    |> Map.merge(%{
      streamed_text:
        events
        |> Enum.filter(&(&1["type"] == "response.output_text.delta"))
        |> Enum.map_join(& &1["delta"]),
      public_terminals: length(terminals),
      terminal_types: Enum.map(terminals, & &1["type"]),
      terminal_last: List.last(events) == List.last(terminals)
    })
  end

  @spec compare(map(), map()) :: [map()]
  def compare(observed, expected) do
    checks = [
      {"typed_text", observed.text, expected["text"]},
      {"typed_calls", observed.calls, expected["calls"]},
      {"public_usage", observed.usage, expected["usage"]},
      {"public_terminal_cardinality", observed.public_terminals, 1},
      {"no_post_terminal_events", Map.get(observed, :terminal_last, true), true}
    ]

    checks =
      if Map.has_key?(observed, :finish_reasons) do
        checks ++ [{"finish_reasons", observed.finish_reasons, [expected["finish_reason"]]}]
      else
        checks ++
          [
            {"response_status", observed.response_status, "completed"},
            {"response_terminal_types",
             Map.get(observed, :terminal_types, ["response.completed"]), ["response.completed"]},
            {"streamed_text", Map.get(observed, :streamed_text, observed.text), expected["text"]},
            {"content_part_types", observed.content_types,
             if(expected["text"] == "", do: [], else: ["output_text"])}
          ]
      end

    checks =
      if Map.has_key?(expected, "object") do
        checks ++ [{"structured_object", Jason.decode(observed.text), {:ok, expected["object"]}}]
      else
        checks
      end

    check(checks)
  end

  @spec check([{String.t(), term(), term()}]) :: [map()]
  def check(checks) do
    Enum.map(checks, fn {id, actual, expected_value} ->
      result = %{assertion: id, status: if(actual == expected_value, do: "pass", else: "fail")}

      if id in [
           "retry_decision",
           "logical_output_count",
           "logical_usage_status",
           "attempt_output_count",
           "attempt_usage_status",
           "quarantine_before_native_drain",
           "no_allocation_reuse_before_native_drain",
           "node_occupancy_before_native_drain",
           "quarantine_persists_after_native_drain"
         ] do
        Map.merge(result, %{actual: actual, expected: expected_value})
      else
        result
      end
    end)
  end

  @spec sse(binary()) :: [map() | :done]
  def sse(body) do
    for "data: " <> data <- String.split(body, "\n"),
        do: if(data == "[DONE]", do: :done, else: Jason.decode!(data))
  end

  @spec stream_checks(binary(), String.t(), map()) :: [map()]
  def stream_checks(body, "responses_stream", expected) do
    events = sse(body)
    public_id = hd(events)["response"]["id"]
    text_deltas = expected["text_deltas"] || []
    calls = expected["calls"]

    text_types =
      if text_deltas == [],
        do: [],
        else:
          ["response.output_item.added"] ++
            List.duplicate("response.output_text.delta", length(text_deltas)) ++
            ["response.output_text.done", "response.output_item.done"]

    call_types =
      Enum.flat_map(calls, fn _ ->
        [
          "response.output_item.added",
          "response.function_call_arguments.delta",
          "response.function_call_arguments.done",
          "response.output_item.done"
        ]
      end)

    message_id = "msg_" <> public_id
    item_events = Enum.filter(events, &is_map(&1["item"]))
    added = Enum.filter(item_events, &(&1["type"] == "response.output_item.added"))
    done = Enum.filter(item_events, &(&1["type"] == "response.output_item.done"))

    expected_items =
      if(text_deltas == [], do: [], else: [message_id]) ++ Enum.map(calls, & &1["id"])

    arguments = Enum.filter(events, &(&1["type"] == "response.function_call_arguments.delta"))
    argument_done = Enum.filter(events, &(&1["type"] == "response.function_call_arguments.done"))

    text_events =
      Enum.filter(
        events,
        &(&1["type"] in ["response.output_text.delta", "response.output_text.done"])
      )

    offset = if text_deltas == [], do: 0, else: 1

    expected_arguments =
      Enum.with_index(calls, offset)
      |> Enum.map(fn {call, index} ->
        [call["id"], index, call["function"]["arguments"]]
      end)

    check([
      {"created_response_state", hd(events)["response"]["status"], "in_progress"},
      {"terminal_response_identity", List.last(events)["response"]["id"], public_id},
      {"added_item_contents", Enum.map(added, & &1["item"]),
       expected_response_items(public_id, expected, :added)},
      {"done_item_contents", Enum.map(done, & &1["item"]),
       expected_response_items(public_id, expected, :done)},
      {"terminal_item_contents", List.last(events)["response"]["output"],
       expected_response_items(public_id, expected, :done)},
      {"stream_event_order", Enum.map(events, & &1["type"]),
       ["response.created"] ++ text_types ++ call_types ++ ["response.completed"]},
      {"stream_sequence", Enum.map(events, & &1["sequence_number"]),
       Enum.to_list(0..(length(events) - 1))},
      {"text_delta_boundaries",
       Enum.filter(events, &(&1["type"] == "response.output_text.delta"))
       |> Enum.map(& &1["delta"]), text_deltas},
      {"text_identity",
       Enum.map(
         text_events,
         &[&1["response_id"], &1["item_id"], &1["output_index"], &1["content_index"]]
       ), List.duplicate([public_id, message_id, 0, 0], length(text_events))},
      {"item_identity_added", Enum.map(added, & &1["item"]["id"]), expected_items},
      {"item_identity_done", Enum.map(done, & &1["item"]["id"]), expected_items},
      {"item_index", Enum.map(added, & &1["output_index"]),
       Enum.with_index(expected_items) |> Enum.map(&elem(&1, 1))},
      {"argument_delta_identity",
       Enum.map(arguments, &[&1["item_id"], &1["output_index"], &1["delta"]]),
       expected_arguments},
      {"argument_done_identity",
       Enum.map(argument_done, &[&1["item_id"], &1["output_index"], &1["arguments"]]),
       expected_arguments}
    ])
  end

  def stream_checks(body, "chat_stream", expected) do
    chunks = sse(body) |> Enum.reject(&(&1 == :done))
    deltas = Enum.flat_map(chunks, fn chunk -> Enum.map(chunk["choices"], & &1["delta"]) end)
    calls = Enum.flat_map(deltas, &(&1["tool_calls"] || []))

    check([
      {"stream_chunk_identity", Enum.map(chunks, & &1["id"]) |> Enum.uniq() |> length(), 1},
      {"stream_choice_identity",
       Enum.flat_map(chunks, &Enum.map(&1["choices"], fn choice -> choice["index"] end))
       |> Enum.uniq(), [0]},
      {"text_delta_boundaries",
       Enum.flat_map(deltas, fn delta ->
         if is_binary(delta["content"]) and delta["content"] != "",
           do: [delta["content"]],
           else: []
       end), expected["text_deltas"] || []},
      {"incremental_call_identity_order", calls, expected["chat_call_deltas"] || []}
    ])
  end

  def stream_checks(_body, _mode, _expected), do: []

  @spec failure_stream_checks(binary(), String.t(), map(), String.t()) :: [map()]
  def failure_stream_checks(body, "responses_stream", expected, public_id) do
    events = sse(body)
    deltas = Map.fetch!(expected, "text_deltas")
    text_events = Enum.filter(events, &(&1["type"] == "response.output_text.delta"))
    text_done = Enum.filter(events, &(&1["type"] == "response.output_text.done"))

    middle =
      if deltas == [],
        do: [],
        else:
          ["response.output_item.added"] ++
            List.duplicate("response.output_text.delta", length(deltas)) ++
            ["response.output_text.done"]

    check([
      {"failure_event_order", Enum.map(events, & &1["type"]),
       ["response.created"] ++ middle ++ ["response.failed"]},
      {"failure_sequence", Enum.map(events, & &1["sequence_number"]),
       Enum.to_list(0..(length(events) - 1))},
      {"failure_response_identity",
       [hd(events)["response"]["id"], List.last(events)["response"]["id"]],
       [public_id, public_id]},
      {"failure_delta_contents", Enum.map(text_events, & &1["delta"]), deltas},
      {"failure_text_identity",
       Enum.map(
         text_events ++ text_done,
         &[&1["response_id"], &1["item_id"], &1["output_index"], &1["content_index"]]
       ),
       List.duplicate([public_id, "msg_" <> public_id, 0, 0], length(deltas) + length(text_done))},
      {"failure_text_done", Enum.map(text_done, & &1["text"]),
       if(deltas == [], do: [], else: [Enum.join(deltas)])},
      {"failure_terminal_text", List.last(events)["response"]["output_text"], Enum.join(deltas)}
    ])
  end

  def failure_stream_checks(body, "chat_stream", expected, public_id) do
    events = sse(body)
    chunks = Enum.reject(events, &is_map_key(&1, "error"))
    deltas = Map.fetch!(expected, "text_deltas")
    choices = Enum.flat_map(chunks, & &1["choices"])

    expected_choices =
      if deltas == [],
        do: [],
        else:
          [
            %{
              "index" => 0,
              "delta" => %{"role" => "assistant", "content" => ""},
              "finish_reason" => nil
            }
          ] ++
            Enum.map(
              deltas,
              &%{"index" => 0, "delta" => %{"content" => &1}, "finish_reason" => nil}
            )

    check([
      {"failure_chunk_identity", Enum.map(chunks, & &1["id"]),
       List.duplicate(public_id, length(expected_choices))},
      {"failure_choice_trace", choices, expected_choices},
      {"failure_terminal_last", Map.has_key?(List.last(events), "error"), true},
      {"failure_one_terminal", length(events) - length(chunks), 1}
    ])
  end

  def failure_stream_checks(_body, _mode, _expected, _public_id), do: []

  @spec stream_controls(binary(), String.t(), map()) :: [map()]
  def stream_controls(body, "responses_stream" = mode, expected) do
    events = sse(body)

    mutations = [
      {"sequence", Enum.map(events, &Map.put(&1, "sequence_number", 0))},
      {"order", [hd(events), List.last(events) | tl(events)]},
      {"terminal_identity",
       List.update_at(events, -1, &put_in(&1, ["response", "id"], "wrong-response"))},
      {"item_content",
       List.update_at(
         events,
         -1,
         &put_in(&1, ["response", "output"], [%{"type" => "unexpected-item"}])
       )}
    ]

    mutations =
      if Enum.any?(events, &Map.has_key?(&1, "item_id")) do
        mutations ++
          [
            {"correlation",
             Enum.map(events, fn event ->
               if Map.has_key?(event, "item_id"),
                 do: Map.put(event, "item_id", "wrong-item"),
                 else: event
             end)}
          ]
      else
        mutations
      end

    Enum.flat_map(mutations, fn {name, mutated} ->
      wire = Enum.map_join(mutated, &("data: " <> Jason.encode!(&1) <> "\n\n"))

      check([
        {"negative_control/" <> name,
         Enum.any?(stream_checks(wire, mode, expected), &(&1.status == "fail")), true}
      ])
    end)
  end

  def stream_controls(_body, _mode, _expected), do: []

  defp expected_response_items(public_id, expected, phase) do
    status = if phase == :added, do: "in_progress", else: "completed"

    messages =
      if expected["text"] == "" do
        []
      else
        [
          %{
            "id" => "msg_" <> public_id,
            "type" => "message",
            "role" => "assistant",
            "status" => status,
            "content" =>
              if(phase == :added,
                do: [],
                else: [
                  %{"type" => "output_text", "text" => expected["text"], "annotations" => []}
                ]
              )
          }
        ]
      end

    messages ++
      Enum.map(expected["calls"], fn call ->
        %{
          "id" => call["id"],
          "call_id" => call["id"],
          "type" => "function_call",
          "name" => call["function"]["name"],
          "arguments" => if(phase == :added, do: "", else: call["function"]["arguments"]),
          "status" => status
        }
      end)
  end

  defp response_observation(response) do
    output = response["output"]

    %{
      response_status: response["status"],
      content_types:
        output
        |> Enum.filter(&(&1["type"] == "message"))
        |> Enum.flat_map(& &1["content"])
        |> Enum.map(& &1["type"]),
      text:
        output
        |> Enum.filter(&(&1["type"] == "message"))
        |> Enum.flat_map(& &1["content"])
        |> Enum.map_join(& &1["text"]),
      calls:
        output
        |> Enum.filter(&(&1["type"] == "function_call"))
        |> Enum.map(fn call ->
          %{
            "id" => call["call_id"],
            "type" => "function",
            "function" => %{"name" => call["name"], "arguments" => call["arguments"]}
          }
        end),
      usage: response_usage(response["usage"]),
      public_terminals: 1
    }
  end

  defp chat_calls(chunks) do
    chunks
    |> Enum.flat_map(fn chunk ->
      get_in(chunk, ["choices", Access.at(0), "delta", "tool_calls"]) || []
    end)
    |> Enum.group_by(& &1["index"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_index, calls} ->
      %{
        "id" => Enum.find_value(calls, & &1["id"]),
        "type" => "function",
        "function" => %{
          "name" => Enum.find_value(calls, &get_in(&1, ["function", "name"])),
          "arguments" => Enum.map_join(calls, &get_in(&1, ["function", "arguments"]))
        }
      }
    end)
  end

  defp chat_usage(nil), do: nil

  defp chat_usage(usage),
    do: [usage["prompt_tokens"], usage["completion_tokens"], usage["total_tokens"]]

  defp response_usage(nil), do: nil

  defp response_usage(usage),
    do: [usage["input_tokens"], usage["output_tokens"], usage["total_tokens"]]
end
