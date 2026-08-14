defmodule Orchard.ManagedNodeAgent.LifecycleState do
  @moduledoc """
  Shared durable state vocabulary for managed Node Agent lifecycle operations.
  """

  @schema_version 1
  @operation_kinds ~w(handover managed_recovery start_attempt managed_stop)
  @terminal_phases ~w(terminal_coherent)
  @managed_stop_phases ~w(
    initial
    eligibility_suppressed
    suppression_proven
    process_observed
    unload_proven
    exit_proven
    terminal_coherent
    terminal_failed
  )

  @managed_stop_forbidden_fields [
    :staging_generation,
    :activation,
    :rollback,
    :start_policy,
    "staging_generation",
    "activation",
    "rollback",
    "start_policy"
  ]

  @type start_state :: %{
          required(:schema_version) => 1,
          required(:eligibility) => %{
            required(:state) => String.t(),
            required(:generation) => pos_integer()
          },
          required(:one_shot_authorization) => map() | nil
        }

  @spec operation_kinds() :: [String.t()]
  def operation_kinds, do: @operation_kinds

  @spec new_managed_stop(
          String.t(),
          map(),
          map(),
          map(),
          [map()],
          String.t()
        ) :: map()
  def new_managed_stop(operation_id, owner, service, observed, reconciles, timestamp) do
    %{
      schema_version: @schema_version,
      operation_id: operation_id,
      kind: "managed_stop",
      phase: "initial",
      owner_identity: owner,
      target_identity: %{
        launchd_domain: "system",
        label: service.label,
        plist_path: service.plist_path,
        active_support_root: "/Library/Application Support/Orchard",
        release_name: "orchard_node_agent",
        release_root: "/Library/Application Support/Orchard/releases/orchard_node_agent",
        release_launcher:
          "/Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent",
        executable_basename: "beam.smp"
      },
      observed_before: observed,
      intended_mutations: [
        "suppress_start_eligibility",
        "invalidate_one_shot_authorization",
        "disable_launchd_job_domain",
        "unload_launchd_job"
      ],
      reconciles: reconciles,
      proofs: %{},
      outcome: nil,
      failure: nil,
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  @spec advance(map(), String.t(), map(), String.t()) :: map()
  def advance(evidence, phase, proof, timestamp) do
    evidence
    |> Map.put(:phase, phase)
    |> Map.put(:updated_at, timestamp)
    |> Map.update(:proofs, proof, &Map.merge(&1, proof))
    |> put_terminal_fields(phase, proof)
  end

  @spec validate_evidence(map()) :: :ok | {:error, term()}
  def validate_evidence(evidence) when is_map(evidence) do
    with 1 <- field(evidence, :schema_version),
         kind when kind in @operation_kinds <- field(evidence, :kind),
         operation_id when is_binary(operation_id) <- field(evidence, :operation_id),
         phase when is_binary(phase) <- field(evidence, :phase),
         owner when is_map(owner) <- field(evidence, :owner_identity),
         target when is_map(target) <- field(evidence, :target_identity),
         observed when is_map(observed) <- field(evidence, :observed_before),
         intended when is_list(intended) <- field(evidence, :intended_mutations),
         :ok <- validate_kind_fields(kind, evidence),
         :ok <- validate_phase(kind, phase, evidence) do
      :ok
    else
      _invalid -> {:error, :invalid_evidence}
    end
  end

  def validate_evidence(_evidence), do: {:error, :invalid_evidence}

  @spec observed_eligibility({:ok, map()} | {:error, term()}) :: String.t() | map()
  def observed_eligibility({:ok, %{eligibility: %{state: state, generation: generation}}})
      when state in ["suppressed", "one_shot_pending", "enabled"] and
             is_integer(generation) and generation > 0 do
    %{"state" => state, "generation" => generation}
  end

  def observed_eligibility({:error, :missing}), do: "missing"
  def observed_eligibility(other), do: %{"unknown" => inspect(other)}

  @spec suppressed_state({:ok, map()} | {:error, term()}) :: start_state()
  def suppressed_state(prior) do
    %{
      schema_version: @schema_version,
      eligibility: %{state: "suppressed", generation: prior_generation(prior) + 1},
      one_shot_authorization: nil
    }
  end

  @spec suppressed?(map()) :: boolean()
  def suppressed?(%{
        schema_version: @schema_version,
        eligibility: %{state: "suppressed", generation: generation},
        one_shot_authorization: nil
      })
      when is_integer(generation) and generation > 0,
      do: true

  def suppressed?(_state), do: false

  @spec validate_start_state(map()) :: :ok | {:error, :invalid_start_state}
  def validate_start_state(%{
        schema_version: @schema_version,
        eligibility: %{state: state, generation: generation},
        one_shot_authorization: authorization
      })
      when state in ["suppressed", "one_shot_pending", "enabled"] and
             is_integer(generation) and generation > 0 and
             (is_map(authorization) or is_nil(authorization)) do
    if state == "suppressed" and not is_nil(authorization) do
      {:error, :invalid_start_state}
    else
      :ok
    end
  end

  def validate_start_state(_state), do: {:error, :invalid_start_state}

  @spec reconciliations([map()]) :: [map()]
  def reconciliations(records) do
    records
    |> Enum.reject(&terminal?/1)
    |> Enum.map(fn record ->
      reconciliation = %{
        operation_id: field(record, :operation_id),
        kind: field(record, :kind),
        phase: field(record, :phase),
        disposition: "supersedes_without_trust"
      }

      Enum.reduce([:filename, :sha256], reconciliation, &put_reference_field(record, &1, &2))
    end)
  end

  defp put_reference_field(record, key, reconciliation) do
    case field(record, key) do
      nil -> reconciliation
      value -> Map.put(reconciliation, key, value)
    end
  end

  @spec terminal?(map()) :: boolean()
  def terminal?(record) do
    validate_evidence(record) == :ok and field(record, :phase) in @terminal_phases
  end

  @spec denies_later_start?(map()) :: boolean()
  def denies_later_start?(record) do
    not (terminal?(record) and field(record, :kind) == "managed_stop" and
           field(record, :outcome) == "stopped")
  end

  defp prior_generation({:ok, %{eligibility: %{generation: generation}}})
       when is_integer(generation) and generation > 0,
       do: generation

  defp prior_generation(_prior), do: 0

  defp put_terminal_fields(evidence, "terminal_coherent", proof) do
    evidence
    |> Map.put(:outcome, Map.get(proof, :outcome, "stopped"))
    |> Map.put(:failure, nil)
  end

  defp put_terminal_fields(evidence, "terminal_failed", proof) do
    Map.put(evidence, :failure, Map.get(proof, :failure, "unknown"))
  end

  defp put_terminal_fields(evidence, _phase, _proof), do: evidence

  defp validate_kind_fields("managed_stop", evidence) do
    if Enum.any?(@managed_stop_forbidden_fields, &Map.has_key?(evidence, &1)) do
      {:error, :managed_stop_forbidden_field}
    else
      :ok
    end
  end

  defp validate_kind_fields(_kind, _evidence), do: :ok

  defp validate_phase("managed_stop", phase, evidence) when phase in @managed_stop_phases do
    if phase == "terminal_coherent", do: validate_terminal_proof(evidence), else: :ok
  end

  defp validate_phase("managed_stop", _phase, _evidence),
    do: {:error, :invalid_managed_stop_phase}

  defp validate_phase(_kind, _phase, _evidence), do: :ok

  defp validate_terminal_proof(evidence) do
    proofs = field(evidence, :proofs)

    if valid_stopped_proof?(evidence, proofs) do
      :ok
    else
      {:error, :invalid_terminal_proof}
    end
  end

  defp valid_stopped_proof?(evidence, proofs) when is_map(proofs) do
    generation = field(proofs, :suppression_generation)

    field(evidence, :outcome) == "stopped" and
      field(proofs, :persistent_disablement) == true and
      field(proofs, :job_unloaded) == true and
      is_integer(generation) and generation > 0 and
      (field(proofs, :affirmative_absence) == true or is_map(field(proofs, :captured_exit)))
  end

  defp valid_stopped_proof?(_evidence, _proofs), do: false

  defp field(record, key), do: Map.get(record, key) || Map.get(record, Atom.to_string(key))
end
