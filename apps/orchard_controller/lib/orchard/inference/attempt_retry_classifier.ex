defmodule Orchard.Inference.AttemptRetryClassifier do
  @moduledoc """
  Pure fail-closed classification of unsuccessful inference attempts.
  """

  alias Orchard.Inference.ModelLoadFailure
  alias Orchard.Requests.InferenceAttemptFailure

  @type model_load_category :: Orchard.Inference.ModelLoadFailure.category() | nil

  defmodule Boundary do
    @moduledoc false

    @enforce_keys [
      :attempt,
      :attempt_outcome,
      :output_committed,
      :caller_status,
      :deadline_status,
      :failure_class,
      :failure_code,
      :model_load_category,
      :runtime_retryable,
      :identity_resolution,
      :execution_resolution,
      :capacity_release_outcome
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt: 1 | 2,
            attempt_outcome: :failed | :cancelled | :timed_out | :interrupted,
            output_committed: boolean(),
            caller_status: :live | :cancelled,
            deadline_status: :remaining | :exhausted,
            failure_class: String.t(),
            failure_code: String.t(),
            model_load_category: Orchard.Inference.AttemptRetryClassifier.model_load_category(),
            runtime_retryable: boolean() | nil,
            identity_resolution: :resolved | :unresolved,
            execution_resolution: :not_started | :terminated | :unresolved,
            capacity_release_outcome:
              :released | :already_released | :not_applicable | :unresolved
          }
  end

  @runtime_retryable_codes ~w(
    node_unavailable node_timeout runtime_unavailable resource_exhausted timeout
    worker_unavailable worker_down
  )
  @model_load_retryable_categories [
    :acquisition_failed,
    :runtime_unavailable,
    :resource_exhausted,
    :timeout
  ]
  @model_load_categories ModelLoadFailure.categories()
  @pre_acceptance_retryable_codes ~w(
    node_unavailable node_timeout runtime_unavailable rpc_unavailable
  )
  @attempt_one_gates [
    :output_committed,
    :cancelled,
    :budget_exhausted,
    :taxonomy,
    :identity,
    :execution,
    :capacity_release
  ]

  @type alternate_result :: :different_node | :no_candidate | :identity_unresolved
  @type pre_schedule_result :: :eligible_for_alternate | {:declined, retry_decision_atom()}
  @type retry_decision_atom ::
          :retried
          | :not_retryable
          | :output_committed
          | :cancelled
          | :budget_exhausted
          | :identity_unresolved
          | :occupancy_unresolved
          | :no_alternative_node
          | :retry_exhausted
  @type t :: Boundary.t()

  @spec new(%{
          attempt: 1 | 2,
          attempt_outcome: :failed | :cancelled | :timed_out | :interrupted,
          output_committed: boolean(),
          caller_status: :live | :cancelled,
          deadline_status: :remaining | :exhausted,
          failure_class: String.t(),
          failure_code: String.t(),
          model_load_category: model_load_category(),
          runtime_retryable: boolean() | nil,
          identity_resolution: :resolved | :unresolved,
          execution_resolution: :not_started | :terminated | :unresolved,
          capacity_release_outcome: :released | :already_released | :not_applicable | :unresolved
        }) :: t()
  def new(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :raw_source_code) or Map.has_key?(attrs, "raw_source_code") do
      raise ArgumentError, "raw_source_code cannot control retry classification"
    end

    build_boundary(attrs)
  end

  @spec pre_schedule(t()) :: pre_schedule_result()
  def pre_schedule(%Boundary{attempt: 2, caller_status: :cancelled}),
    do: {:declined, :cancelled}

  def pre_schedule(%Boundary{attempt: 2, deadline_status: :exhausted}),
    do: {:declined, :retry_exhausted}

  def pre_schedule(%Boundary{attempt: 2, output_committed: true}),
    do: {:declined, :retry_exhausted}

  def pre_schedule(%Boundary{attempt: 2} = boundary),
    do: {:declined, attempt_two_decision(boundary)}

  def pre_schedule(%Boundary{attempt: 1} = boundary),
    do: Enum.find_value(@attempt_one_gates, :eligible_for_alternate, &gate_decision(&1, boundary))

  @spec finalize_alternate(t(), alternate_result()) ::
          :retried | :no_alternative_node | :identity_unresolved
  def finalize_alternate(%Boundary{attempt: 1} = boundary, alternate_result)
      when alternate_result in [:different_node, :no_candidate, :identity_unresolved] do
    case pre_schedule(boundary) do
      :eligible_for_alternate ->
        alternate_decision(alternate_result)

      {:declined, decision} ->
        raise ArgumentError, "cannot finalize declined retry boundary: #{decision}"
    end
  end

  defp build_boundary(%{
         attempt: attempt,
         attempt_outcome: attempt_outcome,
         output_committed: output_committed,
         caller_status: caller_status,
         deadline_status: deadline_status,
         failure_class: failure_class,
         failure_code: failure_code,
         model_load_category: model_load_category,
         runtime_retryable: runtime_retryable,
         identity_resolution: identity_resolution,
         execution_resolution: execution_resolution,
         capacity_release_outcome: capacity_release_outcome
       })
       when attempt_outcome in [:failed, :cancelled, :timed_out, :interrupted] do
    :ok = validate_request_facts(attempt, output_committed, caller_status, deadline_status)

    :ok =
      validate_failure_facts(
        failure_class,
        failure_code,
        model_load_category,
        runtime_retryable
      )

    :ok = validate_identity_fact(identity_resolution)
    :ok = validate_occupancy_facts(execution_resolution, capacity_release_outcome)

    %Boundary{
      attempt: attempt,
      attempt_outcome: attempt_outcome,
      output_committed: output_committed,
      caller_status: caller_status,
      deadline_status: deadline_status,
      failure_class: failure_class,
      failure_code: failure_code,
      model_load_category: model_load_category,
      runtime_retryable: runtime_retryable,
      identity_resolution: identity_resolution,
      execution_resolution: execution_resolution,
      capacity_release_outcome: capacity_release_outcome
    }
  end

  defp validate_request_facts(attempt, output_committed, caller_status, deadline_status)
       when attempt in [1, 2] and is_boolean(output_committed) and
              caller_status in [:live, :cancelled] and
              deadline_status in [:remaining, :exhausted],
       do: :ok

  defp validate_failure_facts(
         "model_load_failure",
         failure_code,
         model_load_category,
         runtime_retryable
       )
       when is_binary(failure_code) and model_load_category in @model_load_categories and
              (is_boolean(runtime_retryable) or is_nil(runtime_retryable)),
       do: :ok

  defp validate_failure_facts(failure_class, failure_code, nil, runtime_retryable)
       when is_binary(failure_class) and failure_class != "model_load_failure" and
              is_binary(failure_code) and
              (is_boolean(runtime_retryable) or is_nil(runtime_retryable)),
       do: :ok

  defp validate_identity_fact(identity_resolution)
       when identity_resolution in [:resolved, :unresolved],
       do: :ok

  defp validate_occupancy_facts(execution_resolution, capacity_release_outcome)
       when execution_resolution in [:not_started, :terminated, :unresolved] and
              capacity_release_outcome in [
                :released,
                :already_released,
                :not_applicable,
                :unresolved
              ],
       do: :ok

  defp gate_decision(:output_committed, %Boundary{output_committed: true}),
    do: {:declined, :output_committed}

  defp gate_decision(:budget_exhausted, %Boundary{deadline_status: :exhausted}),
    do: {:declined, :budget_exhausted}

  defp gate_decision(:cancelled, %Boundary{caller_status: :cancelled}),
    do: {:declined, :cancelled}

  defp gate_decision(:taxonomy, boundary), do: taxonomy_verdict(boundary)

  defp gate_decision(:identity, %Boundary{failure_class: "identity_unresolved"}),
    do: {:declined, :identity_unresolved}

  defp gate_decision(:identity, %Boundary{identity_resolution: :unresolved}),
    do: {:declined, :identity_unresolved}

  defp gate_decision(:execution, %Boundary{failure_class: "occupancy_unresolved"}),
    do: {:declined, :occupancy_unresolved}

  defp gate_decision(:execution, %Boundary{execution_resolution: :unresolved}),
    do: {:declined, :occupancy_unresolved}

  defp gate_decision(:capacity_release, %Boundary{capacity_release_outcome: :unresolved}),
    do: {:declined, :occupancy_unresolved}

  defp gate_decision(_gate, %Boundary{}), do: nil

  defp taxonomy_verdict(%Boundary{failure_class: failure_class})
       when failure_class in ["identity_unresolved", "occupancy_unresolved"],
       do: nil

  defp taxonomy_verdict(%Boundary{} = boundary) do
    if retry_eligible?(boundary), do: nil, else: {:declined, :not_retryable}
  end

  defp attempt_two_decision(%Boundary{
         attempt_outcome: :failed,
         failure_class: failure_class,
         failure_code: failure_code
       }) do
    if InferenceAttemptFailure.acceptance_proof_failure?(failure_class, failure_code),
      do: :not_retryable,
      else: :retry_exhausted
  end

  defp attempt_two_decision(%Boundary{}), do: :retry_exhausted

  defp alternate_decision(:different_node), do: :retried
  defp alternate_decision(:no_candidate), do: :no_alternative_node
  defp alternate_decision(:identity_unresolved), do: :identity_unresolved

  defp retry_eligible?(%Boundary{
         failure_class: "runtime_failure",
         failure_code: code,
         runtime_retryable: true
       }),
       do: code in @runtime_retryable_codes

  defp retry_eligible?(%Boundary{
         failure_class: "model_load_failure",
         model_load_category: category
       }),
       do: category in @model_load_retryable_categories

  defp retry_eligible?(%Boundary{
         failure_class: "pre_acceptance_unavailable",
         failure_code: code
       }),
       do: code in @pre_acceptance_retryable_codes

  defp retry_eligible?(%Boundary{
         failure_class: "worker_or_node_loss",
         runtime_retryable: false
       }),
       do: false

  defp retry_eligible?(%Boundary{failure_class: "worker_or_node_loss"}), do: true
  defp retry_eligible?(%Boundary{}), do: false
end
