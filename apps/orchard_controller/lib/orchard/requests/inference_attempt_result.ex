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
  @persisted_usage_fields ~w(output_usage_status reasoning_tokens)
  @persisted_fields @fields ++ @persisted_usage_fields

  # Keep the established marker vocabulary literal: `output_tokens` alone has
  # never made an otherwise legacy result enriched.
  @marker_fields MapSet.new(~w(
    attempt_outcome started_at ended_at accepted output_committed execution_resolution
    capacity_release_outcome excluded_node_ids output_commitment_kind node_id target_ref
    failure_class failure_code runtime_retryable retry_decision raw_source_code
    output_usage_status reasoning_tokens
  ))

  unmarked_required_fields = @required_fields -- MapSet.to_list(@marker_fields)

  if unmarked_required_fields != [] do
    raise "required inference attempt result fields absent from the marker vocabulary: " <>
            inspect(unmarked_required_fields)
  end

  @attempt_outcomes ~w(completed failed cancelled timed_out interrupted)
  @commitment_kinds ~w(text tool_call structured_output)
  @persisted_commitment_kinds @commitment_kinds ++ ~w(reasoning)
  @output_usage_statuses ~w(exact lower_bound)
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

  @new_write_contract %{fields: @fields, commitment_kinds: @commitment_kinds}
  @persisted_contract %{
    fields: @persisted_fields,
    commitment_kinds: @persisted_commitment_kinds
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

  @spec attempt_outcomes() :: [String.t()]
  def attempt_outcomes, do: @attempt_outcomes

  @spec attempt_one_retry_decisions() :: [String.t()]
  def attempt_one_retry_decisions, do: @attempt_one_decisions

  @spec new(String.t(), 1 | 2, map()) :: {:ok, t()} | {:error, String.t()}
  def new(event_type, attempt, result) when is_map(result),
    do: validate(event_type, attempt, result, @new_write_contract)

  def new(_event_type, _attempt, _result), do: {:error, "inference attempt result must be a map"}

  @doc """
  Validates terminal attempt evidence read from durable storage.

  Historical rows may omit the usage-status vocabulary. Rows that contain any
  of that vocabulary must satisfy the complete current usage contract. The
  `SPEC.md` §3.7.1 `reasoning` commitment kind is readable only here, while
  `new/3` holds every current writer to the pre-reasoning vocabulary.

  Deploy this compatibility reader to every Controller and background reader
  before PR #418's new-format writers may merge; pre-bridge binaries reject it.
  PR #418 stays blocked until those paired status writers are active, not
  merely until the nullable column exists.
  """
  @spec from_persisted(String.t(), 1 | 2, map()) :: {:ok, t()} | {:error, String.t()}
  def from_persisted(event_type, attempt, result) when is_map(result),
    do: validate(event_type, attempt, result, @persisted_contract)

  def from_persisted(_event_type, _attempt, _result),
    do: {:error, "inference attempt result must be a map"}

  defp validate(event_type, attempt, result, contract) do
    with :ok <- validate_attempt(attempt),
         {:ok, normalized} <- normalize_keys(result, contract.fields),
         :ok <- validate_persisted_usage(normalized),
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
         :ok <-
           validate_optional_enum(
             normalized,
             "output_commitment_kind",
             contract.commitment_kinds
           ),
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
         :ok <- validate_commitment(normalized, contract.commitment_kinds),
         :ok <- validate_acceptance_resolution(normalized),
         :ok <- validate_outcome_fields(attempt, normalized),
         :ok <- validate_outcome_failure_consistency(normalized),
         :ok <- validate_retry_consistency(attempt, normalized) do
      validate_node_evidence(attempt, normalized)
    end
  end

  defp validate_attempt(attempt) when attempt in [1, 2], do: :ok
  defp validate_attempt(_attempt), do: {:error, "attempt must be 1 or 2"}

  defp normalize_keys(result, allowed_fields) do
    Enum.reduce_while(result, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        normalized_key not in allowed_fields ->
          {:halt, {:error, "unexpected inference attempt result field #{inspect(key)}"}}

        Map.has_key?(acc, normalized_key) ->
          {:halt, {:error, "duplicate inference attempt result field #{inspect(normalized_key)}"}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
      end
    end)
  end

  defp validate_persisted_usage(result) do
    case Map.fetch(result, "output_usage_status") do
      {:ok, status} when status in @output_usage_statuses ->
        with :ok <- require_usage_output_tokens(result) do
          validate_reasoning_tokens(result)
        end

      {:ok, _status} ->
        {:error, "output_usage_status must be one of #{Enum.join(@output_usage_statuses, ", ")}"}

      :error ->
        if Map.has_key?(result, "reasoning_tokens"),
          do: {:error, "reasoning_tokens requires output_usage_status"},
          else: :ok
    end
  end

  defp require_usage_output_tokens(%{"output_tokens" => output_tokens})
       when is_integer(output_tokens) and output_tokens >= 0 and output_tokens <= @maximum_integer,
       do: :ok

  defp require_usage_output_tokens(_result),
    do: {:error, "output_usage_status requires a bounded non-negative output_tokens"}

  defp validate_reasoning_tokens(result) do
    case Map.fetch(result, "reasoning_tokens") do
      :error ->
        :ok

      {:ok, reasoning_tokens}
      when is_integer(reasoning_tokens) and reasoning_tokens >= 0 and
             reasoning_tokens <= @maximum_integer ->
        if reasoning_tokens <= result["output_tokens"] do
          :ok
        else
          {:error,
           "reasoning_tokens must be a bounded non-negative integer no greater than output_tokens"}
        end

      {:ok, _reasoning_tokens} ->
        {:error,
         "reasoning_tokens must be a bounded non-negative integer no greater than output_tokens"}
    end
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

  defp validate_commitment(%{"output_committed" => true} = result, commitment_kinds) do
    if result["output_commitment_kind"] in commitment_kinds,
      do: :ok,
      else: {:error, "committed output requires output_commitment_kind"}
  end

  defp validate_commitment(%{"output_committed" => false} = result, _commitment_kinds) do
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
      validate_retry_decision(attempt, result)
    end
  end

  defp require_failure_field(result, field) do
    if Map.has_key?(result, field),
      do: :ok,
      else: {:error, "unsuccessful attempts require #{field}"}
  end

  defp validate_retry_decision(1, %{"retry_decision" => decision})
       when decision in @attempt_one_decisions,
       do: :ok

  defp validate_retry_decision(2, %{"retry_decision" => decision})
       when decision in @attempt_two_decisions,
       do: :ok

  defp validate_retry_decision(2, result) do
    if acceptance_proof_exception?(result),
      do: :ok,
      else: {:error, "retry_decision is invalid for attempt 2"}
  end

  defp validate_retry_decision(attempt, _result),
    do: {:error, "retry_decision is invalid for attempt #{attempt}"}

  defp acceptance_proof_exception?(%{
         "retry_decision" => "not_retryable",
         "attempt_outcome" => "failed",
         "output_committed" => false,
         "failure_class" => failure_class,
         "failure_code" => failure_code
       }),
       do: InferenceAttemptFailure.acceptance_proof_failure?(failure_class, failure_code)

  defp acceptance_proof_exception?(_result), do: false

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
