defmodule Orchard.Metrics.InferenceAttemptProjection do
  @moduledoc """
  Projects bounded inference-attempt metrics from durable Request step evidence.
  """

  alias Orchard.Requests.{InferenceAttemptResult, RequestStepEvent}

  @decline_decisions InferenceAttemptResult.attempt_one_retry_decisions() -- ["retried"]

  @type attempt_observation :: %{
          attempt: 1 | 2,
          outcome: String.t(),
          failure_class: String.t(),
          duration_seconds: float()
        }
  @type retry_observation :: %{reason: String.t(), result: String.t()}
  @type projection :: %{attempts: [attempt_observation()], retry: retry_observation() | nil}
  @type projection_result :: {:ok, projection()} | {:error, :invalid_attempt_evidence}

  @spec project([RequestStepEvent.t()]) :: projection_result()
  def project(events) when is_list(events) do
    case observation(events, 1) do
      :absent -> project_without_attempt_one(events)
      {:ok, attempt_one} -> project_with_attempt_one(events, attempt_one)
      {:error, :invalid_attempt_evidence} = error -> error
    end
  end

  def project(_events), do: {:error, :invalid_attempt_evidence}

  defp observation(events, attempt) do
    step_id = RequestStepEvent.inference_turn_step_id(1, attempt)
    started_events = matching_events(events, step_id, "request_step.started")
    terminal_events = matching_terminal_events(events, step_id)

    case {started_events, terminal_events} do
      {[], []} ->
        :absent

      {[%RequestStepEvent{} = started], [%RequestStepEvent{} = terminal]} ->
        build_observation(started, terminal, attempt)

      _invalid_or_ambiguous ->
        {:error, :invalid_attempt_evidence}
    end
  end

  defp build_observation(started, terminal, attempt) do
    with true <- valid_order?(started, terminal),
         {:ok, result} <-
           InferenceAttemptResult.from_persisted(terminal.event_type, attempt, terminal.result),
         {:ok, duration_seconds} <- duration_seconds(result) do
      {:ok,
       %{
         attempt: attempt,
         outcome: result["attempt_outcome"],
         failure_class: Map.get(result, "failure_class", "none"),
         duration_seconds: duration_seconds,
         retry_decision: Map.get(result, "retry_decision"),
         started_seq: started.seq,
         terminal_seq: terminal.seq
       }}
    else
      _invalid_or_ambiguous -> {:error, :invalid_attempt_evidence}
    end
  end

  defp matching_events(events, step_id, event_type) do
    Enum.filter(events, &matching_event?(&1, step_id, event_type))
  end

  defp matching_terminal_events(events, step_id) do
    terminal_types = RequestStepEvent.terminal_step_event_types()
    Enum.filter(events, &matching_event?(&1, step_id, terminal_types))
  end

  defp matching_event?(%RequestStepEvent{} = event, step_id, event_types) do
    event.step_id == step_id and event.step_type == "inference_turn" and event.turn_index == 1 and
      event.attempt in [1, 2] and event.event_type in List.wrap(event_types)
  end

  defp matching_event?(_event, _step_id, _event_types), do: false

  defp valid_order?(%{seq: started_seq}, %{seq: terminal_seq}) do
    is_integer(started_seq) and is_integer(terminal_seq) and started_seq < terminal_seq
  end

  defp duration_seconds(result) do
    with {:ok, started_at, 0} <- DateTime.from_iso8601(result["started_at"]),
         {:ok, ended_at, 0} <- DateTime.from_iso8601(result["ended_at"]) do
      {:ok, DateTime.diff(ended_at, started_at, :microsecond) / 1_000_000}
    end
  end

  defp project_without_attempt_one(events) do
    case observation(events, 2) do
      :absent -> {:ok, %{attempts: [], retry: nil}}
      _attempt_two_evidence -> {:error, :invalid_attempt_evidence}
    end
  end

  defp project_with_attempt_one(events, %{retry_decision: "retried"} = attempt_one) do
    case observation(events, 2) do
      {:ok, %{started_seq: started_seq} = attempt_two}
      when attempt_one.terminal_seq < started_seq ->
        {:ok, projection(attempt_one, attempt_two)}

      _missing_invalid_or_reordered ->
        {:error, :invalid_attempt_evidence}
    end
  end

  defp project_with_attempt_one(events, attempt_one) do
    case observation(events, 2) do
      :absent -> {:ok, projection(attempt_one, nil)}
      _unexpected_attempt_two -> {:error, :invalid_attempt_evidence}
    end
  end

  defp projection(attempt_one, attempt_two) do
    %{
      attempts:
        Enum.map(Enum.reject([attempt_one, attempt_two], &is_nil/1), &public_observation/1),
      retry: retry_metric(attempt_one, attempt_two)
    }
  end

  defp retry_metric(%{retry_decision: "retried"}, %{outcome: "completed"}),
    do: %{reason: "retried", result: "succeeded"}

  defp retry_metric(%{retry_decision: "retried"}, %{outcome: _outcome}),
    do: %{reason: "retried", result: "failed"}

  defp retry_metric(%{retry_decision: decision}, nil) when decision in @decline_decisions,
    do: %{reason: decision, result: "declined"}

  defp retry_metric(_attempt_one, _attempt_two), do: nil

  defp public_observation(observation) do
    Map.take(observation, [:attempt, :outcome, :failure_class, :duration_seconds])
  end
end
