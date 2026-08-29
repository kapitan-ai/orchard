defmodule Orchard.Dispatch.AttemptOutcome do
  @moduledoc """
  Typed internal evidence returned by one dispatcher attempt.
  """

  alias Orchard.Dispatch.AttemptEventDelivery
  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.InferenceEvent
  alias Orchard.Requests.InferenceAttemptFailure

  @enforce_keys [
    :attempt_outcome,
    :node_id,
    :accepted,
    :events,
    :failure,
    :execution_resolution,
    :capacity_release_outcome,
    :started_at,
    :ended_at,
    :first_token_at,
    :output_committed,
    :output_commitment_kind,
    :delivery_state,
    :delivered_event_count
  ]
  defstruct @enforce_keys ++ [runtime_retryable: nil, model_load_category: nil]

  @attempt_outcomes [:completed, :failed, :cancelled, :timed_out, :interrupted]
  @execution_resolutions [:not_started, :terminated, :unresolved]
  @capacity_release_outcomes [:released, :already_released, :not_applicable, :unresolved]
  @commitment_kinds [:text, :tool_call, :structured_output]
  @non_text_commitment_kinds @commitment_kinds -- [:text]
  @model_load_categories ModelLoadFailure.categories()

  @type attempt_outcome :: :completed | :failed | :cancelled | :timed_out | :interrupted
  @type execution_resolution :: :not_started | :terminated | :unresolved

  @type capacity_release_outcome ::
          :released | :already_released | :not_applicable | :unresolved

  @type commitment_kind :: :text | :tool_call | :structured_output
  @type delivery_state :: :pending | :selected | :discarded | :failed
  @type failure :: InferenceAttemptFailure.evidence() | nil

  @type t :: %__MODULE__{
          attempt_outcome: attempt_outcome(),
          node_id: Ecto.UUID.t() | nil,
          accepted: boolean(),
          events: [InferenceEvent.t()],
          failure: failure(),
          execution_resolution: execution_resolution(),
          capacity_release_outcome: capacity_release_outcome(),
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          first_token_at: DateTime.t() | nil,
          output_committed: boolean(),
          output_commitment_kind: commitment_kind() | nil,
          delivery_state: delivery_state(),
          delivered_event_count: non_neg_integer(),
          runtime_retryable: boolean() | nil,
          model_load_category: ModelLoadFailure.category() | nil
        }

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_attempt_outcome}
  def new(
        %{
          attempt_outcome: attempt_outcome,
          node_id: node_id,
          accepted: accepted,
          events: events,
          failure: failure,
          execution_resolution: execution_resolution,
          capacity_release_outcome: capacity_release_outcome,
          started_at: %DateTime{} = started_at,
          ended_at: %DateTime{} = ended_at,
          first_token_at: first_token_at,
          output_committed: output_committed,
          output_commitment_kind: output_commitment_kind,
          delivery_state: delivery_state,
          delivered_event_count: delivered_event_count
        } = attrs
      ) do
    if valid_identity?(attempt_outcome, node_id, accepted, events) and
         valid_result?(attempt_outcome, failure, execution_resolution, capacity_release_outcome) and
         valid_runtime_retryable?(attempt_outcome, Map.get(attrs, :runtime_retryable)) and
         valid_model_load_category?(failure, Map.get(attrs, :model_load_category)) and
         ordered_timestamps?(started_at, ended_at, first_token_at) and
         valid_commitment?(accepted, output_committed, output_commitment_kind, first_token_at) and
         valid_delivery?(
           delivery_state,
           delivered_event_count,
           length(events),
           output_committed
         ) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      {:error, :invalid_attempt_outcome}
    end
  end

  def new(_attrs), do: {:error, :invalid_attempt_outcome}

  @spec select(t(), String.t(), (String.t(), InferenceEvent.t() -> term()) | nil) :: t()
  def select(%__MODULE__{delivery_state: :pending} = outcome, request_id, event_handler) do
    delivery =
      Enum.reduce(
        outcome.events,
        AttemptEventDelivery.new(request_id, event_handler),
        &AttemptEventDelivery.record(&2, &1)
      )
      |> AttemptEventDelivery.select()

    selected = %{
      outcome
      | delivery_state: AttemptEventDelivery.delivery_state(delivery),
        delivered_event_count: AttemptEventDelivery.delivered_event_count(delivery)
    }

    case AttemptEventDelivery.failure_reason(delivery) do
      :cancel ->
        cancel_delivery(selected, selected.delivered_event_count)

      reason when reason in [:serializer_failed, :event_handler_failed] ->
        fail_delivery(selected, selected.delivered_event_count)

      nil ->
        selected
    end
  end

  def select(%__MODULE__{} = outcome, _request_id, _event_handler), do: outcome

  @spec discard(t()) :: {:ok, t()} | {:error, :output_committed | :already_selected}
  def discard(%__MODULE__{output_committed: true}), do: {:error, :output_committed}

  def discard(%__MODULE__{delivery_state: :pending} = outcome),
    do: {:ok, %{outcome | delivery_state: :discarded}}

  def discard(%__MODULE__{}), do: {:error, :already_selected}

  @spec fail_attempt(t()) :: t()
  def fail_attempt(%__MODULE__{} = outcome) do
    attrs = %{
      outcome
      | attempt_outcome: :failed,
        model_load_category: nil,
        failure:
          InferenceAttemptFailure.normalize(%{
            category: :controller,
            code: :orchestration_error
          })
    }

    {:ok, transformed} = new(Map.from_struct(attrs))
    transformed
  end

  @spec fail_delivery(t(), non_neg_integer()) :: t()
  def fail_delivery(%__MODULE__{} = outcome, delivered_event_count) do
    transform_delivery_failure(
      outcome,
      :failed,
      delivered_event_count,
      InferenceAttemptFailure.normalize(%{category: :controller, code: :orchestration_error})
    )
  end

  @spec cancel_delivery(t(), non_neg_integer()) :: t()
  def cancel_delivery(%__MODULE__{} = outcome, delivered_event_count) do
    transform_delivery_failure(
      outcome,
      :cancelled,
      delivered_event_count,
      InferenceAttemptFailure.normalize(%{
        category: :cancellation,
        code: :request_client_disconnect
      })
    )
  end

  defp transform_delivery_failure(outcome, attempt_outcome, delivered_event_count, failure) do
    attrs = %{
      outcome
      | attempt_outcome: attempt_outcome,
        delivery_state: :failed,
        delivered_event_count: delivered_event_count,
        model_load_category: nil,
        failure: failure
    }

    {:ok, transformed} = new(Map.from_struct(attrs))
    transformed
  end

  defp valid_identity?(attempt_outcome, node_id, accepted, events) do
    attempt_outcome in @attempt_outcomes and valid_node_id?(node_id) and is_boolean(accepted) and
      valid_events?(events)
  end

  defp valid_result?(attempt_outcome, failure, execution_resolution, capacity_release_outcome) do
    valid_failure?(attempt_outcome, failure) and
      execution_resolution in @execution_resolutions and
      capacity_release_outcome in @capacity_release_outcomes
  end

  defp valid_node_id?(nil), do: true
  defp valid_node_id?(node_id), do: match?({:ok, _uuid}, Ecto.UUID.cast(node_id))

  defp valid_events?(events),
    do: is_list(events) and Enum.all?(events, &match?(%InferenceEvent{}, &1))

  defp valid_failure?(:completed, nil), do: true

  defp valid_failure?(attempt_outcome, %{
         "failure_class" => failure_class,
         "failure_code" => failure_code
       })
       when attempt_outcome != :completed do
    failure_class in InferenceAttemptFailure.failure_classes() and
      failure_code in InferenceAttemptFailure.stable_error_codes()
  end

  defp valid_failure?(_attempt_outcome, _failure), do: false

  defp valid_runtime_retryable?(:completed, nil), do: true

  defp valid_runtime_retryable?(attempt_outcome, runtime_retryable)
       when attempt_outcome != :completed,
       do: is_boolean(runtime_retryable) or is_nil(runtime_retryable)

  defp valid_runtime_retryable?(_attempt_outcome, _runtime_retryable), do: false

  defp valid_model_load_category?(
         %{"failure_class" => "model_load_failure"},
         model_load_category
       ),
       do: model_load_category in @model_load_categories

  defp valid_model_load_category?(%{"failure_class" => failure_class}, nil)
       when failure_class != "model_load_failure",
       do: true

  defp valid_model_load_category?(nil, nil), do: true
  defp valid_model_load_category?(_failure, _model_load_category), do: false

  defp valid_commitment?(true, true, :text, %DateTime{}), do: true

  defp valid_commitment?(true, true, kind, first_token_at)
       when kind in @non_text_commitment_kinds and
              (is_nil(first_token_at) or is_struct(first_token_at, DateTime)),
       do: true

  defp valid_commitment?(_accepted, false, nil, nil), do: true
  defp valid_commitment?(_accepted, _committed, _kind, _first_token_at), do: false

  defp valid_delivery?(:pending, 0, _event_count, false), do: true
  defp valid_delivery?(:discarded, 0, _event_count, false), do: true
  defp valid_delivery?(:selected, event_count, event_count, _output_committed), do: true

  defp valid_delivery?(:failed, delivered_event_count, event_count, _output_committed),
    do:
      is_integer(delivered_event_count) and delivered_event_count >= 0 and
        delivered_event_count < event_count

  defp valid_delivery?(_state, _delivered_event_count, _event_count, _output_committed),
    do: false

  defp ordered_timestamps?(started_at, ended_at, nil) do
    DateTime.compare(ended_at, started_at) != :lt
  end

  defp ordered_timestamps?(started_at, ended_at, %DateTime{} = first_token_at) do
    DateTime.compare(ended_at, started_at) != :lt and
      DateTime.compare(first_token_at, started_at) != :lt and
      DateTime.compare(first_token_at, ended_at) != :gt
  end

  defp ordered_timestamps?(_started_at, _ended_at, _first_token_at), do: false
end
