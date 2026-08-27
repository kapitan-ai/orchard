defmodule Orchard.Inference.AttemptRetryClassifier do
  @moduledoc """
  Pure fail-closed classification of unsuccessful inference attempts.
  """

  defmodule Boundary do
    @moduledoc false

    @enforce_keys [
      :attempt,
      :output_committed,
      :budget_remaining?,
      :cancelled?,
      :failure_class,
      :failure_code,
      :runtime_retryable,
      :alternate_available?
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            attempt: 1 | 2,
            output_committed: boolean(),
            budget_remaining?: boolean(),
            cancelled?: boolean(),
            failure_class: String.t(),
            failure_code: String.t(),
            runtime_retryable: boolean() | nil,
            alternate_available?: boolean()
          }
  end

  @runtime_retryable_codes ~w(
    node_unavailable node_timeout runtime_unavailable resource_exhausted timeout
    worker_unavailable worker_down
  )
  @model_load_retryable_codes ~w(
    acquisition_failed runtime_unavailable resource_exhausted load_timeout
  )
  @pre_acceptance_retryable_codes ~w(
    node_unavailable node_timeout runtime_unavailable rpc_unavailable
  )
  @attempt_one_gates [
    :output_committed,
    :budget_exhausted,
    :cancelled,
    :taxonomy,
    :alternate
  ]

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
          output_committed: boolean(),
          budget_remaining?: boolean(),
          cancelled?: boolean(),
          failure_class: String.t(),
          failure_code: String.t(),
          runtime_retryable: boolean() | nil,
          alternate_available?: boolean()
        }) :: t()
  def new(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :raw_source_code) or Map.has_key?(attrs, "raw_source_code") do
      raise ArgumentError, "raw_source_code cannot control retry classification"
    end

    build_boundary(attrs)
  end

  @spec decide(t()) :: retry_decision_atom()
  def decide(%Boundary{attempt: 2, cancelled?: true}), do: :cancelled
  def decide(%Boundary{attempt: 2}), do: :retry_exhausted

  def decide(%Boundary{attempt: 1} = boundary) do
    Enum.find_value(@attempt_one_gates, &gate_decision(&1, boundary))
  end

  defp build_boundary(%{
         attempt: attempt,
         output_committed: output_committed,
         budget_remaining?: budget_remaining?,
         cancelled?: cancelled?,
         failure_class: failure_class,
         failure_code: failure_code,
         runtime_retryable: runtime_retryable,
         alternate_available?: alternate_available?
       })
       when attempt in [1, 2] and is_boolean(output_committed) and
              is_boolean(budget_remaining?) and is_boolean(cancelled?) and
              is_binary(failure_class) and is_binary(failure_code) and
              (is_boolean(runtime_retryable) or is_nil(runtime_retryable)) and
              is_boolean(alternate_available?) do
    %Boundary{
      attempt: attempt,
      output_committed: output_committed,
      budget_remaining?: budget_remaining?,
      cancelled?: cancelled?,
      failure_class: failure_class,
      failure_code: failure_code,
      runtime_retryable: runtime_retryable,
      alternate_available?: alternate_available?
    }
  end

  defp gate_decision(:output_committed, %Boundary{output_committed: true}),
    do: :output_committed

  defp gate_decision(:budget_exhausted, %Boundary{budget_remaining?: false}),
    do: :budget_exhausted

  defp gate_decision(:cancelled, %Boundary{cancelled?: true}), do: :cancelled
  defp gate_decision(:taxonomy, boundary), do: taxonomy_verdict(boundary)
  defp gate_decision(:alternate, %Boundary{alternate_available?: true}), do: :retried
  defp gate_decision(:alternate, %Boundary{}), do: :no_alternative_node
  defp gate_decision(_gate, %Boundary{}), do: nil

  defp taxonomy_verdict(%Boundary{failure_class: "identity_unresolved"}),
    do: :identity_unresolved

  defp taxonomy_verdict(%Boundary{failure_class: "occupancy_unresolved"}),
    do: :occupancy_unresolved

  defp taxonomy_verdict(%Boundary{} = boundary) do
    if retry_eligible?(boundary), do: nil, else: :not_retryable
  end

  defp retry_eligible?(%Boundary{
         failure_class: "runtime_failure",
         failure_code: code,
         runtime_retryable: true
       }),
       do: code in @runtime_retryable_codes

  defp retry_eligible?(%Boundary{failure_class: "model_load_failure", failure_code: code}),
    do: code in @model_load_retryable_codes

  defp retry_eligible?(%Boundary{
         failure_class: "pre_acceptance_unavailable",
         failure_code: code
       }),
       do: code in @pre_acceptance_retryable_codes

  defp retry_eligible?(%Boundary{failure_class: "worker_or_node_loss"}), do: true
  defp retry_eligible?(%Boundary{}), do: false
end
