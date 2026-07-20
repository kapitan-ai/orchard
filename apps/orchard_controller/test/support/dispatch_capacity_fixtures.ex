defmodule Orchard.TestSupport.DispatchCapacityFixtures do
  @moduledoc false

  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input

  def record_authenticated_probe_evidence(response) do
    metadata = value(response, :node_metadata) || value(response, :metadata) || %{}
    node_id = value(metadata, :node_id)

    active =
      value(response, :active_request_count) || value(response, :aggregate_active_request_count)

    maximum = value(response, :max_concurrency) || value(response, :aggregate_max_concurrency)

    with {:ok, node_id} <- Ecto.UUID.cast(node_id),
         true <- is_integer(active) and active >= 0,
         true <- is_integer(maximum) and maximum > 0 do
      Orchard.DispatchCapacity.record_capacity_evidence(node_id, %{
        active_request_count: active,
        observed_at: DateTime.utc_now(),
        runtime_concurrency_limit: maximum,
        validity: :valid
      })
    else
      _incomplete -> :ok
    end
  end

  def authorize_unmanaged_schedule(schedule, opts \\ []) do
    input = unmanaged_input(opts)

    Map.merge(schedule, %{
      dispatch_capacity_input: input,
      dispatch_capacity_evaluation: Evaluator.evaluate(input),
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end
    })
  end

  def unmanaged_input(opts \\ []) do
    %Input{
      authority_phase: :invalid,
      policy_presence: :missing,
      policy_state: :missing,
      management_classification:
        {:ok, Keyword.get(opts, :management_class, :unmanaged_compatibility)},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: DateTime.utc_now(),
      runtime_concurrency_limit: {:valid, Keyword.get(opts, :runtime_concurrency_limit, 4)},
      aggregate_active_count: {:valid, Keyword.get(opts, :active_request_count, 0)},
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 0,
      placement_capacity: Keyword.get(opts, :placement_capacity, :not_applicable),
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
