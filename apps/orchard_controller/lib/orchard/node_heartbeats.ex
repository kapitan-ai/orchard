defmodule Orchard.NodeHeartbeats do
  @moduledoc """
  Persistence context for trusted Runtime Endpoint heartbeat history.
  """

  import Ecto.Query

  alias Orchard.ControlPlane
  alias Orchard.NodeHeartbeats.{CandidateSnapshot, Payload}
  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.Repo
  alias Orchard.RuntimeEndpoint.Target

  @retention_seconds 7 * 24 * 60 * 60
  @retention_batch_size 1_000

  @doc """
  Reads one immutable production candidate snapshot for a scheduling attempt.

  The caller supplies the effective normalized targets and the successful
  certificate-backed active inventory resolution. Database or incomplete-read
  failure returns `{:error, :candidate_snapshot_unavailable}` with no partial result.
  """
  @spec production_candidate_snapshot([Target.t()], [Target.t()], keyword()) ::
          {:ok, CandidateSnapshot.t()} | {:error, CandidateSnapshot.error()}
  def production_candidate_snapshot(effective_targets, active_targets, opts \\ []) do
    CandidateSnapshot.read(effective_targets, active_targets, opts)
  catch
    :error, _reason -> {:error, :candidate_snapshot_unavailable}
    :exit, _reason -> {:error, :candidate_snapshot_unavailable}
  end

  @doc """
  Appends one authenticated, normalized heartbeat inside its owning Node transaction.

  This internal persistence seam is leader-authorized, requires an existing Repo
  transaction, and rejects target identity that does not exactly name the Node.
  """
  @spec append(Node.t(), Target.t(), map() | struct(), DateTime.t()) ::
          {:ok, NodeHeartbeat.t()} | {:error, term()}
  def append(%Node{} = node, %Target{} = target, observation, %DateTime{} = observed_at) do
    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         :ok <- require_transaction(),
         {:ok, target} <- matching_target(target, node) do
      payload = Payload.build(target, observation)

      %NodeHeartbeat{}
      |> NodeHeartbeat.changeset(%{
        node_id: node.id,
        observed_at: observed_at,
        health: node.health,
        active_requests: active_requests(observation),
        payload: payload
      })
      |> Repo.insert()
    end
  end

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :heartbeat_transaction_required}
  end

  defp matching_target(target, node) do
    normalized = Target.normalize(target)

    if normalized.node_id == node.id do
      {:ok, normalized}
    else
      {:error, :heartbeat_target_identity_mismatch}
    end
  rescue
    _error in ArgumentError -> {:error, :heartbeat_target_identity_mismatch}
  end

  defp active_requests(observation) when is_map(observation) do
    value =
      Map.get(observation, :aggregate_active_request_count) ||
        Map.get(observation, "aggregate_active_request_count") ||
        Map.get(observation, :active_request_count) ||
        Map.get(observation, "active_request_count")

    if is_integer(value) and value in 0..4_294_967_295, do: value, else: 0
  end

  @doc """
  Deletes up to 1,000 oldest heartbeat rows beyond the seven-day SPEC §8.5 bound.
  """
  @spec prune_expired(DateTime.t()) :: {:ok, non_neg_integer()} | :noop
  def prune_expired(now \\ DateTime.utc_now()) do
    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         true <- is_struct(now, DateTime) do
      cutoff = DateTime.add(now, -@retention_seconds, :second)

      expired_ids =
        NodeHeartbeat
        |> where([heartbeat], heartbeat.observed_at < ^cutoff)
        |> order_by([heartbeat], asc: heartbeat.observed_at, asc: heartbeat.id)
        |> limit(@retention_batch_size)
        |> select([heartbeat], heartbeat.id)

      {deleted, _rows} =
        NodeHeartbeat
        |> where([heartbeat], heartbeat.id in subquery(expired_ids))
        |> Repo.delete_all()

      {:ok, deleted}
    else
      _reason -> :noop
    end
  end
end
