defmodule Orchard.Requests do
  @moduledoc """
  Persistence context for durable request rows and lifecycle events.
  """

  import Ecto.Query

  alias Orchard.Repo
  alias Orchard.Requests.{Request, RequestEvent}

  @spec create_request(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_request(attrs) do
    %Request{}
    |> Request.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec get_request!(Ecto.UUID.t()) :: struct()
  def get_request!(id), do: Repo.get!(Request, id)

  @spec get_request_by_public_id(String.t()) :: struct() | nil
  def get_request_by_public_id(public_id) do
    Request
    |> where([r], r.public_id == ^public_id)
    |> preload([:retry_of_request, :tenant, :api_key])
    |> Repo.one()
  end

  @spec get_request_by_tenant_and_idempotency_key(Ecto.UUID.t(), String.t()) :: struct() | nil
  def get_request_by_tenant_and_idempotency_key(tenant_id, idempotency_key) do
    Request
    |> where([r], r.tenant_id == ^tenant_id and r.idempotency_key == ^idempotency_key)
    |> Repo.one()
  end

  @spec list_request_events(struct() | Ecto.UUID.t()) :: [struct()]
  def list_request_events(%Request{id: request_id}), do: list_request_events(request_id)

  def list_request_events(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> order_by([event], asc: event.seq)
    |> Repo.all()
  end

  @spec append_request_event(struct() | Ecto.UUID.t(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def append_request_event(%Request{id: request_id}, attrs),
    do: append_request_event(request_id, attrs)

  def append_request_event(request_id, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          insert_event_and_sync_state(request, request_id, attrs)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp insert_event_and_sync_state(request, request_id, attrs) do
    event_attrs =
      attrs
      |> normalize_request_event_attrs()
      |> Map.put("request_id", request_id)
      |> Map.put("seq", next_request_event_seq(request_id))
      |> default_occurred_at()

    # Atomically advance requests.state when the event carries a
    # state value. This keeps the row in sync with events for
    # active-state queries and index correctness (P1 review fix).
    sync_request_state(request, event_attrs, attrs)

    %RequestEvent{}
    |> RequestEvent.changeset(event_attrs)
    |> Repo.insert()
  end

  defp sync_request_state(request, event_attrs, raw_attrs) do
    new_state = Map.get(event_attrs, "state") || Map.get(raw_attrs, :state)

    if new_state && new_state != request.state do
      request
      |> Ecto.Changeset.change(state: new_state)
      |> Repo.update!()
    end
  end

  @spec mark_terminal(struct(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :already_terminal | :request_not_found}
  def mark_terminal(%Request{id: request_id}, attrs) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, current_request} ->
          apply_terminal_update(current_request, attrs)

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp apply_terminal_update(%Request{} = request, attrs) do
    # Allow idempotent terminal updates: if the row is already in a terminal
    # state (set by append_request_event's atomic state sync), still apply
    # the terminal metadata (usage, timestamps, error fields). Only reject
    # if this would overwrite a *different* terminal state.
    target_state = Map.get(attrs, :state) || Map.get(attrs, "state")

    cond do
      request.state not in Request.terminal_states() ->
        request |> Request.terminal_changeset(attrs) |> Repo.update()

      target_state != nil and request.state == target_state ->
        # Same terminal state — apply metadata update idempotently
        request |> Request.terminal_changeset(attrs) |> Repo.update()

      true ->
        Repo.rollback(:already_terminal)
    end
  end

  @doc """
  Persists the scheduler decision onto the request row.

  Sets `scheduler_decision` (normalized to JSON-safe map) and optionally
  sets `node_id` when the schedule contains a non-nil UUID.
  """
  @spec record_schedule(struct() | Ecto.UUID.t(), map()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def record_schedule(%Request{id: request_id}, schedule),
    do: record_schedule(request_id, schedule)

  def record_schedule(request_id, schedule) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          attrs = %{
            scheduler_decision: normalize_schedule(schedule),
            node_id: Map.get(schedule, :node_id)
          }

          request
          |> Request.schedule_changeset(attrs)
          |> Repo.update()

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  @doc """
  Assigns a runtime-discovered node UUID to the request row.

  Overwrites any existing `node_id` (including scheduler-attributed values)
  because the runtime-discovered identity is authoritative.
  """
  @spec assign_node(struct() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, struct()} | {:error, Ecto.Changeset.t() | :request_not_found}
  def assign_node(%Request{id: request_id}, node_id),
    do: assign_node(request_id, node_id)

  def assign_node(request_id, node_id) do
    Repo.transaction(fn ->
      case lock_request(request_id) do
        {:ok, request} ->
          request
          |> Request.node_assignment_changeset(%{node_id: node_id})
          |> Repo.update()

        {:error, :request_not_found} ->
          Repo.rollback(:request_not_found)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp normalize_schedule(schedule) when is_map(schedule) do
    schedule
    |> Map.new(fn
      {:runtime_client_target, target} when is_list(target) ->
        {"runtime_client_target",
         %{
           "host" => to_string(Keyword.get(target, :host, "")),
           "port" => Keyword.get(target, :port)
         }}

      {:strategy, value} when is_atom(value) ->
        {"strategy", Atom.to_string(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp lock_request(request_id) do
    request =
      Request
      |> where([request], request.id == ^request_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case request do
      nil -> {:error, :request_not_found}
      request -> {:ok, request}
    end
  end

  defp normalize_request_event_attrs(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp default_occurred_at(%{"occurred_at" => nil} = attrs),
    do: Map.put(attrs, "occurred_at", utc_now())

  defp default_occurred_at(%{"occurred_at" => _occurred_at} = attrs), do: attrs
  defp default_occurred_at(attrs), do: Map.put(attrs, "occurred_at", utc_now())

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  defp next_request_event_seq(request_id) do
    RequestEvent
    |> where([event], event.request_id == ^request_id)
    |> select([event], max(event.seq))
    |> Repo.one()
    |> case do
      nil -> 1
      seq -> seq + 1
    end
  end

  @doc """
  Returns a summary of request counts grouped by lifecycle state.

  All states from `Request.states/0` are present in `by_state`, zero-filled
  when no rows exist for that state. `active` and `terminal` are derived
  from the canonical state partitions.
  """
  @spec summary() :: %{
          total: non_neg_integer(),
          active: non_neg_integer(),
          terminal: non_neg_integer(),
          by_state: %{required(atom()) => non_neg_integer()}
        }
  def summary do
    counts =
      Request
      |> group_by([r], r.state)
      |> select([r], {r.state, count(r.id)})
      |> Repo.all()
      |> Map.new()

    by_state = zero_fill_states(counts, Request.states())
    total = by_state |> Map.values() |> Enum.sum()
    active = sum_states(by_state, Request.active_states())
    terminal = sum_states(by_state, Request.terminal_states())

    %{total: total, active: active, terminal: terminal, by_state: by_state}
  end

  defp zero_fill_states(counts, states) do
    Map.new(states, fn state -> {state, Map.get(counts, state, 0)} end)
  end

  defp sum_states(by_state, states) do
    Enum.reduce(states, 0, fn state, acc -> acc + Map.get(by_state, state, 0) end)
  end

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, {:error, changeset}}), do: {:error, changeset}
  defp unwrap_transaction_result({:error, :request_not_found}), do: {:error, :request_not_found}
  defp unwrap_transaction_result({:error, :already_terminal}), do: {:error, :already_terminal}
end
