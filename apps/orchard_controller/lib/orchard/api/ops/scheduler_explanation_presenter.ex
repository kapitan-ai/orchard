defmodule Orchard.API.Ops.SchedulerExplanationPresenter do
  @moduledoc """
  Operator API projection for persisted scheduler explanations.
  """

  alias Orchard.ClusterManagement.SchedulerExplanation
  alias Orchard.Requests.Request

  @spec show(Request.t()) :: {:ok, map()} | {:error, term()}
  def show(%Request{public_id: public_id, scheduler_decision: decision}) when is_map(decision) do
    if scheduler_explanation?(decision) do
      decision
      |> Map.put_new("request_id", public_id)
      |> Map.put_new("selected_node_id", Map.get(decision, "node_id"))
      |> Map.put_new("selection_tier", Map.get(decision, "selected_tier"))
      |> SchedulerExplanation.new()
      |> case do
        {:ok, explanation} -> {:ok, api_map(explanation)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :scheduler_explanation_not_found}
    end
  end

  def show(%Request{}), do: {:error, :scheduler_explanation_not_found}

  defp scheduler_explanation?(decision) do
    Enum.any?(
      [
        :scored_candidates,
        "scored_candidates",
        :rejected_candidates,
        "rejected_candidates",
        :skipped_candidates,
        "skipped_candidates"
      ],
      &Map.has_key?(decision, &1)
    )
  end

  defp api_map(%SchedulerExplanation{} = explanation) do
    explanation
    |> SchedulerExplanation.to_map()
    |> Map.drop([:object, :contract_version])
  end
end
