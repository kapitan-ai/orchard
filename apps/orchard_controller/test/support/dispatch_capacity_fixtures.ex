defmodule Orchard.TestSupport.DispatchCapacityFixtures do
  @moduledoc false

  alias Orchard.Cluster.V1.{RuntimeNodeMetadata, StatusResponse}
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input

  @probe_node_id_key {__MODULE__, :probe_node_id}

  def put_probe_node_id(node_id), do: :persistent_term.put(@probe_node_id_key, node_id)

  def clear_probe_node_id, do: :persistent_term.erase(@probe_node_id_key)

  @doc """
  Builds the status response a claimed managed Node reports for its dispatch probe.

  Dispatch binds a live claim to the probed Node identity, so a stub standing in
  for a claimed Node must report that identity the way a real node agent does.
  """
  def probe_status_response do
    case :persistent_term.get(@probe_node_id_key, nil) do
      nil ->
        %StatusResponse{}

      node_id ->
        %StatusResponse{
          node_metadata: %RuntimeNodeMetadata{
            node_id: node_id,
            display_name: "dispatch-claim-probe",
            hostname: "dispatch-claim-probe.local",
            agent_version: "test",
            listen_host: "127.0.0.1",
            listen_port: 50_071,
            worker_backend: "mlx"
          }
        }
    end
  end

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
