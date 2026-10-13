defmodule Orchard.BeamDisconnectObligations do
  @moduledoc """
  Persists and reconciles forced-disconnect obligations for obsolete BEAM authority.
  """

  use GenServer

  import Ecto.Query

  alias Orchard.BeamDisconnectObligations.Obligation
  alias Orchard.BeamPeerGrants.Grant
  alias Orchard.NodeCredentials.Generation
  alias Orchard.Nodes.Node, as: NodeRecord
  alias Orchard.Repo
  alias Orchard.RuntimeEndpoint.{BeamPeerConnectionLock, ConnectionIncarnation, RevokedCookie}

  @default_interval_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec enqueue_in_transaction(Grant.t(), Ecto.UUID.t() | nil, String.t(), DateTime.t()) ::
          {:ok, Obligation.t()} | {:error, term()}
  def enqueue_in_transaction(%Grant{} = grant, credential_generation_id, reason, now)
      when is_binary(reason) do
    true = Repo.in_transaction?()

    attrs = %{
      node_id: grant.node_id,
      grant_id: grant.id,
      credential_generation_id: credential_generation_id,
      peer_beam_name: grant.node_beam_name,
      reason: reason,
      state: :pending,
      due_at: now,
      attempt_count: 0,
      evidence: %{"grant_generation" => grant.generation}
    }

    case open_obligation(grant.node_id, grant.id, reason) do
      %Obligation{} = obligation -> {:ok, obligation}
      nil -> %Obligation{} |> Obligation.changeset(attrs) |> Repo.insert()
    end
  end

  @spec list_open(Ecto.UUID.t()) :: [Obligation.t()]
  def list_open(node_id) do
    Obligation
    |> where([obligation], obligation.node_id == ^node_id)
    |> where([obligation], obligation.state in [:pending, :attempted])
    |> order_by([obligation], asc: obligation.due_at, asc: obligation.id)
    |> Repo.all()
  end

  @spec reconcile_once(keyword()) :: :ok | {:error, term()}
  def reconcile_once(opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    case expire_grants(now) do
      {:ok, _expired} ->
        due_obligations(now)
        |> Enum.each(&attempt_disconnect(&1, now, opts))

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      reconcile_opts: Keyword.take(opts, [:connected?, :disconnect, :now, :registry])
    }

    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    _result = reconcile_once(state.reconcile_opts)
    Process.send_after(self(), :reconcile, state.interval_ms)
    {:noreply, state}
  end

  defp expire_grants(now) do
    candidates =
      from(grant in Grant, as: :grant)
      |> where([grant], grant.state == :active and grant.expires_at <= ^now)
      |> or_where(
        [grant],
        grant.state == :active and
          exists(
            from(generation in Generation,
              where:
                generation.node_id == parent_as(:grant).node_id and
                  generation.state == :staged and
                  not is_nil(generation.overlap_ends_at) and generation.overlap_ends_at <= ^now,
              select: 1
            )
          )
      )
      |> order_by([grant], asc: grant.node_id, asc: grant.id)
      |> select([grant], %{id: grant.id, node_id: grant.node_id})
      |> Repo.all()

    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, expired} ->
      case expire_grant(candidate, now) do
        {:ok, nil} -> {:cont, {:ok, expired}}
        {:ok, grant} -> {:cont, {:ok, [grant | expired]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp expire_grant(candidate, now) do
    Repo.transaction(fn ->
      _node =
        NodeRecord
        |> where([node], node.id == ^candidate.node_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      grant =
        Grant
        |> where([grant], grant.id == ^candidate.id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      overlap_expired? = staged_overlap_expired?(candidate.node_id, now)
      grant_expired? = grant && DateTime.compare(grant.expires_at, now) != :gt
      expire_active_grant(grant, grant_expired?, overlap_expired?, now)
    end)
  end

  defp expire_active_grant(grant, grant_expired?, overlap_expired?, now) do
    if grant && grant.state == :active && (grant_expired? || overlap_expired?) do
      reason = if overlap_expired?, do: "credential_overlap_expired", else: "grant_expired"

      {:ok, expired} =
        grant
        |> Ecto.Changeset.change(
          state: :expired,
          revocation_evidence: %{"reason" => reason}
        )
        |> Repo.update()

      {:ok, _obligation} = enqueue_in_transaction(expired, nil, reason, now)
      expired
    end
  end

  defp staged_overlap_expired?(node_id, now) do
    Generation
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state == :staged)
    |> where([generation], not is_nil(generation.overlap_ends_at))
    |> where([generation], generation.overlap_ends_at <= ^now)
    |> Repo.exists?()
  end

  defp due_obligations(now) do
    Obligation
    |> where([obligation], obligation.state in [:pending, :attempted])
    |> where([obligation], obligation.due_at <= ^now)
    |> order_by([obligation], asc: obligation.due_at, asc: obligation.id)
    |> Repo.all()
  end

  defp attempt_disconnect(obligation, now, opts) do
    case existing_peer_atom(obligation.peer_beam_name) do
      {:ok, peer} -> disconnect_connected(obligation, peer, now, opts)
      {:error, :unknown_peer_atom} -> complete(obligation, now, "peer_atom_absent")
    end
  end

  defp disconnect_connected(obligation, peer, now, opts) do
    BeamPeerConnectionLock.transact(peer, fn ->
      registry = Keyword.get(opts, :registry, ConnectionIncarnation)
      _invalidated = safe_invalidate(registry, peer)
      cookie_setter = Keyword.get(opts, :cookie_setter, &Node.set_cookie/2)
      cookie_result = safe_call(cookie_setter, [peer, revoked_cookie(opts)])
      disconnect = Keyword.get(opts, :disconnect, &:erlang.disconnect_node/1)
      result = safe_call(disconnect, peer)

      if cookie_result == true and not connected?(peer, opts) do
        complete(obligation, now, "forced_disconnect_complete")
      else
        attempted(obligation, now, %{cookie: cookie_result, disconnect: result})
      end
    end)
  end

  defp revoked_cookie(opts) do
    case Keyword.fetch(opts, :revoked_cookie) do
      {:ok, cookie} when is_atom(cookie) -> cookie
      _other -> RevokedCookie.value()
    end
  end

  defp connected?(peer, opts) do
    Keyword.get(opts, :connected?, fn candidate -> candidate in Node.list(:connected) end).(peer)
  end

  defp complete(obligation, now, outcome) do
    obligation
    |> Obligation.changeset(%{
      state: :completed,
      last_attempt_at: now,
      attempt_count: obligation.attempt_count + 1,
      completed_at: now,
      evidence: Map.put(obligation.evidence, "outcome", outcome)
    })
    |> Repo.update()
  end

  defp attempted(obligation, now, result) do
    obligation
    |> Obligation.changeset(%{
      state: :attempted,
      last_attempt_at: now,
      attempt_count: obligation.attempt_count + 1,
      evidence: Map.put(obligation.evidence, "last_result", inspect(result, limit: 20))
    })
    |> Repo.update()
  end

  defp open_obligation(node_id, grant_id, reason) do
    Obligation
    |> where([obligation], obligation.node_id == ^node_id)
    |> where([obligation], obligation.grant_id == ^grant_id)
    |> where([obligation], obligation.reason == ^reason)
    |> where([obligation], obligation.state in [:pending, :attempted])
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp existing_peer_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :unknown_peer_atom}
  end

  defp safe_invalidate(registry, peer) do
    ConnectionIncarnation.invalidate(peer, :any, registry)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_call(fun, args) do
    apply(fun, List.wrap(args))
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end
end
