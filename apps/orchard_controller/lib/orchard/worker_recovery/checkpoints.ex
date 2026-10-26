defmodule Orchard.WorkerRecovery.Checkpoints do
  @moduledoc """
  Transactional storage for Node-originated SPEC §12.2 checkpoints.

  The control adapter supplies the certificate from the completed mTLS exchange,
  never a certificate field from a request body. Transactions end before any
  Controller-to-Node operation is forwarded.
  """

  import Ecto.Query
  alias Orchard.{BeamPeerGrants, ControlPlane, Repo}
  alias Orchard.Models.Model
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint, as: Record
  alias Orchard.WorkerRecovery.Checkpoint

  @type result :: {:ok, map() | :absent} | {:error, term()}

  @spec read(Record.key(), binary()) :: result()
  def read(key, certificate), do: read_with(key, &authorize_peer(&1, certificate))

  @doc """
  Reads a checkpoint for the Node Agent running in this BEAM.

  All-in-one source development has no enrolled Node identity to present, and
  its Node Agent is part of this release, so the exact key is trusted as given.
  """
  @spec read_local(Record.key()) :: result()
  def read_local(key), do: read_with(key, &authorize_local/1)

  @spec commit(
          Record.key(),
          String.t() | nil,
          non_neg_integer(),
          String.t(),
          Record.t(),
          binary()
        ) :: result()
  def commit(key, expected_epoch, expected_revision, transition_id, record, certificate) do
    commit_with(
      key,
      {expected_epoch, expected_revision, transition_id, record},
      &authorize_peer(&1, certificate)
    )
  end

  @doc "Commits a checkpoint for the Node Agent running in this BEAM; see `read_local/1`."
  @spec commit_local(Record.key(), String.t() | nil, non_neg_integer(), String.t(), Record.t()) ::
          result()
  def commit_local(key, expected_epoch, expected_revision, transition_id, record) do
    commit_with(
      key,
      {expected_epoch, expected_revision, transition_id, record},
      &authorize_local/1
    )
  end

  defp read_with(key, authorize) do
    transact(key, authorize, fn node_id, model ->
      case locked_checkpoint(node_id, model) do
        nil -> :absent
        checkpoint -> projection(checkpoint)
      end
    end)
  end

  defp commit_with(key, {expected_epoch, expected_revision, transition_id, record}, authorize) do
    with :ok <- Record.validate(record),
         true <- Record.token?(transition_id),
         true <- is_integer(expected_revision) and expected_revision >= 0 do
      fingerprint = Record.fingerprint({expected_epoch, expected_revision, transition_id, record})

      transact(key, authorize, fn node_id, model ->
        checkpoint = locked_checkpoint(node_id, model)

        persist(
          checkpoint,
          node_id,
          model,
          expected_epoch,
          expected_revision,
          transition_id,
          fingerprint,
          record
        )
      end)
    else
      _invalid -> {:error, :invalid_checkpoint}
    end
  end

  defp transact(key, authorize, fun) do
    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle) do
      Repo.transaction(fn -> authorized(authorize.(key), fun) end)
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp authorized({:ok, node_id, model}, fun), do: fun.(node_id, model)
  defp authorized(:error, _fun), do: Repo.rollback(:unauthorized_checkpoint)

  defp authorize_peer(key, certificate) do
    with {:ok, peer} <- BeamPeerGrants.authenticated_peer_from_certificate(certificate),
         true <- peer.node_id == key.node_id,
         %Enrollment{state: :consumed, certificate_issuance_outcome: :issued} <-
           lock_enrollment(peer.enrollment_id),
         %Node{} = node <- lock_node(peer.node_id),
         true <- node.state in [:admitted, :active, :cordoned, :draining, :maintenance],
         %Model{} = model <- exact_model(key) do
      {:ok, node.id, model}
    else
      _invalid -> :error
    end
  end

  # No Node row need exist here, so a transaction-scoped advisory lock takes the
  # Node row lock's place in serializing insert-if-absent for this Node.
  defp authorize_local(key) do
    with {:ok, node_id} <- Ecto.UUID.cast(key.node_id),
         %Model{} = model <- exact_model(key) do
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["worker_recovery:" <> node_id])
      {:ok, node_id, model}
    else
      _invalid -> :error
    end
  end

  # The Node row serializes insert-if-absent as well as updates for this Node.
  defp lock_node(id), do: Repo.one(from(n in Node, where: n.id == ^id, lock: "FOR UPDATE"))

  defp lock_enrollment(id),
    do: Repo.one(from(e in Enrollment, where: e.id == ^id, lock: "FOR SHARE"))

  defp exact_model(key) do
    Repo.one(from(m in Model, where: m.model_id == ^key.model_id and m.version == ^key.version))
  end

  defp locked_checkpoint(node_id, model) do
    Repo.one(
      from(c in Checkpoint,
        where:
          c.node_id == ^node_id and c.runtime_model_id == ^model.model_id and
            c.version == ^model.version,
        lock: "FOR UPDATE"
      )
    )
  end

  defp persist(
         %Checkpoint{transition_id: id, fingerprint: fingerprint} = checkpoint,
         _node_id,
         _model_id,
         _epoch,
         _revision,
         id,
         fingerprint,
         _record
       ),
       do: projection(checkpoint)

  defp persist(
         %Checkpoint{transition_id: id},
         _node,
         _model,
         _epoch,
         _revision,
         id,
         _fingerprint,
         _record
       ),
       do: Repo.rollback(:stale_checkpoint)

  defp persist(nil, node_id, model, nil, 0, id, fingerprint, record) do
    %Checkpoint{
      node_id: node_id,
      model_id: model.id,
      runtime_model_id: model.model_id,
      version: model.version
    }
    |> write(1, id, fingerprint, record)
  end

  defp persist(
         %Checkpoint{epoch: epoch, revision: revision} = checkpoint,
         _node_id,
         _model_id,
         epoch,
         revision,
         id,
         fingerprint,
         record
       ) do
    if epoch == record["epoch"] or safe_epoch_claim?(checkpoint.record, record) do
      write(checkpoint, revision + 1, id, fingerprint, record)
    else
      Repo.rollback(:unresolved_epoch_claim)
    end
  end

  defp persist(_checkpoint, _node_id, _model_id, _epoch, _revision, _id, _fingerprint, _record),
    do: Repo.rollback(:stale_checkpoint)

  defp safe_epoch_claim?(previous, next) do
    Record.resolved?(next) and next["stable_since"] == nil and
      previous["crashes"] == next["crashes"] and
      previous["delay_index"] == next["delay_index"] and
      (Record.clean?(previous) or next["state"] in ["open", "recovery_required"]) and
      (previous["state"] != "open" or next["state"] == "open")
  end

  defp write(checkpoint, revision, id, fingerprint, record) do
    checkpoint
    |> Ecto.Changeset.change(%{
      epoch: record["epoch"],
      revision: revision,
      transition_id: id,
      fingerprint: fingerprint,
      record: record
    })
    |> Repo.insert_or_update!()
    |> projection()
  end

  defp projection(checkpoint) do
    %{
      epoch: checkpoint.epoch,
      revision: checkpoint.revision,
      transition_id: checkpoint.transition_id,
      record: checkpoint.record
    }
  end
end
