defmodule Orchard.ClusterManagement.SchedulerExplanation do
  @moduledoc """
  Shared scheduler explanation contract with fixed candidate reason codes.
  """

  alias Orchard.ClusterManagement.{ReasonCodes, Value}

  @object "cluster_management.scheduler_explanation"
  @contract_version "orchard.cluster_management.scheduler_explanation.v1"

  defstruct object: @object,
            contract_version: @contract_version,
            request_id: nil,
            selected_node_id: nil,
            selection_tier: nil,
            scored_candidates: [],
            rejected_candidates: [],
            skipped_candidates: []

  @type t :: %__MODULE__{}

  @spec object() :: String.t()
  def object, do: @object

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, scored} <- candidates(value(attrs, :scored_candidates), :scored),
         {:ok, rejected} <- candidates(value(attrs, :rejected_candidates), :rejected),
         {:ok, skipped} <- candidates(value(attrs, :skipped_candidates), :skipped) do
      {:ok,
       %__MODULE__{
         request_id: Value.normalize_string(value(attrs, :request_id)),
         selected_node_id: Value.normalize_string(value(attrs, :selected_node_id)),
         selection_tier: Value.normalize_string(value(attrs, :selection_tier)),
         scored_candidates: scored,
         rejected_candidates: rejected,
         skipped_candidates: skipped
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, explanation} -> explanation
      {:error, reason} -> raise ArgumentError, "invalid scheduler explanation: #{inspect(reason)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = explanation) do
    %{
      object: explanation.object,
      contract_version: explanation.contract_version,
      request_id: explanation.request_id,
      selected_node_id: explanation.selected_node_id,
      selection_tier: explanation.selection_tier,
      scored_candidates: Enum.map(explanation.scored_candidates, &Value.json_value/1),
      rejected_candidates: Enum.map(explanation.rejected_candidates, &Value.json_value/1),
      skipped_candidates: Enum.map(explanation.skipped_candidates, &Value.json_value/1)
    }
  end

  @spec validate_map(map()) :: :ok | {:error, term()}
  def validate_map(map) when is_map(map) do
    case new(map) do
      {:ok, _explanation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_map(_map), do: {:error, :scheduler_explanation_must_be_map}

  defp candidates(nil, _kind), do: {:ok, []}

  defp candidates(candidates, kind) when is_list(candidates) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case candidate(candidate, kind) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp candidates(_candidates, kind), do: {:error, {:candidates_must_be_list, kind}}

  defp candidate(candidate, kind) when is_map(candidate) do
    with {:ok, reason_codes} <- reason_codes(candidate, kind) do
      {:ok,
       %{
         node_id: Value.normalize_string(map_value(candidate, :node_id)),
         target_ref: Value.normalize_string(map_value(candidate, :target_ref)),
         eligible: map_value(candidate, :eligible) == true,
         tier: Value.normalize_string(map_value(candidate, :tier)),
         score: map_value(candidate, :score),
         components: map_value_or_empty(map_value(candidate, :components)),
         diagnostics: map_value_or_empty(map_value(candidate, :diagnostics)),
         reason_codes: reason_codes
       }}
    end
  end

  defp candidate(_candidate, kind), do: {:error, {:candidate_must_be_map, kind}}

  defp reason_codes(candidate, :rejected) do
    validate_required_codes(
      candidate,
      :scheduler_rejection,
      :rejected_candidate_reason_codes_required
    )
  end

  defp reason_codes(candidate, :skipped) do
    validate_required_codes(candidate, :scheduler_skip, :skipped_candidate_reason_codes_required)
  end

  defp reason_codes(candidate, :scored) do
    ReasonCodes.validate_codes(:scheduler_rejection, map_value(candidate, :reason_codes))
  end

  defp validate_required_codes(candidate, vocabulary, empty_reason) do
    case ReasonCodes.validate_codes(vocabulary, map_value(candidate, :reason_codes)) do
      {:ok, []} -> {:error, empty_reason}
      other -> other
    end
  end

  defp map_value_or_empty(value) when is_map(value), do: value
  defp map_value_or_empty(_value), do: %{}

  defp value(attrs, key), do: map_value(attrs, key)

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
