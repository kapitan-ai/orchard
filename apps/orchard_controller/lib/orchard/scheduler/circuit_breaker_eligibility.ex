defmodule Orchard.Scheduler.CircuitBreakerEligibility do
  @moduledoc false

  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.CircuitBreakers
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.Models
  alias Orchard.Models.Model

  @type reason_code ::
          :node_circuit_breaker_open
          | :model_load_suppressed
          | :runtime_identity_mismatch
          | :dispatch_capacity_facts_unavailable

  @type snapshot :: %{
          model_id: Ecto.UUID.t(),
          decisions: %{CircuitBreakers.target() => Orchard.CircuitBreakers.Decision.t() | map()}
        }

  @doc """
  Reads the Node and load-required placement facts for a request candidate set atomically.
  """
  @spec snapshot([{Ecto.UUID.t(), boolean()}], ModelRef.t(), keyword()) ::
          {:ok, snapshot()} | {:error, reason_code()}
  def snapshot(candidates, %ModelRef{} = model_ref, opts \\ []) when is_list(candidates) do
    with {:ok, model_id} <- resolve_model_id(model_ref, opts),
         targets = snapshot_targets(candidates, model_id),
         {:ok, decisions} <- evaluate_many(targets, opts),
         true <- length(decisions) == length(targets) do
      {:ok, %{model_id: model_id, decisions: Map.new(Enum.zip(targets, decisions))}}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      _invalid -> {:error, :dispatch_capacity_facts_unavailable}
    end
  rescue
    _error -> {:error, :dispatch_capacity_facts_unavailable}
  catch
    _kind, _reason -> {:error, :dispatch_capacity_facts_unavailable}
  end

  @spec apply(Input.t(), Ecto.UUID.t() | nil, ModelRef.t(), boolean(), keyword()) ::
          {:ok, Input.t(), [reason_code()]} | {:error, reason_code()}
  def apply(%Input{} = input, node_id, %ModelRef{} = model_ref, load_required?, opts \\ []) do
    if production_managed?(input) do
      apply_managed(input, node_id, model_ref, load_required?, opts)
    else
      {:ok, input, []}
    end
  end

  @spec check_node(Ecto.UUID.t() | nil, keyword()) :: :ok | {:error, reason_code()}
  def check_node(nil, _opts), do: :ok

  def check_node(node_id, opts) do
    case evaluate({:node, node_id}, opts) do
      {:ok, %{state: :closed}} -> :ok
      {:ok, %{state: :open}} -> {:error, :node_circuit_breaker_open}
      {:error, reason} -> {:error, normalize_error(reason)}
      _invalid -> {:error, :dispatch_capacity_facts_unavailable}
    end
  rescue
    _error -> {:error, :dispatch_capacity_facts_unavailable}
  catch
    _kind, _reason -> {:error, :dispatch_capacity_facts_unavailable}
  end

  defp apply_managed(input, node_id, model_ref, load_required?, opts) do
    with {:ok, snapshot} <- breaker_snapshot(node_id, model_ref, load_required?, opts),
         {:ok, node_decision} <- Map.fetch(snapshot.decisions, {:node, node_id}),
         {:ok, eligible?, reason_codes} <-
           placement_decision(node_decision, node_id, snapshot, load_required?) do
      {:ok, %{input | breaker_eligible?: eligible?}, reason_codes}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  rescue
    _error -> {:error, :dispatch_capacity_facts_unavailable}
  catch
    _kind, _reason -> {:error, :dispatch_capacity_facts_unavailable}
  end

  defp production_managed?(%Input{management_classification: {:ok, :production_managed}}),
    do: true

  defp production_managed?(_input), do: false

  defp resolve_model_id(%ModelRef{model_id: model_id, version: version}, opts) do
    models = Keyword.get(opts, :circuit_breaker_models, Models)

    case models.get_model_by_identity(model_id, version) do
      %Model{id: id, state: state} when state in [:active, :deprecated] and is_binary(id) ->
        {:ok, id}

      %Model{} ->
        {:error, :model_not_active}

      nil ->
        {:error, :model_not_found}

      _invalid ->
        {:error, :invalid_model_identity}
    end
  end

  defp evaluate(target, opts) do
    evaluator = Keyword.get(opts, :circuit_breaker_evaluator, CircuitBreakers)
    evaluator.evaluate(target)
  end

  defp evaluate_many(targets, opts) do
    evaluator = Keyword.get(opts, :circuit_breaker_evaluator, CircuitBreakers)
    evaluator.evaluate_many(targets)
  end

  defp breaker_snapshot(node_id, model_ref, load_required?, opts) do
    case Keyword.fetch(opts, :circuit_breaker_snapshot) do
      {:ok, {:ok, snapshot}} -> {:ok, snapshot}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _invalid} -> {:error, :breaker_state_invalid}
      :error -> snapshot([{node_id, load_required?}], model_ref, opts)
    end
  end

  defp snapshot_targets(candidates, model_id) do
    candidates
    |> Enum.flat_map(fn
      {node_id, true} when is_binary(node_id) ->
        [{:node, node_id}, {:placement, node_id, model_id}]

      {node_id, false} when is_binary(node_id) ->
        [{:node, node_id}]

      _invalid ->
        []
    end)
    |> Enum.uniq()
  end

  defp placement_decision(%{state: :open}, _node_id, _snapshot, _load_required?),
    do: {:ok, false, [:node_circuit_breaker_open]}

  defp placement_decision(%{state: :closed}, _node_id, _snapshot, false),
    do: {:ok, true, []}

  defp placement_decision(%{state: :closed}, node_id, snapshot, true) do
    case Map.fetch(snapshot.decisions, {:placement, node_id, snapshot.model_id}) do
      {:ok, %{state: :open}} -> {:ok, false, [:model_load_suppressed]}
      {:ok, %{state: :closed}} -> {:ok, true, []}
      _missing_or_invalid -> {:error, :breaker_state_invalid}
    end
  end

  defp placement_decision(_invalid, _node_id, _snapshot, _load_required?),
    do: {:error, :breaker_state_invalid}

  defp normalize_error(reason) when reason in [:invalid_node_identity, :node_not_found],
    do: :runtime_identity_mismatch

  defp normalize_error(_reason), do: :dispatch_capacity_facts_unavailable
end
