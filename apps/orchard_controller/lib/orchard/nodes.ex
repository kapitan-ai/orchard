defmodule Orchard.Nodes do
  @moduledoc """
  Persistence context for node inventory.

  Provides observational node discovery (no join ceremony) — nodes are
  automatically registered when a successful `GetStatus` response includes
  valid `RuntimeNodeMetadata`.
  """

  import Ecto.Query

  require Logger

  alias Orchard.Nodes.Node
  alias Orchard.Repo

  # -- Read APIs --

  @doc """
  Lists all nodes ordered by display_name, then id.

  Returns `[]` when the repo is unavailable.
  """
  @spec list_nodes() :: [Node.t()]
  def list_nodes do
    if repo_available?() do
      Node
      |> order_by([n], asc: n.display_name, asc: n.id)
      |> Repo.all()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns a summary of node counts grouped by state and health.

  All enum values are present, zero-filled when no rows exist.
  Returns a zero-filled summary when the repo is unavailable.
  """
  @spec summary() :: %{
          total: non_neg_integer(),
          by_state: %{required(atom()) => non_neg_integer()},
          by_health: %{required(atom()) => non_neg_integer()}
        }
  def summary do
    if repo_available?() do
      state_counts =
        Node
        |> group_by([n], n.state)
        |> select([n], {n.state, count(n.id)})
        |> Repo.all()
        |> Map.new()

      health_counts =
        Node
        |> group_by([n], n.health)
        |> select([n], {n.health, count(n.id)})
        |> Repo.all()
        |> Map.new()

      by_state = zero_fill(state_counts, Node.states())
      by_health = zero_fill(health_counts, Node.health_values())

      %{
        total: by_state |> Map.values() |> Enum.sum(),
        by_state: by_state,
        by_health: by_health
      }
    else
      empty_summary()
    end
  rescue
    _ -> empty_summary()
  end

  @doc """
  Fetches a node by ID. Raises on not found.
  """
  @spec get_node!(Ecto.UUID.t()) :: Node.t()
  def get_node!(id), do: Repo.get!(Node, id)

  @doc """
  Looks up a node by its advertise address and RPC port.

  Accepts a target keyword list matching the scheduler/dispatch shape:
  `[host: "127.0.0.1", port: 50071]`.

  Returns `nil` when no match, target is malformed, or repo is unavailable.
  """
  @spec lookup_by_target(keyword()) :: Node.t() | nil
  def lookup_by_target(target) do
    with true <- repo_available?(),
         {:ok, host, port} <- validate_target(target) do
      Node
      |> where([n], n.advertise_addr == ^host and n.rpc_port == ^port)
      |> Repo.one()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- Observational Write APIs --

  @doc """
  Observes a successful status response and persists the node.

  Normalizes metadata from a `StatusResponse` (or compatible map),
  resolves conflicts (identity, display_name, staleness), and inserts
  or updates the node row.

  New nodes are inserted with `state: :active`. Updates preserve the
  existing `state` (admin-managed).

  Returns:
  - `{:ok, %Node{}}` on insert or update
  - `:noop` when metadata is missing/invalid, repo unavailable,
    observation is stale, or an identity conflict is detected
  """
  @spec observe_status(keyword(), map() | struct(), DateTime.t()) ::
          {:ok, Node.t()} | :noop
  def observe_status(target, status_response, observed_at) do
    with true <- repo_available?(),
         {:ok, observation} <- normalize_observation(target, status_response, observed_at) do
      execute_observe(observation)
    else
      _ -> :noop
    end
  rescue
    _ -> :noop
  end

  @doc """
  Marks a node as unreachable by target address.

  Only updates health on an existing node. Does not insert new rows
  on failure-only observations. Preserves `state` and `last_heartbeat_at`.

  Returns:
  - `{:ok, %Node{}}` on successful mark
  - `:noop` when target is unknown, stale, malformed, or repo unavailable
  """
  @spec mark_target_unreachable(keyword(), DateTime.t()) :: {:ok, Node.t()} | :noop
  def mark_target_unreachable(target, observed_at) do
    with true <- repo_available?(),
         {:ok, host, port} <- validate_target(target) do
      execute_mark_unreachable(host, port, observed_at)
    else
      _ -> :noop
    end
  rescue
    _ -> :noop
  end

  # -- Observation Normalization --

  defp normalize_observation(target, status_response, observed_at) do
    metadata = extract_metadata(status_response)

    with {:metadata, %{} = meta} <- {:metadata, metadata},
         {:uuid, {:ok, node_id}} <- {:uuid, Ecto.UUID.cast(meta.node_id)},
         {:display_name, display_name} when display_name != nil <-
           {:display_name, resolve_display_name(meta)},
         {:port, port} when is_integer(port) and port in 1..65_535 <-
           {:port, resolve_port(meta, target)} do
      {:ok,
       %{
         id: node_id,
         display_name: display_name,
         hostname: non_empty_or(meta.hostname, target_host(target)),
         advertise_addr: non_empty_or(meta.listen_host, target_host(target)),
         rpc_port: port,
         health: derive_health(extract_runtime_health(status_response)),
         agent_version: non_empty_or(meta.agent_version, nil),
         capabilities: build_capabilities(meta),
         last_heartbeat_at: observed_at
       }}
    else
      _ -> :error
    end
  end

  defp extract_metadata(%{node_metadata: nil}), do: nil
  defp extract_metadata(%{node_metadata: meta}), do: meta
  defp extract_metadata(_), do: nil

  defp extract_runtime_health(%{runtime_health: health}), do: health
  defp extract_runtime_health(_), do: nil

  defp resolve_display_name(meta) do
    cond do
      non_empty?(meta.display_name) -> meta.display_name
      non_empty?(meta.hostname) -> meta.hostname
      true -> nil
    end
  end

  defp resolve_port(meta, target) do
    port = meta.listen_port

    cond do
      is_integer(port) and port in 1..65_535 -> port
      true -> target_port(target)
    end
  end

  defp derive_health(nil), do: :healthy

  defp derive_health(health) do
    ready = Map.get(health, :ready, true)
    code = Map.get(health, :health_code, "")
    message = Map.get(health, :health_message, "")

    cond do
      ready == false -> :unhealthy
      non_empty?(code) or non_empty?(message) -> :degraded
      true -> :healthy
    end
  end

  defp build_capabilities(meta) do
    backend = Map.get(meta, :worker_backend, "")
    if non_empty?(backend), do: %{"worker_backend" => backend}, else: %{}
  end

  # -- Transactional Observe --

  defp execute_observe(observation) do
    Repo.transaction(fn ->
      # Lock all potentially conflicting rows in one query
      conflicting =
        Node
        |> where(
          [n],
          n.id == ^observation.id or
            n.display_name == ^observation.display_name or
            (n.advertise_addr == ^observation.advertise_addr and
               n.rpc_port == ^observation.rpc_port)
        )
        |> lock("FOR UPDATE")
        |> Repo.all()

      existing_by_id = Enum.find(conflicting, &(&1.id == observation.id))
      existing_by_target = Enum.find(conflicting, &target_match?(&1, observation))
      existing_by_name = Enum.find(conflicting, &(&1.display_name == observation.display_name))

      cond do
        # Identity conflict: same target, different UUID
        existing_by_target != nil and existing_by_target.id != observation.id ->
          Logger.warning(
            "Node identity conflict: target #{observation.advertise_addr}:#{observation.rpc_port} " <>
              "claimed by #{observation.id} but registered to #{existing_by_target.id}"
          )

          Repo.rollback(:identity_conflict)

        # Identity conflict: same display_name, different UUID
        existing_by_name != nil and existing_by_name.id != observation.id ->
          Logger.warning(
            "Node identity conflict: display_name #{inspect(observation.display_name)} " <>
              "claimed by #{observation.id} but registered to #{existing_by_name.id}"
          )

          Repo.rollback(:identity_conflict)

        # Stale observation: existing row has fresher or equal heartbeat
        existing_by_id != nil and
          existing_by_id.last_heartbeat_at != nil and
            DateTime.compare(existing_by_id.last_heartbeat_at, observation.last_heartbeat_at) !=
              :lt ->
          Repo.rollback(:stale)

        # Update existing node: preserve admin-managed state
        existing_by_id != nil ->
          existing_by_id
          |> Node.changeset(
            observation
            |> Map.delete(:id)
            |> Map.put(:state, existing_by_id.state)
          )
          |> Repo.update!()

        # Insert new node as :active
        true ->
          %Node{}
          |> Node.changeset(Map.put(observation, :state, :active))
          |> Repo.insert!()
      end
    end)
    |> case do
      {:ok, node} -> {:ok, node}
      {:error, :identity_conflict} -> :noop
      {:error, :stale} -> :noop
    end
  rescue
    # Concurrent first-observation race: two transactions see no existing
    # rows, both attempt insert, one hits a uniqueness constraint.
    # Treat as a benign conflict — the other process won the insert.
    error in Ecto.ConstraintError ->
      Logger.debug("Node observation lost concurrent insert race: #{inspect(error.constraint)}")
      :noop
  end

  defp target_match?(node, observation) do
    node.advertise_addr == observation.advertise_addr and
      node.rpc_port == observation.rpc_port
  end

  # -- Mark Unreachable --

  defp execute_mark_unreachable(host, port, observed_at) do
    node =
      Node
      |> where([n], n.advertise_addr == ^host and n.rpc_port == ^port)
      |> Repo.one()

    case node do
      nil ->
        :noop

      %Node{last_heartbeat_at: last_hb} when last_hb != nil ->
        if DateTime.compare(last_hb, observed_at) == :lt do
          do_mark_unreachable(node)
        else
          :noop
        end

      %Node{} ->
        do_mark_unreachable(node)
    end
  end

  defp do_mark_unreachable(node) do
    updated =
      node
      |> Ecto.Changeset.change(health: :unreachable)
      |> Repo.update!()

    {:ok, updated}
  end

  # -- Helpers --

  defp repo_available? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end

  defp validate_target(target) do
    host = Keyword.get(target, :host)
    port = Keyword.get(target, :port)

    if is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 do
      {:ok, host, port}
    else
      :error
    end
  end

  defp target_host(target), do: Keyword.get(target, :host, "")
  defp target_port(target), do: Keyword.get(target, :port)

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp non_empty_or(value, fallback), do: if(non_empty?(value), do: value, else: fallback)

  defp zero_fill(counts, values) do
    Map.new(values, fn v -> {v, Map.get(counts, v, 0)} end)
  end

  defp empty_summary do
    %{
      total: 0,
      by_state: zero_fill(%{}, Node.states()),
      by_health: zero_fill(%{}, Node.health_values())
    }
  end
end
