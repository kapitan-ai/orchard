defmodule Orchard.DispatchCapacity.Diagnostics do
  @moduledoc """
  Read-only counterfactual diagnostics for the dispatch-capacity contract.

  This module assembles Controller-owned facts for the pure evaluator. It does
  not reserve capacity, mutate queue state, or authorize dispatch.

  Because it is observability rather than authorization, a failed durable read
  is logged and degraded to a missing fact instead of raised: an operator
  surface must still render while Postgres is unavailable. A snapshot therefore
  reports what the evaluator decided from the facts that could be read, which
  fail closed, and never proves the underlying evidence was reachable.
  """

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.{Authorization, CapacityEvidence, Policy}
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.ManagementClassifier
  alias Orchard.DispatchCapacity.ManagementClassifier.Input, as: ClassificationInput
  alias Orchard.Nodes.Node
  alias Orchard.Repo
  import Ecto.Query, only: [from: 2]

  require Logger

  @admitted_states [:admitted, :active, :cordoned, :draining, :maintenance, :decommissioning]

  defmodule Snapshot do
    @moduledoc "Typed read-only wrapper around one complete counterfactual evaluation."

    @enforce_keys [:counterfactual?, :consumers_ready?, :evaluation]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            counterfactual?: true,
            consumers_ready?: false,
            evaluation: Orchard.DispatchCapacity.Evaluator.Result.t()
          }

    @doc "Converts the snapshot to the shared operator status representation."
    @spec to_map(t()) :: map()
    def to_map(%__MODULE__{} = snapshot) do
      snapshot.evaluation
      |> Map.from_struct()
      |> Map.update!(:placement_capacity, &placement_to_map/1)
      |> Map.put(:mode, :counterfactual)
      |> Map.put(:counterfactual, snapshot.counterfactual?)
      |> Map.put(:consumers_ready, snapshot.consumers_ready?)
      |> Map.put(:eligible, snapshot.evaluation.eligible?)
      |> Map.delete(:eligible?)
    end

    defp placement_to_map({:valid, active, maximum}) do
      %{status: :valid, active_request_count: active, max_concurrency: maximum}
    end

    defp placement_to_map(value), do: value
  end

  @doc "Builds one diagnostic snapshot without changing dispatch authorization state."
  @spec snapshot(map(), keyword()) :: Snapshot.t()
  def snapshot(node, opts \\ []) when is_map(node) do
    authority =
      option(opts, :authority, fn ->
        safe_read(nil, "the dispatch-capacity authority", &DispatchCapacity.get_authority/0)
      end)

    policy =
      option(opts, :policy, fn ->
        safe_read(nil, "the Node dispatch-capacity policy", fn ->
          DispatchCapacity.get_policy(field(node, :id))
        end)
      end)

    evidence =
      option(opts, :evidence, fn ->
        safe_read(nil, "Node runtime capacity evidence", fn ->
          DispatchCapacity.get_capacity_evidence(field(node, :id))
        end)
      end)

    now = Keyword.get_lazy(opts, :now, &utc_now/0)
    freshness_threshold_ms = Keyword.get(opts, :freshness_threshold_ms, freshness_threshold_ms())

    evaluation_opts =
      opts
      |> Keyword.put(:now, now)
      |> Keyword.put(:freshness_threshold_ms, freshness_threshold_ms)
      |> Keyword.put(:management_classification, management_classification(node, opts))
      |> Keyword.put_new(:controller_accounted_allocation, :missing)

    evaluation =
      node
      |> diagnostic_node()
      |> Authorization.from_facts(authority, policy, evidence, evaluation_opts)
      |> Evaluator.evaluate()

    %Snapshot{counterfactual?: true, consumers_ready?: false, evaluation: evaluation}
  end

  @doc "Builds snapshots for a Node list with one bounded read per durable fact type."
  @spec snapshots([map()], keyword()) :: %{term() => Snapshot.t()}
  def snapshots(nodes, opts \\ []) when is_list(nodes) do
    node_ids = nodes |> Enum.map(&field(&1, :id)) |> Enum.reject(&is_nil/1)

    authority =
      option(opts, :authority, fn ->
        safe_read(nil, "the dispatch-capacity authority", &DispatchCapacity.get_authority/0)
      end)

    policies = policies_by_node(node_ids, opts)
    evidence = evidence_by_node(node_ids, opts)
    now = Keyword.get_lazy(opts, :now, &utc_now/0)

    Map.new(nodes, fn node ->
      node_id = field(node, :id)

      snapshot_opts =
        opts
        |> Keyword.put(:authority, authority)
        |> Keyword.put(:policy, Map.get(policies, node_id))
        |> Keyword.put(:evidence, Map.get(evidence, node_id))
        |> Keyword.put(:now, now)

      {node_id, snapshot(node, snapshot_opts)}
    end)
  end

  defp management_classification(node, opts) do
    option(opts, :management_classification, fn ->
      %ClassificationInput{
        target_reference: field(node, :id),
        inventory_resolution: inventory_resolution(node),
        controller_mode: Keyword.get(opts, :controller_mode, :production),
        declared_classes: Keyword.get(opts, :declared_classes, []),
        compatibility_enabled?: Keyword.get(opts, :compatibility_enabled?, false)
      }
      |> ManagementClassifier.classify()
    end)
  end

  defp inventory_resolution(node) do
    if field(node, :state) in @admitted_states, do: :admitted, else: :not_admitted
  end

  defp diagnostic_node(%Node{} = node), do: node

  defp diagnostic_node(node) do
    %Node{
      id: field(node, :id),
      state: field(node, :state),
      health: field(node, :health),
      last_heartbeat_at: field(node, :last_heartbeat_at)
    }
  end

  defp freshness_threshold_ms, do: Orchard.Inference.node_freshness_threshold_ms()

  defp policies_by_node(node_ids, opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, %Policy{node_id: node_id} = policy} -> %{node_id => policy}
      {:ok, _policy} -> %{}
      :error -> read_rows_by_node(Policy, "Node dispatch-capacity policies", node_ids)
    end
  end

  defp evidence_by_node(node_ids, opts) do
    case Keyword.fetch(opts, :evidence) do
      {:ok, %CapacityEvidence{node_id: node_id} = evidence} ->
        %{node_id => evidence}

      {:ok, _evidence} ->
        %{}

      :error ->
        read_rows_by_node(CapacityEvidence, "Node runtime capacity evidence", node_ids)
    end
  end

  defp read_rows_by_node(queryable, source, node_ids) do
    node_ids = Enum.filter(node_ids, &valid_uuid?/1)

    case node_ids do
      [] ->
        %{}

      ids ->
        safe_read(%{}, source, fn ->
          queryable |> where_node_id_in(ids) |> Repo.all() |> index_by_node()
        end)
    end
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp where_node_id_in(queryable, node_ids) do
    from(row in queryable, where: row.node_id in ^node_ids)
  end

  defp index_by_node(rows), do: Map.new(rows, &{&1.node_id, &1})

  defp option(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default.()
    end
  end

  defp safe_read(fallback, source, fun) do
    fun.()
  rescue
    exception ->
      log_read_fallback(source, :error, exception, __STACKTRACE__)
      fallback
  catch
    kind, reason ->
      log_read_fallback(source, kind, reason, __STACKTRACE__)
      fallback
  end

  defp log_read_fallback(source, kind, reason, stacktrace) do
    Logger.warning(fn ->
      "dispatch-capacity diagnostics could not read #{source} and fell back to fail-closed " <>
        "facts: " <> Exception.format(kind, reason, stacktrace)
    end)
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
