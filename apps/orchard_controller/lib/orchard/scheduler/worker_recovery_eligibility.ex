defmodule Orchard.Scheduler.WorkerRecoveryEligibility do
  @moduledoc """
  Exact-placement admission evidence for SPEC §12.2, independent of §5.10 breakers.

  Status supplies `worker_recovery_epoch`; matching placements supply
  `worker_recovery`. The optional two-argument `worker_recovery_inspector`
  receives a target and runtime ModelRef and must return authenticated exact-key
  evidence without loading. Missing loaded evidence never falls back to inspection.
  """

  require Logger

  alias Orchard.Inference
  alias Orchard.RuntimeEndpoint.{ModelRef, Placement, Target, WorkerRecoveryEvidence}

  @unknown :worker_recovery_evidence_unavailable

  @doc "Validates a recovery projection against its current authenticated endpoint epoch."
  @spec evidence(term(), term()) :: :ok | {:error, atom()}
  def evidence(epoch, projection) when is_binary(epoch) and epoch != "" and is_map(projection) do
    with {:ok, evidence} <- WorkerRecoveryEvidence.validate(projection),
         ^epoch <- evidence.epoch,
         true <- evidence.hydrated do
      WorkerRecoveryEvidence.eligibility(evidence)
    else
      _invalid -> {:error, @unknown}
    end
  end

  def evidence(_epoch, _projection), do: {:error, @unknown}

  @doc "Checks an observation before ranking; only cold missing evidence may be inspected."
  @spec check(term(), map(), map(), keyword()) :: :ok | {:error, atom()}
  def check(target, observation, model_ref, opts \\ []) do
    epoch = value(observation, :worker_recovery_epoch)
    runtime_ref = ModelRef.new!(model_ref.model_id, model_ref.version)

    target = Target.normalize(target)
    node_id = target.node_id || value(value(observation, :metadata), :node_id)

    with true <- fresh?(observation),
         {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      target = %{target | node_id: node_id}

      case matching_placements(observation, runtime_ref) do
        [] -> inspect_evidence(target, runtime_ref, epoch, opts)
        [placement] -> placement_evidence(target, runtime_ref, epoch, placement, opts)
        _conflicting -> {:error, @unknown}
      end
    else
      _invalid -> {:error, @unknown}
    end
  catch
    :exit, _reason -> {:error, @unknown}
  end

  @doc "Recognizes only the structured no-execution refusal vocabulary."
  @spec refusal?(term()) :: boolean()
  def refusal?({:worker_recovery_refused, reason}) do
    match?({:ok, _reason}, WorkerRecoveryEvidence.refusal_reason(reason))
  end

  def refusal?(_reason), do: false

  defp matching_placements(observation, model_ref) do
    case value(observation, :placements) do
      placements when is_list(placements) ->
        Enum.filter(placements, &ModelRef.equal?(value(&1, :model_ref), model_ref))

      _invalid ->
        :invalid
    end
  end

  defp placement_evidence(target, model_ref, epoch, placement, opts) do
    case value(placement, :worker_recovery) do
      nil ->
        if Placement.loaded?(placement),
          do: {:error, @unknown},
          else: inspect_evidence(target, model_ref, epoch, opts)

      projection ->
        exact_evidence(target, model_ref, epoch, projection)
    end
  end

  defp inspect_evidence(target, model_ref, epoch, opts) when is_binary(epoch) and epoch != "" do
    inspector = Keyword.get(opts, :worker_recovery_inspector)

    result =
      if is_function(inspector, 2),
        do: inspector.(target, model_ref),
        else: inspect_endpoint(target, model_ref, opts)

    case result do
      {:ok, projection} -> exact_evidence(target, model_ref, epoch, projection)
      _unavailable -> {:error, @unknown}
    end
  end

  defp inspect_evidence(_target, _model_ref, _epoch, _opts), do: {:error, @unknown}

  defp inspect_endpoint(target, model_ref, opts) do
    client = Keyword.get(opts, :status_client, Inference.runtime_endpoint_client())

    if Code.ensure_loaded?(client) and function_exported?(client, :inspect_worker_recovery, 3) do
      with {:ok, channel} <- client.connect(target) do
        try do
          client.inspect_worker_recovery(
            channel,
            model_ref,
            timeout: Keyword.get(opts, :status_timeout_ms, 2_000)
          )
        after
          disconnect_best_effort(client, channel)
        end
      end
    else
      {:error, @unknown}
    end
  end

  defp exact_evidence(target, model_ref, epoch, projection) do
    key = value(projection, :key)

    if value(key, :node_id) == target.node_id and
         value(key, :model_id) == model_ref.model_id and
         value(key, :version) == model_ref.version do
      evidence(epoch, projection)
    else
      {:error, @unknown}
    end
  end

  defp disconnect_best_effort(client, channel) do
    client.disconnect(channel)
    :ok
  rescue
    error ->
      Logger.warning("Recovery inspection disconnect failed: #{inspect(error.__struct__)}")
      :ok
  catch
    _kind, _reason ->
      Logger.warning("Recovery inspection disconnect did not complete")
      :ok
  end

  defp fresh?(observation) do
    now = DateTime.utc_now()

    case value(observation, :observed_at) do
      %DateTime{} = observed_at ->
        age = DateTime.diff(now, observed_at, :millisecond)
        age >= 0 and age <= Inference.node_freshness_threshold_ms()

      _missing ->
        false
    end
  end

  defp value(map, key) when is_map(map) do
    case {Map.fetch(map, key), Map.fetch(map, Atom.to_string(key))} do
      {{:ok, value}, {:ok, value}} -> value
      {{:ok, _left}, {:ok, _right}} -> :conflicting
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      {:error, :error} -> nil
    end
  end

  defp value(_map, _key), do: nil
end
