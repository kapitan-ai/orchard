defmodule Orchard.Dispatch.AttemptOutcome do
  @moduledoc """
  Typed internal evidence returned by one dispatcher attempt.
  """

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
    :first_token_at
  ]
  defstruct @enforce_keys

  @attempt_outcomes [:completed, :failed, :cancelled, :timed_out, :interrupted]
  @execution_resolutions [:not_started, :terminated, :unresolved]
  @capacity_release_outcomes [:released, :already_released, :not_applicable, :unresolved]

  @type attempt_outcome :: :completed | :failed | :cancelled | :timed_out | :interrupted
  @type execution_resolution :: :not_started | :terminated | :unresolved

  @type capacity_release_outcome ::
          :released | :already_released | :not_applicable | :unresolved

  @type failure :: InferenceAttemptFailure.evidence() | nil

  @type t :: %__MODULE__{
          attempt_outcome: attempt_outcome(),
          node_id: Ecto.UUID.t() | nil,
          accepted: boolean(),
          events: [Orchard.InferenceEvent.t()],
          failure: failure(),
          execution_resolution: execution_resolution(),
          capacity_release_outcome: capacity_release_outcome(),
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          first_token_at: DateTime.t() | nil
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
          first_token_at: first_token_at
        } = attrs
      ) do
    if attempt_outcome in @attempt_outcomes and
         valid_node_id?(node_id) and
         is_boolean(accepted) and
         is_list(events) and
         valid_failure?(attempt_outcome, failure) and
         execution_resolution in @execution_resolutions and
         capacity_release_outcome in @capacity_release_outcomes and
         ordered_timestamps?(started_at, ended_at, first_token_at) do
      {:ok, struct!(__MODULE__, attrs)}
    else
      {:error, :invalid_attempt_outcome}
    end
  end

  def new(_attrs), do: {:error, :invalid_attempt_outcome}

  defp valid_node_id?(nil), do: true
  defp valid_node_id?(node_id), do: match?({:ok, _uuid}, Ecto.UUID.cast(node_id))

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
