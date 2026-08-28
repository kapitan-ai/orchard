defmodule Orchard.Requests.InferenceAttemptResult do
  @moduledoc """
  Strict JSON-safe persistence contract for terminal inference attempt evidence.
  """

  alias Orchard.Requests.InferenceAttemptFailure

  @required_fields ~w(
    attempt_outcome started_at ended_at accepted output_committed execution_resolution
    capacity_release_outcome excluded_node_ids
  )
  @optional_fields ~w(
    output_commitment_kind node_id target_ref failure_class failure_code runtime_retryable
    retry_decision raw_source_code finish_reason input_tokens output_tokens http_status error_message
  )
  @fields @required_fields ++ @optional_fields
  @marker_fields MapSet.new(@required_fields ++ ~w(
    output_commitment_kind node_id target_ref failure_class failure_code runtime_retryable
    retry_decision raw_source_code
  ))

  @attempt_outcomes ~w(completed failed cancelled timed_out interrupted)
  @commitment_kinds ~w(text tool_call structured_output)
  @execution_resolutions ~w(not_started terminated unresolved)
  @capacity_release_outcomes ~w(released already_released not_applicable unresolved)
  @retry_decisions ~w(
    retried not_retryable output_committed cancelled budget_exhausted identity_unresolved
    occupancy_unresolved no_alternative_node retry_exhausted
  )
  @attempt_one_decisions @retry_decisions -- ["retry_exhausted"]
  @attempt_two_decisions ~w(retry_exhausted cancelled)
  @finish_reasons ~w(cancelled content_filter error length stop tool_calls)
  @maximum_integer 2_147_483_647
  @event_outcomes %{
    "request_step.completed" => "completed",
    "request_step.failed" => "failed",
    "request_step.cancelled" => "cancelled",
    "request_step.timed_out" => "timed_out",
    "request_step.interrupted" => "interrupted"
  }

  @type t :: map()

  @spec enriched?(map()) :: boolean()
  def enriched?(result) when is_map(result),
    do: Enum.any?(Map.keys(result), &marker_field?/1)

  def enriched?(_result), do: false

  defp marker_field?(key) when is_atom(key),
    do: MapSet.member?(@marker_fields, Atom.to_string(key))

  defp marker_field?(key) when is_binary(key), do: MapSet.member?(@marker_fields, key)
  defp marker_field?(_key), do: false

  @spec fields() :: [String.t()]
  def fields, do: @fields

  @spec new(String.t(), 1 | 2, map()) :: {:ok, t()} | {:error, String.t()}
  def new(event_type, attempt, result) when is_map(result) do
    with :ok <- validate_attempt(attempt),
         {:ok, normalized} <- normalize_keys(result),
         :ok <- validate_required_fields(normalized),
         :ok <- validate_enum(normalized, "attempt_outcome", @attempt_outcomes),
         :ok <- validate_event_outcome(event_type, normalized),
         {:ok, started_at, normalized} <- normalize_datetime(normalized, "started_at"),
         {:ok, ended_at, normalized} <- normalize_datetime(normalized, "ended_at"),
         :ok <- validate_time_order(started_at, ended_at),
         :ok <- validate_boolean(normalized, "accepted"),
         :ok <- validate_boolean(normalized, "output_committed"),
         :ok <- validate_optional_boolean(normalized, "runtime_retryable"),
         :ok <- validate_enum(normalized, "execution_resolution", @execution_resolutions),
         :ok <-
           validate_enum(normalized, "capacity_release_outcome", @capacity_release_outcomes),
         :ok <- validate_optional_enum(normalized, "output_commitment_kind", @commitment_kinds),
         :ok <-
           validate_optional_enum(
             normalized,
             "failure_class",
             InferenceAttemptFailure.failure_classes()
           ),
         :ok <-
           validate_optional_enum(
             normalized,
             "failure_code",
             InferenceAttemptFailure.stable_error_codes()
           ),
         :ok <- validate_optional_enum(normalized, "finish_reason", @finish_reasons),
         :ok <- validate_optional_strings(normalized),
         :ok <- validate_optional_integers(normalized),
         :ok <- validate_commitment(normalized),
         :ok <- validate_acceptance_resolution(normalized),
         :ok <- validate_outcome_fields(attempt, normalized),
         :ok <- validate_outcome_failure_consistency(normalized),
         :ok <- validate_retry_consistency(attempt, normalized) do
      validate_node_evidence(attempt, normalized)
    end
  end

  def new(_event_type, _attempt, _result), do: {:error, "inference attempt result must be a map"}

  defp validate_attempt(attempt) when attempt in [1, 2], do: :ok
  defp validate_attempt(_attempt), do: {:error, "attempt must be 1 or 2"}

  defp normalize_keys(result) do
    Enum.reduce_while(result, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        normalized_key not in @fields ->
          {:halt, {:error, "unexpected inference attempt result field #{inspect(key)}"}}

        Map.has_key?(acc, normalized_key) ->
          {:halt, {:error, "duplicate inference attempt result field #{inspect(normalized_key)}"}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
      end
    end)
  end

  defp validate_required_fields(result) do
    case Enum.find(@required_fields, &(not Map.has_key?(result, &1))) do
      nil -> :ok
      field -> {:error, "inference attempt result requires #{field}"}
    end
  end

  defp normalize_datetime(result, field) do
    case Map.fetch!(result, field) do
      %DateTime{} = datetime ->
        normalized = DateTime.to_iso8601(datetime)
        {:ok, datetime, Map.put(result, field, normalized)}

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, 0} ->
            {:ok, datetime, Map.put(result, field, DateTime.to_iso8601(datetime))}

          _error ->
            {:error, "#{field} must be a canonical UTC timestamp"}
        end

      _value ->
        {:error, "#{field} must be a canonical UTC timestamp"}
    end
  end

  defp validate_time_order(started_at, ended_at) do
    if DateTime.compare(ended_at, started_at) == :lt,
      do: {:error, "ended_at must not precede started_at"},
      else: :ok
  end

  defp validate_event_outcome(event_type, result) do
    case Map.fetch(@event_outcomes, event_type) do
      {:ok, expected} ->
        if expected == result["attempt_outcome"],
          do: :ok,
          else: {:error, "attempt_outcome must be #{expected} for #{event_type}"}

      :error ->
        {:error, "event_type does not close an inference attempt"}
    end
  end

  defp validate_boolean(result, field) do
    if is_boolean(result[field]), do: :ok, else: {:error, "#{field} must be a boolean"}
  end

  defp validate_optional_boolean(result, field) do
    case Map.fetch(result, field) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, "#{field} must be a boolean"}
    end
  end

  defp validate_enum(result, field, values) do
    if result[field] in values,
      do: :ok,
      else: {:error, "#{field} must be one of #{Enum.join(values, ", ")}"}
  end

  defp validate_optional_enum(result, field, values) do
    case Map.fetch(result, field) do
      :error ->
        :ok

      {:ok, value} ->
        if value in values,
          do: :ok,
          else: {:error, "#{field} must be one of #{Enum.join(values, ", ")}"}
    end
  end

  defp validate_optional_strings(result) do
    Enum.reduce_while(~w(target_ref raw_source_code error_message), :ok, fn field, :ok ->
      case Map.fetch(result, field) do
        :error -> {:cont, :ok}
        {:ok, value} when is_binary(value) and value != "" -> {:cont, :ok}
        {:ok, _value} -> {:halt, {:error, "#{field} must be a non-empty string"}}
      end
    end)
  end

  defp validate_optional_integers(result) do
    Enum.reduce_while(~w(input_tokens output_tokens http_status), :ok, fn field, :ok ->
      case Map.fetch(result, field) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_integer(value) and value >= 0 and value <= @maximum_integer ->
          {:cont, :ok}

        {:ok, _value} ->
          {:halt, {:error, "#{field} must be a bounded non-negative integer"}}
      end
    end)
  end

  defp validate_commitment(%{"output_committed" => true} = result) do
    if result["output_commitment_kind"] in @commitment_kinds,
      do: :ok,
      else: {:error, "committed output requires output_commitment_kind"}
  end

  defp validate_commitment(%{"output_committed" => false} = result) do
    if Map.has_key?(result, "output_commitment_kind"),
      do: {:error, "uncommitted output must omit output_commitment_kind"},
      else: :ok
  end

  defp validate_acceptance_resolution(%{"accepted" => false, "output_committed" => true}),
    do: {:error, "unaccepted attempts cannot commit output"}

  defp validate_acceptance_resolution(%{
         "accepted" => true,
         "execution_resolution" => "not_started"
       }),
       do: {:error, "not_started execution requires accepted to be false"}

  defp validate_acceptance_resolution(_result), do: :ok

  defp validate_outcome_fields(_attempt, %{"attempt_outcome" => "completed"} = result) do
    forbidden =
      ~w(failure_class failure_code retry_decision raw_source_code error_message runtime_retryable)

    if Enum.any?(forbidden, &Map.has_key?(result, &1)),
      do: {:error, "completed attempts must omit failure and retry fields"},
      else: :ok
  end

  defp validate_outcome_fields(attempt, result) do
    with :ok <- require_failure_field(result, "failure_class"),
         :ok <- require_failure_field(result, "failure_code"),
         :ok <- require_failure_field(result, "retry_decision") do
      validate_retry_decision(attempt, result["retry_decision"])
    end
  end

  defp require_failure_field(result, field) do
    if Map.has_key?(result, field),
      do: :ok,
      else: {:error, "unsuccessful attempts require #{field}"}
  end

  defp validate_retry_decision(1, decision) when decision in @attempt_one_decisions, do: :ok
  defp validate_retry_decision(2, decision) when decision in @attempt_two_decisions, do: :ok

  defp validate_retry_decision(attempt, _decision),
    do: {:error, "retry_decision is invalid for attempt #{attempt}"}

  defp validate_outcome_failure_consistency(%{
         "attempt_outcome" => "cancelled",
         "failure_class" => "cancellation"
       }),
       do: :ok

  defp validate_outcome_failure_consistency(%{"attempt_outcome" => "cancelled"}),
    do: {:error, "cancelled attempts require cancellation failure evidence"}

  defp validate_outcome_failure_consistency(_result), do: :ok

  defp validate_retry_consistency(1, %{
         "output_committed" => true,
         "retry_decision" => decision
       })
       when decision != "output_committed",
       do: {:error, "committed output requires output_committed retry decision"}

  defp validate_retry_consistency(_attempt, result), do: validate_retry_consistency(result)

  defp validate_retry_consistency(%{
         "attempt_outcome" => "cancelled",
         "output_committed" => false,
         "retry_decision" => decision
       })
       when decision != "cancelled",
       do: {:error, "uncommitted cancelled attempts require cancelled retry decision"}

  defp validate_retry_consistency(%{
         "retry_decision" => "retried",
         "output_committed" => true
       }),
       do: {:error, "retried attempts cannot have committed output"}

  defp validate_retry_consistency(%{
         "retry_decision" => "retried",
         "node_id" => node_id,
         "execution_resolution" => execution_resolution,
         "capacity_release_outcome" => release_outcome
       })
       when is_binary(node_id) and execution_resolution != "unresolved" and
              release_outcome in ["released", "already_released", "not_applicable"],
       do: :ok

  defp validate_retry_consistency(%{"retry_decision" => "retried"}),
    do: {:error, "retried attempts require resolved Node, execution, and capacity evidence"}

  defp validate_retry_consistency(%{
         "retry_decision" => "output_committed",
         "output_committed" => false
       }),
       do: {:error, "output_committed retry decision requires committed output"}

  defp validate_retry_consistency(%{
         "retry_decision" => "cancelled",
         "attempt_outcome" => outcome,
         "failure_class" => failure_class
       })
       when outcome != "cancelled" or failure_class != "cancellation",
       do: {:error, "cancelled retry decision requires a cancelled attempt"}

  defp validate_retry_consistency(_result), do: :ok

  defp validate_node_evidence(attempt, result) do
    with {:ok, node_id} <- optional_uuid(result["node_id"], "node_id"),
         {:ok, excluded_node_ids} <- uuid_list(result["excluded_node_ids"]) do
      cond do
        attempt == 1 and excluded_node_ids != [] ->
          {:error, "attempt 1 requires an empty exclusion list"}

        attempt == 2 and length(excluded_node_ids) != 1 ->
          {:error, "attempt 2 requires exactly one excluded Node UUID"}

        attempt == 2 and node_id in excluded_node_ids ->
          {:error, "attempt 2 selected Node must differ from its exclusion"}

        true ->
          normalized =
            result
            |> Map.put("excluded_node_ids", excluded_node_ids)
            |> put_optional_node_id(node_id)

          {:ok, normalized}
      end
    end
  end

  defp put_optional_node_id(result, nil), do: Map.delete(result, "node_id")
  defp put_optional_node_id(result, node_id), do: Map.put(result, "node_id", node_id)

  defp optional_uuid(nil, _field), do: {:ok, nil}

  defp optional_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "#{field} must be a valid UUID"}
    end
  end

  defp uuid_list(values) when is_list(values) do
    with {:ok, uuids} <- cast_uuids(values),
         true <- length(uuids) == MapSet.size(MapSet.new(uuids)) do
      {:ok, uuids}
    else
      false -> {:error, "excluded_node_ids must not contain duplicates"}
      :error -> {:error, "excluded_node_ids must contain valid UUIDs"}
    end
  end

  defp uuid_list(_values), do: {:error, "excluded_node_ids must be a list"}

  defp cast_uuids(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, uuids} -> {:ok, Enum.reverse(uuids)}
      :error -> :error
    end
  end
end
