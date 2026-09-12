defmodule OrchardConsole.RequestEvidence do
  @moduledoc """
  Read-only Request timeline projections from persisted step evidence.
  """

  alias Orchard.Requests.RequestStepEvent
  alias OrchardConsole.TimeHelpers

  @type attempt :: %{
          step_id: String.t(),
          number: pos_integer(),
          turn: pos_integer(),
          outcome: String.t(),
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          result: map()
        }

  @doc "Groups validated Inference Turn events without inferring attempts from Request state."
  @spec attempts([struct()]) :: [attempt()]
  def attempts(events) do
    events
    |> Enum.flat_map(fn event ->
      case RequestStepEvent.from_request_event(event) do
        {:ok, %{step_type: "inference_turn"} = step} -> [step]
        _ -> []
      end
    end)
    |> Enum.group_by(& &1.step_id)
    |> Enum.map(fn {id, steps} -> project_attempt(id, steps) end)
    |> Enum.sort_by(&{&1.turn, &1.number})
  end

  defp project_attempt(id, steps) do
    first = Enum.min_by(steps, & &1.seq)
    starts = Enum.filter(steps, &(&1.event_type == "request_step.started"))

    terminals =
      Enum.filter(steps, &(&1.event_type in RequestStepEvent.terminal_step_event_types()))

    terminal = if length(terminals) == 1, do: hd(terminals)
    result = if terminal, do: terminal.result, else: %{}

    %{
      step_id: id,
      number: first.attempt,
      turn: first.turn_index,
      outcome: attempt_outcome(terminal, terminals),
      started_at: timestamp(result["started_at"]) || started_at(starts),
      ended_at: timestamp(result["ended_at"]),
      result: result
    }
  end

  defp attempt_outcome(nil, []), do: "Terminal outcome not recorded"
  defp attempt_outcome(nil, _), do: "Conflicting terminal evidence"
  defp attempt_outcome(%{result: %{"result_invalid" => _}}, _), do: "Invalid terminal evidence"

  defp attempt_outcome(terminal, _),
    do: String.replace_prefix(terminal.event_type, "request_step.", "")

  defp started_at([step]), do: step.occurred_at
  defp started_at(_), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} -> date
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  @doc "Measures public-output latency from creation, rejecting timestamps after completion."
  @spec ttft_ms(map()) :: non_neg_integer() | nil
  def ttft_ms(request) do
    if request.completed_at &&
         is_nil(TimeHelpers.elapsed_ms(request.first_token_at, request.completed_at)) do
      nil
    else
      TimeHelpers.elapsed_ms(request.inserted_at, request.first_token_at)
    end
  end

  @doc "Returns percentages only for a fully bounded interval on the Request scale."
  @spec bar(DateTime.t() | nil, DateTime.t() | nil, DateTime.t() | nil, DateTime.t() | nil) ::
          %{left: float(), width: float()} | nil
  def bar(created_at, completed_at, started_at, ended_at) do
    total = TimeHelpers.elapsed_ms(created_at, completed_at)
    offset = TimeHelpers.elapsed_ms(created_at, started_at)
    duration = TimeHelpers.elapsed_ms(started_at, ended_at)
    remaining = TimeHelpers.elapsed_ms(ended_at, completed_at)

    if is_integer(total) and total > 0 and is_integer(offset) and is_integer(duration) and
         is_integer(remaining) do
      %{left: offset / total * 100, width: duration / total * 100}
    end
  end

  @doc "Formats measured milliseconds without conflating missing and zero."
  @spec duration(non_neg_integer() | nil) :: String.t()
  def duration(nil), do: "Not recorded"
  def duration(ms) when ms < 1000, do: "#{ms} ms"
  def duration(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 2) <> " s"
end
