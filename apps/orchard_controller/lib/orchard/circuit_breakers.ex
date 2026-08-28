defmodule Orchard.CircuitBreakers do
  @moduledoc """
  Persistent Node and placement circuit breakers defined by `SPEC.md` section 5.10.

  Postgres owns failure identity, rolling-window evidence, serialization, clear
  watermarks, and suppression deadlines. The optional `:now` value is a
  deterministic decision-time seam; production callers omit it and use the
  database clock.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.UUID
  alias Orchard.CircuitBreakers.{Breaker, Decision, Failure}
  alias Orchard.ControlPlane
  alias Orchard.Governance.AuditWriter
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node
  alias Orchard.Repo

  @node_classes ~w(pre_acceptance_unavailable worker_or_node_loss)
  @placement_classes ~w(model_load_failure)

  @ineligible_classes ~w(
    capacity_rejection
    runtime_failure
    terminal_conformance
    cancellation
    deadline
    controller_failure
    occupancy_unresolved
    identity_unresolved
  )

  @policies %{
    node: %{window_seconds: 60, suppression_seconds: 300},
    placement: %{window_seconds: 600, suppression_seconds: 900}
  }

  @type target :: {:node, Ecto.UUID.t()} | {:placement, Ecto.UUID.t(), Ecto.UUID.t()}
  @type error ::
          :invalid_failure_identity
          | :invalid_node_identity
          | :node_not_found
          | :invalid_model_identity
          | :model_not_found
          | :model_not_active
          | :invalid_failure_class
          | :invalid_occurred_at
          | :failure_target_mismatch
          | :failure_identity_conflict
          | :breaker_state_invalid
          | :circuit_breaker_unavailable
          | :controller_standby
          | :controller_leadership_unproven
          | term()

  @doc """
  Records one stable eligible failure exactly once and returns its durable decision.

  Duplicate delivery with the same identity and payload is idempotent. Reuse of
  the identity for a different failure fails closed.
  """
  @spec record_failure(map(), keyword()) ::
          {:ok, Decision.t() | :not_eligible} | {:error, error()}
  def record_failure(attrs, opts \\ [])

  def record_failure(attrs, opts) when is_map(attrs) and is_list(opts) do
    domain_call(fn ->
      with :ok <- ControlPlane.authorize_write_path(:circuit_breaker),
           {:ok, normalized} <- normalize_failure(attrs) do
        record_normalized(normalized, opts)
      end
    end)
  end

  def record_failure(_attrs, _opts), do: {:error, :invalid_failure_identity}

  defp record_normalized(:not_eligible, _opts), do: {:ok, :not_eligible}

  defp record_normalized(failure, opts),
    do: transact(fn -> record_eligible(failure, opts) end)

  @doc """
  Evaluates whether a canonical Node or placement is currently suppressed.

  Expiry is lazy: a persisted open row whose deadline has passed is returned as
  closed immediately, and the next authorized mutation persists the transition.
  """
  @spec evaluate(target(), keyword()) :: {:ok, Decision.t()} | {:error, error()}
  def evaluate(target, opts \\ []) when is_list(opts) do
    domain_call(fn -> evaluate_target(target, opts) end)
  end

  defp evaluate_target(target, opts) do
    with {:ok, identity} <- normalize_target(target) do
      transact(fn -> evaluate_locked(identity, opts) end)
    end
  end

  @doc """
  Evaluates several canonical targets from one coherent database decision point.

  Target locks are acquired in canonical order so callers may supply targets in
  any order without introducing lock-order inversions. Results preserve the
  caller's input order.
  """
  @spec evaluate_many([target()], keyword()) :: {:ok, [Decision.t()]} | {:error, error()}
  def evaluate_many(targets, opts \\ []) when is_list(targets) and is_list(opts) do
    domain_call(fn -> evaluate_targets(targets, opts) end)
  end

  defp evaluate_targets(targets, opts) do
    with {:ok, identities} <- normalize_targets(targets) do
      transact(fn -> evaluate_many_locked(identities, opts) end)
    end
  end

  @doc """
  Inspects durable breaker history, including placements whose catalog Model was removed.
  """
  @spec inspect(target(), keyword()) :: {:ok, Decision.t()} | {:error, error()}
  def inspect(target, opts \\ []) when is_list(opts) do
    domain_call(fn -> inspect_target(target, opts) end)
  end

  defp inspect_target(target, opts) do
    with {:ok, identity} <- normalize_target(target) do
      transact(fn -> inspect_locked(identity, opts) end)
    end
  end

  @doc """
  Clears a breaker with a durable generation and time watermark.

  An `:audit` callback, when supplied, runs with the post-clear decision inside
  the same transaction. Any callback error rolls the clear back.
  """
  @spec clear(target(), keyword()) :: {:ok, Decision.t()} | {:error, error()}
  def clear(target, opts \\ []) when is_list(opts) do
    domain_call(fn -> clear_target(target, opts) end)
  end

  defp clear_target(target, opts) do
    with :ok <- ControlPlane.authorize_write_path(:circuit_breaker_clear),
         {:ok, identity} <- normalize_target(target) do
      transact(fn -> clear_locked(identity, opts) end)
    end
  end

  defp record_eligible(failure, opts) do
    identity = failure_identity(failure)
    lock_target(identity, opts)
    lock_failure(failure.failure_id, opts)

    case Repo.get(Failure, failure.failure_id) do
      nil -> insert_failure(failure, opts)
      existing -> duplicate_result(existing, failure, opts)
    end
  end

  defp insert_failure(failure, opts) do
    identity = failure_identity(failure)
    now = decision_time(opts)

    with :ok <- validate_occurrence(failure, now),
         :ok <- validate_target(identity),
         {:ok, breaker} <- get_or_create_breaker(identity),
         {:ok, breaker} <- persist_expiry(breaker, now),
         disposition = failure_disposition(breaker, failure),
         {:ok, persisted_failure} <- persist_failure(failure, breaker, now, disposition),
         {:ok, count} <- contribution_count(breaker, now),
         {:ok, breaker, changed?} <- maybe_open(breaker, count, now),
         transition = if(changed?, do: :opened, else: :none),
         {:ok, _persisted_failure} <- mark_transition(persisted_failure, transition),
         {:ok, decision} <-
           decision(breaker, now, changed?, :recorded,
             contribution_disposition: disposition,
             transition: transition
           ) do
      %{decision | contribution_count: count}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp duplicate_result(existing, failure, opts) do
    if same_failure?(existing, failure) do
      now = decision_time(opts)

      with :ok <- validate_occurrence(failure, now),
           {:ok, breaker} <- fetch_breaker_by_id(existing.breaker_id),
           true <- breaker_matches_failure?(breaker, existing) || {:error, :breaker_state_invalid},
           {:ok, result} <-
             decision(breaker, now, false, :duplicate,
               contribution_disposition: existing.disposition,
               transition: existing.transition
             ) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      Repo.rollback(:failure_identity_conflict)
    end
  end

  defp clear_locked(identity, opts) do
    lock_target(identity, opts)
    now = decision_time(opts)

    with :ok <- validate_target(identity),
         {:ok, breaker} <- get_or_create_breaker(identity),
         previous_state = effective_state(breaker, now),
         {:ok, breaker} <- persist_expiry(breaker, now),
         changed? = previous_state == :open,
         {:ok, breaker} <- persist_clear(breaker, changed?, now),
         {:ok, result} <- decision(breaker, now, changed?, nil, previous_state: previous_state),
         :ok <- audit_clear(Keyword.get(opts, :audit), result) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp evaluate_locked(identity, opts) do
    lock_target(identity, opts)
    now = decision_time(opts)

    case validate_target(identity) do
      :ok -> evaluate_fetched(identity, now)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp evaluate_many_locked(identities, opts) do
    identities
    |> Enum.uniq_by(&target_lock_key/1)
    |> Enum.sort_by(&target_lock_key/1)
    |> Enum.each(&lock_target(&1, opts))

    now = decision_time(opts)

    identities
    |> Enum.reduce_while([], fn identity, decisions ->
      case validate_target(identity) do
        :ok -> {:cont, [evaluate_fetched(identity, now) | decisions]}
        {:error, reason} -> {:halt, Repo.rollback(reason)}
      end
    end)
    |> Enum.reverse()
  end

  defp evaluate_fetched(identity, now) do
    case fetch_breaker(identity) do
      nil -> empty_decision(identity, now)
      breaker -> unwrap_or_rollback(decision(breaker, now, false, nil))
    end
  end

  defp inspect_locked(identity, opts) do
    lock_target(identity, opts)
    now = decision_time(opts)

    case validate_node(identity.node_id) do
      :ok -> inspect_fetched(identity, now)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp inspect_fetched(identity, now) do
    case fetch_breaker(identity) do
      nil -> inspect_empty(identity, now)
      breaker -> unwrap_or_rollback(decision(breaker, now, false, nil))
    end
  end

  defp inspect_empty(identity, now) do
    case validate_model(identity.kind, identity.model_id) do
      :ok -> empty_decision(identity, now)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_clear(nil, _decision), do: :ok
  defp audit_clear(callback, decision) when is_function(callback, 1), do: callback.(decision)
  defp audit_clear(_callback, _decision), do: {:error, :invalid_audit_callback}

  defp persist_clear(breaker, false, _now), do: {:ok, breaker}

  defp persist_clear(breaker, true, now) do
    breaker
    |> Ecto.Changeset.change(%{
      state: :closed,
      generation: breaker.generation + 1,
      opened_at: nil,
      suppressed_until: nil,
      last_cleared_at: now
    })
    |> Repo.update()
  end

  defp persist_failure(failure, breaker, now, disposition) do
    %Failure{}
    |> Failure.changeset(%{
      id: failure.failure_id,
      breaker_id: breaker.id,
      node_id: failure.node_id,
      model_id: failure.model_id,
      failure_class: failure.failure_class,
      occurred_at: failure.occurred_at,
      decision_at: now,
      disposition: disposition,
      transition: :none,
      generation: breaker.generation
    })
    |> Repo.insert()
  end

  defp mark_transition(failure, transition) do
    failure
    |> Ecto.Changeset.change(transition: transition)
    |> Repo.update()
  end

  defp failure_disposition(%Breaker{last_cleared_at: nil}, _failure), do: :contributed

  defp failure_disposition(%Breaker{last_cleared_at: cleared_at}, failure) do
    if DateTime.compare(failure.occurred_at, cleared_at) == :gt,
      do: :contributed,
      else: :fenced
  end

  defp contribution_count(breaker, now) do
    cutoff = DateTime.add(now, -policy(breaker).window_seconds, :second)

    count =
      Failure
      |> where([failure], failure.breaker_id == ^breaker.id)
      |> where([failure], failure.generation == ^breaker.generation)
      |> where([failure], failure.disposition == :contributed)
      |> where([failure], failure.decision_at > ^cutoff)
      |> where([failure], failure.decision_at <= ^now)
      |> after_clear_watermark(breaker.last_cleared_at)
      |> Repo.aggregate(:count)

    {:ok, count}
  end

  defp after_clear_watermark(query, nil), do: query

  defp after_clear_watermark(query, cleared_at),
    do: where(query, [failure], failure.occurred_at > ^cleared_at)

  defp maybe_open(%Breaker{state: :closed} = breaker, count, now) when count >= 3 do
    suppression_until = DateTime.add(now, policy(breaker).suppression_seconds, :second)

    breaker
    |> Ecto.Changeset.change(%{
      state: :open,
      opened_at: now,
      suppressed_until: suppression_until
    })
    |> Repo.update()
    |> case do
      {:ok, opened} -> {:ok, opened, true}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_open(breaker, _count, _now), do: {:ok, breaker, false}

  defp persist_expiry(%Breaker{} = breaker, now) do
    if breaker.state == :open and effective_state(breaker, now) == :closed do
      breaker
      |> Ecto.Changeset.change(state: :closed, opened_at: nil, suppressed_until: nil)
      |> Repo.update()
    else
      {:ok, breaker}
    end
  end

  defp decision(%Breaker{} = breaker, now, changed?, delivery, opts \\ []) do
    with {:ok, count} <- contribution_count(breaker, now),
         {:ok, state} <- validated_effective_state(breaker, now) do
      {:ok,
       %Decision{
         id: breaker.id,
         kind: breaker.kind,
         node_id: breaker.node_id,
         model_id: breaker.model_id,
         state: state,
         contribution_count: count,
         opened_at: if(state == :open, do: breaker.opened_at),
         suppressed_until: if(state == :open, do: breaker.suppressed_until),
         last_cleared_at: breaker.last_cleared_at,
         decision_at: now,
         previous_state: Keyword.get(opts, :previous_state),
         contribution_disposition: Keyword.get(opts, :contribution_disposition),
         transition: Keyword.get(opts, :transition),
         generation: breaker.generation,
         delivery: delivery,
         changed_state?: changed?
       }}
    end
  end

  defp empty_decision(identity, now) do
    %Decision{
      kind: identity.kind,
      node_id: identity.node_id,
      model_id: identity.model_id,
      state: :closed,
      contribution_count: 0,
      decision_at: now,
      transition: nil,
      generation: 0
    }
  end

  defp get_or_create_breaker(identity) do
    case fetch_breaker(identity) do
      nil ->
        %Breaker{}
        |> Breaker.create_changeset(%{
          kind: identity.kind,
          node_id: identity.node_id,
          model_id: identity.model_id,
          state: :closed,
          generation: 0
        })
        |> Repo.insert()

      breaker ->
        {:ok, breaker}
    end
  end

  defp fetch_breaker(%{kind: :node, node_id: node_id}),
    do: Repo.get_by(Breaker, kind: :node, node_id: node_id)

  defp fetch_breaker(%{kind: :placement, node_id: node_id, model_id: model_id}),
    do: Repo.get_by(Breaker, kind: :placement, node_id: node_id, model_id: model_id)

  defp fetch_breaker_by_id(id) do
    case Repo.get(Breaker, id) do
      nil -> {:error, :breaker_state_invalid}
      breaker -> {:ok, breaker}
    end
  end

  defp validate_target(%{node_id: node_id, kind: kind} = identity) do
    with :ok <- validate_node(node_id) do
      validate_model(kind, Map.get(identity, :model_id))
    end
  end

  defp validate_node(node_id) do
    case Repo.get(Node, node_id) do
      nil -> {:error, :node_not_found}
      %Node{} -> :ok
    end
  end

  defp validate_model(:node, nil), do: :ok

  defp validate_model(:placement, model_id) do
    case Repo.get(Model, model_id) do
      nil -> {:error, :model_not_found}
      %Model{state: state} when state in [:active, :deprecated] -> :ok
      %Model{} -> {:error, :model_not_active}
    end
  end

  defp normalize_failure(attrs) do
    failure_id = attr(attrs, :failure_id)
    node_id = attr(attrs, :node_id)
    model_id = attr(attrs, :model_id)
    failure_class = normalize_class(attr(attrs, :failure_class))
    occurred_at = attr(attrs, :occurred_at)

    with {:ok, failure_id} <- cast_uuid(failure_id, :invalid_failure_identity),
         {:ok, node_id} <- cast_uuid(node_id, :invalid_node_identity),
         {:ok, occurred_at} <- cast_time(occurred_at),
         {:ok, target} <- class_target(failure_class, model_id) do
      case target do
        :not_eligible ->
          {:ok, :not_eligible}

        {kind, model_id} ->
          {:ok,
           %{
             failure_id: failure_id,
             node_id: node_id,
             model_id: model_id,
             failure_class: failure_class,
             occurred_at: occurred_at,
             kind: kind
           }}
      end
    end
  end

  defp class_target(class, model_id) when class in @node_classes do
    if is_nil(model_id), do: {:ok, {:node, nil}}, else: {:error, :failure_target_mismatch}
  end

  defp class_target(class, model_id) when class in @placement_classes do
    with {:ok, model_id} <- cast_uuid(model_id, :invalid_model_identity) do
      {:ok, {:placement, model_id}}
    end
  end

  defp class_target(class, _model_id) when class in @ineligible_classes,
    do: {:ok, :not_eligible}

  defp class_target(_class, _model_id), do: {:error, :invalid_failure_class}

  defp normalize_target({:node, node_id}) do
    with {:ok, node_id} <- cast_uuid(node_id, :invalid_node_identity) do
      {:ok, %{kind: :node, node_id: node_id, model_id: nil}}
    end
  end

  defp normalize_target({:placement, node_id, model_id}) do
    with {:ok, node_id} <- cast_uuid(node_id, :invalid_node_identity),
         {:ok, model_id} <- cast_uuid(model_id, :invalid_model_identity) do
      {:ok, %{kind: :placement, node_id: node_id, model_id: model_id}}
    end
  end

  defp normalize_target(_target), do: {:error, :invalid_node_identity}

  defp normalize_targets(targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, identities} ->
      case normalize_target(target) do
        {:ok, identity} -> {:cont, {:ok, [identity | identities]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      error -> error
    end
  end

  defp failure_identity(%{kind: kind, node_id: node_id, model_id: model_id}),
    do: %{kind: kind, node_id: node_id, model_id: model_id}

  defp same_failure?(existing, failure) do
    existing.node_id == failure.node_id and existing.model_id == failure.model_id and
      existing.failure_class == failure.failure_class and
      DateTime.compare(existing.occurred_at, failure.occurred_at) == :eq
  end

  defp breaker_matches_failure?(breaker, failure) do
    breaker.node_id == failure.node_id and breaker.model_id == failure.model_id and
      breaker.generation >= failure.generation
  end

  defp validate_occurrence(failure, now) do
    if DateTime.compare(failure.occurred_at, now) == :gt,
      do: {:error, :invalid_occurred_at},
      else: :ok
  end

  defp validated_effective_state(%Breaker{state: state} = breaker, now)
       when state in [:open, :closed],
       do: {:ok, effective_state(breaker, now)}

  defp validated_effective_state(_breaker, _now), do: {:error, :breaker_state_invalid}

  defp effective_state(%Breaker{state: :open, suppressed_until: %DateTime{} = until}, now) do
    if DateTime.compare(until, now) == :gt, do: :open, else: :closed
  end

  defp effective_state(%Breaker{state: :closed}, _now), do: :closed
  defp effective_state(_breaker, _now), do: :closed

  defp policy(%Breaker{kind: kind}), do: Map.fetch!(@policies, kind)

  defp lock_failure(id, opts) do
    advisory_lock("failure:" <> id)
    notify_lock(opts, :failure)
  end

  defp lock_target(%{kind: kind, node_id: node_id, model_id: model_id}, opts) do
    advisory_lock(Enum.join([kind, node_id, model_id], ":"))
    notify_lock(opts, :target)
  end

  defp target_lock_key(%{kind: kind, node_id: node_id, model_id: model_id}),
    do: Enum.join([kind, node_id, model_id], ":")

  defp notify_lock(opts, lock_name) do
    case Keyword.get(opts, :test_lock_observer) do
      observer when is_function(observer, 1) -> observer.(lock_name)
      _observer -> :ok
    end
  end

  defp advisory_lock(key) do
    SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["orchard:circuit-breaker:" <> key]
    )

    :ok
  end

  defp decision_time(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} ->
        DateTime.truncate(now, :microsecond)

      _ ->
        %{rows: [[now]]} = SQL.query!(Repo, "SELECT clock_timestamp()", [])
        DateTime.truncate(now, :microsecond)
    end
  end

  defp transact(fun), do: AuditWriter.transaction(fun)

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp domain_call(fun) do
    fun.()
  rescue
    _exception in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      {:error, :circuit_breaker_unavailable}
  catch
    :exit, reason ->
      if database_exit?(reason),
        do: {:error, :circuit_breaker_unavailable},
        else: exit(reason)
  end

  defp database_exit?(%DBConnection.ConnectionError{}), do: true
  defp database_exit?(%DBConnection.OwnershipError{}), do: true
  defp database_exit?(%Postgrex.Error{}), do: true

  defp database_exit?(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.any?(&database_exit?/1)
  end

  defp database_exit?(reason) when is_list(reason), do: Enum.any?(reason, &database_exit?/1)
  defp database_exit?(_reason), do: false

  defp cast_uuid(value, error) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp cast_time(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :microsecond)}
  defp cast_time(_value), do: {:error, :invalid_occurred_at}

  defp normalize_class(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_class(value) when is_binary(value), do: value
  defp normalize_class(_value), do: nil

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
