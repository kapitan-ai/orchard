defmodule Orchard.DispatchCapacity do
  @moduledoc """
  Domain boundary for durable dispatch-capacity authority, policy, and evidence.

  The reads are open to any caller; the writing seams are deliberately narrow.
  `lock_authority/0` and `approve_admission_policy/1` exist only for the Node
  Admission transaction, `with_policy_mutation_gate/3` serializes a policy write
  against the dispatch handoff on the same Node, and `record_capacity_evidence/2`
  persists Node-owned runtime evidence that never becomes policy. This module
  exposes no transition to `enforcing`, for either the durable phase or a policy.
  """

  alias Orchard.DispatchCapacity.{AllocationAuthority, Authority, CapacityEvidence, Policy}
  alias Orchard.Repo

  import Ecto.Query, only: [from: 2]

  @policy_mutation_gate_timeout_ms 5_000

  @doc """
  Returns the singleton durable authority row, or `nil` if persistence is corrupt.
  """
  @spec get_authority() :: Authority.t() | nil
  def get_authority, do: Repo.one(Authority)

  @doc """
  Locks and returns the singleton authority row for an admission transaction.

  A transaction that locks both this row and Node or grant rows must take this
  lock first. Admission establishes that order and the later cutover slice
  inherits it; a caller that locks a Node first deadlocks against a concurrent
  admission.
  """
  @spec lock_authority() :: {:ok, Authority.t()} | {:error, :dispatch_capacity_authority_missing}
  def lock_authority do
    from(authority in Authority,
      where: authority.singleton == true,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
    |> case do
      %Authority{} = authority -> {:ok, authority}
      nil -> {:error, :dispatch_capacity_authority_missing}
    end
  end

  @doc """
  Returns one Node's durable dispatch-capacity policy when present.
  """
  @spec get_policy(Ecto.UUID.t()) :: Policy.t() | nil
  def get_policy(node_id), do: Repo.get(Policy, node_id)

  @doc """
  Returns one Node's current bounded aggregate runtime capacity evidence.
  """
  @spec get_capacity_evidence(Ecto.UUID.t()) :: CapacityEvidence.t() | nil
  def get_capacity_evidence(node_id), do: Repo.get(CapacityEvidence, node_id)

  @doc """
  Persists an explicit pre-cutover policy linked to its admission decision.
  """
  @spec approve_admission_policy(map()) ::
          {:ok, Policy.t()} | {:error, Ecto.Changeset.t()}
  def approve_admission_policy(attrs) do
    %Policy{}
    |> Policy.approved_explicit_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Runs a policy mutation while holding the target Node's acceptance gate.

  Dispatch holds the same gate until the Node accepts, so acquisition is
  bounded by `:gate_timeout_ms` and reported as
  `{:error, :dispatch_capacity_acceptance_gate_busy}` instead of blocking the
  caller for a whole request. An unavailable authority yields
  `{:error, :dispatch_capacity_authority_unavailable}`.
  """
  @spec with_policy_mutation_gate(Ecto.UUID.t(), (-> result), keyword()) ::
          result | {:error, AllocationAuthority.acceptance_gate_error()}
        when result: term()
  def with_policy_mutation_gate(node_id, fun, opts \\ []) when is_function(fun, 0) do
    authority = Keyword.get(opts, :authority, AllocationAuthority)
    timeout_ms = Keyword.get(opts, :gate_timeout_ms, @policy_mutation_gate_timeout_ms)

    case AllocationAuthority.try_acquire_acceptance_gate(authority, node_id, timeout_ms) do
      {:ok, lease} ->
        try do
          fun.()
        after
          AllocationAuthority.release_acceptance_gate(authority, lease)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Records the newest authenticated aggregate capacity evidence for one Node.

  Callers establish authenticated Node identity before crossing this seam.
  Older observations never replace newer evidence.
  """
  @spec record_capacity_evidence(Ecto.UUID.t(), map()) ::
          {:ok, CapacityEvidence.t()} | {:error, Ecto.Changeset.t()}
  def record_capacity_evidence(node_id, attrs) do
    attrs = normalize_capacity_evidence_attrs(node_id, attrs)

    with {:ok, _attempted_evidence} <-
           %CapacityEvidence{}
           |> CapacityEvidence.changeset(attrs)
           |> Repo.insert(
             conflict_target: [:node_id],
             on_conflict: capacity_evidence_conflict_update(),
             returning: true,
             allow_stale: true
           ) do
      {:ok, Repo.get!(CapacityEvidence, node_id)}
    end
  end

  defp normalize_capacity_evidence_attrs(node_id, attrs) do
    %{
      node_id: node_id,
      runtime_concurrency_limit: capacity_attr(attrs, :runtime_concurrency_limit),
      active_request_count: capacity_attr(attrs, :active_request_count),
      validity: capacity_attr(attrs, :validity),
      observed_at: capacity_attr(attrs, :observed_at)
    }
  end

  defp capacity_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp capacity_evidence_conflict_update do
    from(evidence in CapacityEvidence,
      where: evidence.observed_at < fragment("EXCLUDED.observed_at"),
      update: [
        set: [
          runtime_concurrency_limit: fragment("EXCLUDED.runtime_concurrency_limit"),
          active_request_count: fragment("EXCLUDED.active_request_count"),
          validity: fragment("EXCLUDED.validity"),
          observed_at: fragment("EXCLUDED.observed_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end
end
