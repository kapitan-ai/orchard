defmodule Orchard.Inference.QueueManager do
  @moduledoc """
  BEAM-local controller admission owner for the bounded queue-first slice.

  The owner grants at most `capacity` active requests per `{model_id, version}`
  lane and, when configured or resolved from policy, at most the tenant active
  request cap across all lanes. It queues callers by tenant FIFO and monitors
  queued callers so disconnected clients cannot be scheduled later.
  Cross-tenant grants use weighted round-robin, and live `:cluster_busy` or
  `:model_busy` scheduler saturation can requeue an active grant under its
  original queue deadline.
  """

  use GenServer

  import Ecto.Query

  alias Orchard.Repo
  alias Orchard.Requests
  alias Orchard.Requests.{Request, RequestServer}

  require Logger

  defmodule Grant do
    @moduledoc false

    @enforce_keys [
      :server,
      :grant_id,
      :queue_key,
      :queue_result,
      :queue_granted_at,
      :queue_wait_ms
    ]
    defstruct [
      :server,
      :grant_id,
      :queue_key,
      :queue_result,
      :queued_at,
      :queue_granted_at,
      :queue_wait_ms
    ]

    @type t :: %__MODULE__{
            server: GenServer.server(),
            grant_id: String.t(),
            queue_key: String.t(),
            queue_result: :immediate | :queued,
            queued_at: String.t() | nil,
            queue_granted_at: String.t(),
            queue_wait_ms: non_neg_integer()
          }
  end

  defmodule Ticket do
    @moduledoc false

    @enforce_keys [
      :server,
      :ticket_ref,
      :queue_key,
      :queued_at,
      :enqueued_monotonic_ms,
      :max_wait_ms
    ]
    defstruct [
      :server,
      :ticket_ref,
      :queue_key,
      :queued_at,
      :enqueued_monotonic_ms,
      :max_wait_ms
    ]

    @type t :: %__MODULE__{
            server: GenServer.server(),
            ticket_ref: reference(),
            queue_key: String.t(),
            queued_at: String.t(),
            enqueued_monotonic_ms: integer(),
            max_wait_ms: non_neg_integer()
          }
  end

  defstruct server: __MODULE__,
            lanes: %{},
            tenant_queues: %{},
            tenant_order: [],
            tenant_rr_index: 0,
            scheduler_tick_ref: nil,
            entries: %{},
            monitors: %{},
            grants: %{},
            tenant_counts: %{},
            ticket_results: %{},
            next_admission_sequence: 0,
            owner_runtime: false,
            capacity_sources: %{},
            capacity_source_limits: %{}

  @pre_dispatch_states [:admitted, :queued]
  @in_flight_states [:scheduled, :dispatching, :running, :streaming]
  @recoverable_active_states @in_flight_states
  @ticket_result_ttl_ms 60_000
  @ticket_result_max_count 1_024
  @manager_restart_wait_ms 1_000
  @manager_restart_poll_ms 10
  @max_tenant_weight 100

  @type admission_request :: %{
          required(:request_id) => Ecto.UUID.t() | String.t(),
          required(:public_id) => String.t(),
          required(:tenant_id) => Ecto.UUID.t() | String.t(),
          required(:model_id) => String.t(),
          required(:version) => String.t(),
          optional(:max_active_per_tenant) => pos_integer() | nil,
          optional(:caller_pid) => pid()
        }

  @type acquire_result ::
          {:ok, Grant.t()}
          | {:queued, Ticket.t()}
          | {:error, :queue_full | :request_caller_disconnect, map()}

  @type await_result ::
          {:ok, Grant.t()}
          | {:error, :queue_timeout | :request_caller_disconnect, map()}

  @type requeue_result ::
          {:queued, Ticket.t()}
          | {:error, :queue_timeout | :request_caller_disconnect | :invalid_requeue, map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    opts = Keyword.put_new(opts, :name, name)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{server: stable_server(opts), owner_runtime: owner_runtime?(opts)}

    case reconcile_startup(state, opts) do
      {:ok, reconciled_state} ->
        schedule_recovered_prune(reconciled_state)
        {:ok, reconciled_state}

      {:error, reason} ->
        Logger.error("[QueueManager] startup reconciliation failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @spec acquire(admission_request(), keyword()) :: acquire_result()
  def acquire(attrs, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    config = Keyword.get(opts, :config, Orchard.Inference.queue_admission_config())

    call_manager(server, {:acquire, normalize_request(attrs), normalize_config(config)})
  end

  @spec await(Ticket.t()) :: await_result()
  def await(%Ticket{} = ticket) do
    call_manager(ticket.server, {:await, ticket}, :infinity)
  end

  @spec requeue(Grant.t(), admission_request(), keyword()) :: requeue_result()
  def requeue(%Grant{} = grant, attrs, opts \\ []) do
    config = Keyword.get(opts, :config, Orchard.Inference.queue_admission_config())

    call_manager(
      grant.server,
      {:requeue, grant, normalize_request(attrs), normalize_config(config)}
    )
  end

  @spec abandon(Ticket.t()) :: :ok
  def abandon(%Ticket{} = ticket) do
    call_manager(ticket.server, {:abandon, ticket.ticket_ref})
  end

  @spec refresh_capacity(String.t(), String.t(), non_neg_integer(), keyword()) :: :ok
  def refresh_capacity(model_id, version, capacity, opts \\ [])
      when is_binary(model_id) and is_binary(version) and is_integer(capacity) do
    server = Keyword.get(opts, :server, __MODULE__)
    source = Keyword.get(opts, :source)
    queue_key = queue_key(model_id, version)

    if is_nil(source) do
      call_manager(server, {:refresh_capacity, queue_key, max(capacity, 0), nil})
    else
      call_manager(
        server,
        {:refresh_capacity_sources,
         [{source, max(capacity, 0), %{queue_key => max(capacity, 0)}}]}
      )
    end
  end

  @spec refresh_capacity_sources(
          [{term(), non_neg_integer(), [{String.t(), String.t(), non_neg_integer()}]}],
          keyword()
        ) :: :ok
  def refresh_capacity_sources(records, opts \\ []) when is_list(records) do
    server = Keyword.get(opts, :server, __MODULE__)
    records = Enum.map(records, &normalize_capacity_source_record/1)

    call_manager(server, {:refresh_capacity_sources, records})
  end

  @spec refresh_node_capacity_sources(map(), keyword()) :: :ok
  def refresh_node_capacity_sources(observation, opts \\ []) when is_map(observation) do
    server = Keyword.get(opts, :server, __MODULE__)
    observation = normalize_node_capacity_observation(observation)

    call_manager(server, {:refresh_node_capacity_sources, observation})
  end

  @spec clear_capacity_source(term(), keyword()) :: :ok
  def clear_capacity_source(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:clear_capacity_source, source})
  end

  @spec clear_capacity_sources([term()], keyword()) :: :ok
  def clear_capacity_sources(sources, opts \\ []) when is_list(sources) do
    server = Keyword.get(opts, :server, __MODULE__)
    promote? = Keyword.get(opts, :promote?, true)
    call_manager(server, {:clear_capacity_sources, sources, promote?})
  end

  @spec active_capacity_source_lanes(term(), keyword()) :: [{String.t(), String.t()}]
  def active_capacity_source_lanes(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:active_capacity_source_lanes, source})
  end

  @spec active_capacity_source_reservations(term(), keyword()) :: [
          {String.t(), String.t(), pos_integer()}
        ]
  def active_capacity_source_reservations(source, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:active_capacity_source_reservations, source})
  end

  @spec mark_capacity_source_observed(Grant.t() | String.t(), keyword()) :: :ok
  def mark_capacity_source_observed(grant_or_id, opts \\ [])

  def mark_capacity_source_observed(%Grant{server: server, grant_id: grant_id}, opts) do
    mark_capacity_source_observed(grant_id, Keyword.put(opts, :server, server))
  end

  def mark_capacity_source_observed(grant_id, opts) when is_binary(grant_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:mark_capacity_source_observed, grant_id})
  end

  @spec mark_grant_node(Grant.t() | String.t(), Ecto.UUID.t() | String.t(), keyword()) :: :ok
  def mark_grant_node(grant_or_id, node_id, opts \\ [])

  def mark_grant_node(%Grant{server: server, grant_id: grant_id}, node_id, opts) do
    mark_grant_node(grant_id, node_id, Keyword.put(opts, :server, server))
  end

  def mark_grant_node(grant_id, node_id, opts) when is_binary(grant_id) and is_binary(node_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:mark_grant_node, grant_id, node_id})
  end

  @spec queued_model_lanes(keyword()) :: [{String.t(), String.t()}]
  def queued_model_lanes(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    unique? = Keyword.get(opts, :unique?, true)
    call_manager(server, {:queued_model_lanes, unique?})
  end

  @spec release(Grant.t() | String.t(), keyword()) :: :ok
  def release(grant_or_id, opts \\ [])

  def release(%Grant{server: server, grant_id: grant_id}, opts) do
    release(grant_id, Keyword.put(opts, :server, server))
  end

  def release(grant_id, opts) when is_binary(grant_id) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_manager(server, {:release, grant_id})
  end

  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> :ok
      _pid -> GenServer.call(server, :reset)
    end
  end

  @spec grant_metadata(Grant.t()) :: map()
  def grant_metadata(%Grant{} = grant) do
    %{
      queueing_enabled: true,
      queue_key: grant.queue_key,
      queue_result: grant.queue_result,
      queue_wait_ms: grant.queue_wait_ms,
      queued_at: grant.queued_at,
      queue_granted_at: grant.queue_granted_at,
      queue_grant_id: grant.grant_id
    }
    |> reject_nil_values()
  end

  @spec queued_metadata(Ticket.t()) :: map()
  def queued_metadata(%Ticket{} = ticket) do
    :queued
    |> error_metadata(ticket.queue_key, elapsed_ms(ticket.enqueued_monotonic_ms))
    |> Map.put(:queued_at, ticket.queued_at)
  end

  @spec error_metadata(atom(), String.t(), non_neg_integer()) :: map()
  def error_metadata(queue_result, queue_key, wait_ms \\ 0) do
    %{
      queueing_enabled: true,
      queue_key: queue_key,
      queue_result: queue_result,
      queue_wait_ms: wait_ms
    }
  end

  @impl true
  def handle_call(:reset, _from, state), do: {:reply, :ok, reset_state(state)}

  def handle_call(:queued_model_lanes, _from, state) do
    {:reply, queued_model_lanes_from_state(state), state}
  end

  def handle_call({:queued_model_lanes, unique?}, _from, state) do
    {:reply, queued_model_lanes_from_state(state, unique?), state}
  end

  def handle_call({:active_capacity_source_lanes, source}, _from, state) do
    {:reply, active_capacity_source_lanes_from_state(source, state), state}
  end

  def handle_call({:active_capacity_source_reservations, source}, _from, state) do
    {:reply, active_capacity_source_reservations_from_state(source, state), state}
  end

  def handle_call({:mark_capacity_source_observed, grant_id}, _from, state) do
    {:reply, :ok, mark_capacity_source_observed_in_state(grant_id, state)}
  end

  def handle_call({:mark_grant_node, grant_id, node_id}, _from, state) do
    {:reply, :ok, mark_grant_node_in_state(grant_id, node_id, state)}
  end

  def handle_call({:acquire, request, config}, {_waiter_pid, _tag}, state) do
    config = queue_config_for_request(config, request)

    state =
      request.queue_key
      |> prune_recovered_grants(state)
      |> maybe_grant_next_global()

    {lane, state} = put_lane_capacity(request.queue_key, config.capacity, state)

    cond do
      tenant_has_queued_entries?(state, request.tenant_id) and
          tenant_queue_full?(state, request.tenant_id, config.max_queued_per_tenant) ->
        metadata = error_metadata(:queue_full, request.queue_key)
        {:reply, {:error, :queue_full, metadata}, state}

      tenant_has_queued_entries?(state, request.tenant_id) ->
        {ticket, state} = enqueue_request(request, config, state)
        {:reply, {:queued, ticket}, state}

      active_capacity?(lane, config.capacity) and
        tenant_active_capacity?(state, request, config) and
          not queue_key_has_queued_entries?(state, request.queue_key) ->
        {grant, state} = grant_immediate(request, config, state)
        {:reply, {:ok, grant}, state}

      tenant_queue_full?(state, request.tenant_id, config.max_queued_per_tenant) ->
        metadata = error_metadata(:queue_full, request.queue_key)
        {:reply, {:error, :queue_full, metadata}, state}

      true ->
        {ticket, state} = enqueue_request(request, config, state)
        {:reply, {:queued, ticket}, state}
    end
  end

  def handle_call({:release, grant_id}, _from, state) do
    {:reply, :ok, release_grant(grant_id, state)}
  end

  def handle_call({:requeue, %Grant{} = grant, request, config}, _from, state) do
    config = queue_config_for_request(config, request)
    {result, state} = requeue_grant(grant, request, config, state)
    {:reply, result, state}
  end

  def handle_call({:refresh_capacity, queue_key, capacity, nil}, _from, state) do
    {_lane, state} =
      put_lane_capacity(queue_key, capacity, clear_lane_capacity_sources(queue_key, state))

    {:reply, :ok, maybe_grant_next_global(state)}
  end

  def handle_call({:refresh_capacity_sources, records}, _from, state) do
    state = refresh_capacity_source_records(records, state)
    {:reply, :ok, maybe_grant_next_global(state)}
  end

  def handle_call({:refresh_node_capacity_sources, observation}, _from, state) do
    state =
      observation.clear_sources
      |> clear_capacity_sources_from_state(state, false)
      |> refresh_node_capacity_sources_from_state(observation)
      |> maybe_grant_next_global()

    {:reply, :ok, state}
  end

  def handle_call({:clear_capacity_source, source}, _from, state) do
    {:reply, :ok, clear_capacity_source_from_state(source, state)}
  end

  def handle_call({:clear_capacity_sources, sources, promote?}, _from, state) do
    {:reply, :ok, clear_capacity_sources_from_state(sources, state, promote?)}
  end

  def handle_call({:await, %Ticket{} = ticket}, from, state) do
    case Map.fetch(state.entries, ticket.ticket_ref) do
      {:ok, entry} ->
        entry = put_awaiter(entry, from)

        state =
          state
          |> put_entry_update(entry)
          |> maybe_grant_next_global()

        {:noreply, state}

      :error ->
        {result, state} = pop_ticket_result(ticket, state)
        {:reply, result, state}
    end
  end

  def handle_call({:abandon, ticket_ref}, _from, state) do
    state =
      case Map.fetch(state.entries, ticket_ref) do
        {:ok, entry} ->
          abandon_entry(entry, state)

        :error ->
          delete_ticket_result(state, ticket_ref)
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:prune_recovered_grants, state) do
    state = prune_all_recovered_grants(state)
    schedule_recovered_prune(state)

    {:noreply, state}
  end

  def handle_info({:lane_retry, queue_key, block_ref}, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())

    state =
      if lane.block_ref == block_ref do
        lane = %{lane | blocked_until_monotonic_ms: nil, block_ref: nil}

        state
        |> put_lane(queue_key, lane)
        |> maybe_grant_next_global()
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:queue_timeout, ticket_ref}, state) do
    case Map.fetch(state.entries, ticket_ref) do
      {:ok, entry} ->
        cond do
          terminal_pending?(entry) ->
            {:noreply, state}

          queued_process_alive?(entry) ->
            {:noreply, timeout_queued_entry(entry, state)}

          true ->
            {:noreply, disconnect_queued_entry(entry, state)}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:queued_terminal_retry, ticket_ref}, state) do
    case Map.fetch(state.entries, ticket_ref) do
      {:ok, entry} ->
        {:noreply, retry_queued_terminalization(entry, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:queue_tick, state) do
    state =
      %{state | scheduler_tick_ref: nil}
      |> maybe_grant_next_global()

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, {:caller, ticket_ref}} ->
        {:noreply, handle_queued_process_down(ticket_ref, monitor_ref, :caller, state)}

      {:ok, {:awaiter, ticket_ref}} ->
        {:noreply, handle_queued_process_down(ticket_ref, monitor_ref, :awaiter, state)}

      {:ok, {:grant_owner, grant_id}} ->
        {:noreply, handle_grant_owner_down(grant_id, monitor_ref, state)}

      :error ->
        {:noreply, state}
    end
  end

  defp reconcile_startup(state, opts) do
    cond do
      not state.owner_runtime ->
        {:ok, state}

      not repo_started?() ->
        {:ok, state}

      true ->
        with :ok <- maybe_interrupt_stale_pre_dispatch_requests(opts) do
          {:ok, reconstruct_active_grants(state)}
        end
    end
  end

  defp stable_server(opts), do: Keyword.get(opts, :name, __MODULE__)

  defp owner_runtime?(opts) do
    Keyword.get(opts, :owner_runtime, Orchard.Inference.queue_admission_owner?())
  end

  defp maybe_interrupt_stale_pre_dispatch_requests(opts) do
    case startup_reconciliation_gate(opts) do
      :run ->
        interrupt_stale_pre_dispatch_requests()

      :skip ->
        :ok

      {:run_once, token} ->
        with :ok <- interrupt_stale_pre_dispatch_requests() do
          complete_startup_reconciliation(token)
        end
    end
  end

  defp startup_reconciliation_gate(opts) do
    case Keyword.get(opts, :startup_reconciliation, :always) do
      {:once, token} -> startup_reconciliation_once_gate(token)
      :always -> :run
      value when value == true -> :run
      _other -> :skip
    end
  end

  defp startup_reconciliation_once_gate(token) do
    if startup_reconciliation_complete?(token), do: :run, else: {:run_once, token}
  end

  defp startup_reconciliation_complete?(token) do
    token
    |> startup_reconciliation_key()
    |> :persistent_term.get(false)
  end

  defp complete_startup_reconciliation(token) do
    token
    |> startup_reconciliation_key()
    |> :persistent_term.put(true)
  end

  defp startup_reconciliation_key(token), do: {__MODULE__, :startup_reconciliation, token}

  defp reset_state(state),
    do: %__MODULE__{server: state.server, owner_runtime: state.owner_runtime}

  defp pop_ticket_result(ticket, state) do
    state = prune_ticket_results(state)

    case Map.pop(state.ticket_results, ticket.ticket_ref) do
      {nil, ticket_results} ->
        {{:error, :queue_timeout, timeout_metadata(ticket)},
         %{state | ticket_results: ticket_results}}

      {%{result: result}, ticket_results} ->
        {result, %{state | ticket_results: ticket_results}}
    end
  end

  defp maybe_put_ticket_result(state, %{await_from: nil} = entry, result) do
    state
    |> prune_ticket_results()
    |> put_ticket_result(entry.ticket_ref, result)
    |> prune_ticket_results()
  end

  defp maybe_put_ticket_result(state, _entry, _result), do: state

  defp put_ticket_result(state, ticket_ref, result) do
    ticket_results =
      Map.put(state.ticket_results, ticket_ref, %{
        result: result,
        inserted_monotonic_ms: monotonic_ms()
      })

    %{state | ticket_results: ticket_results}
  end

  defp delete_ticket_result(state, ticket_ref) do
    %{state | ticket_results: Map.delete(state.ticket_results, ticket_ref)}
  end

  defp prune_ticket_results(state) do
    ticket_results =
      state.ticket_results
      |> reject_expired_ticket_results(monotonic_ms())
      |> drop_oldest_ticket_results()

    %{state | ticket_results: ticket_results}
  end

  defp reject_expired_ticket_results(ticket_results, now_ms) do
    Map.reject(ticket_results, fn {_ticket_ref, %{inserted_monotonic_ms: inserted_ms}} ->
      now_ms - inserted_ms > @ticket_result_ttl_ms
    end)
  end

  defp drop_oldest_ticket_results(ticket_results) do
    overflow_count = map_size(ticket_results) - @ticket_result_max_count

    if overflow_count > 0 do
      ticket_results
      |> Enum.sort_by(fn {_ticket_ref, %{inserted_monotonic_ms: inserted_ms}} -> inserted_ms end)
      |> Enum.drop(overflow_count)
      |> Map.new()
    else
      ticket_results
    end
  end

  defp repo_started?, do: Process.whereis(Orchard.Repo) != nil

  defp call_manager(server, message, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, reason -> retry_manager_call(server, message, timeout, reason)
  end

  defp retry_manager_call(server, message, timeout, reason) do
    if stable_server?(server) and retryable_manager_exit?(reason) do
      wait_for_manager(server)
      GenServer.call(server, message, timeout)
    else
      exit(reason)
    end
  end

  defp stable_server?(server), do: not is_pid(server)

  defp retryable_manager_exit?({:timeout, {GenServer, :call, _args}}), do: false
  defp retryable_manager_exit?({_reason, {GenServer, :call, _args}}), do: true
  defp retryable_manager_exit?(_reason), do: false

  defp wait_for_manager(server, remaining_ms \\ @manager_restart_wait_ms)

  defp wait_for_manager(server, remaining_ms) when remaining_ms <= 0 do
    GenServer.whereis(server)
  end

  defp wait_for_manager(server, remaining_ms) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        pid

      nil ->
        Process.sleep(@manager_restart_poll_ms)
        wait_for_manager(server, remaining_ms - @manager_restart_poll_ms)
    end
  end

  defp list_requests_by_states(states) do
    Request
    |> where([request], request.state in ^states)
    |> Repo.all()
  end

  defp terminal_request?(request_id) do
    case Repo.get(Request, request_id) do
      %Request{state: state} -> state in Request.terminal_states()
      nil -> true
    end
  end

  defp interrupt_stale_pre_dispatch_requests do
    failures =
      @pre_dispatch_states
      |> list_requests_by_states()
      |> Enum.reduce([], &collect_reconciliation_failure/2)

    case failures do
      [] -> :ok
      failures -> {:error, {:pre_dispatch_reconciliation_failed, Enum.reverse(failures)}}
    end
  end

  defp interrupt_restarted_request(request) do
    metadata = restart_metadata(request)

    with {:ok, _request} <- Requests.record_schedule(request, metadata),
         :ok <- transition_restarted_request(request),
         {:ok, _request} <-
           Requests.mark_terminal(request, %{
             state: :interrupted,
             error_code: "request_controller_restarted",
             error_message: "Controller admission owner restarted before dispatch"
           }) do
      :ok
    end
  end

  defp collect_reconciliation_failure(request, failures) do
    case interrupt_restarted_request(request) do
      :ok ->
        failures

      {:error, reason} ->
        failure = %{request_id: request.id, public_id: request.public_id, reason: reason}

        Logger.error(
          "[QueueManager] startup reconciliation failed to terminalize " <>
            "#{request.public_id}: #{inspect(reason)}"
        )

        [failure | failures]
    end
  end

  defp transition_restarted_request(request) do
    transition_terminal_state(request.id, :interrupted,
      payload: %{reason: "request_controller_restarted"}
    )
  end

  defp terminalize_queue_timeout(entry, metadata) do
    with {:ok, _request} <- Requests.record_schedule(entry.request_id, metadata),
         :ok <- transition_terminal_state(entry.request_id, :timed_out),
         {:ok, _request} <-
           entry.request_id
           |> Requests.get_request!()
           |> Requests.mark_terminal(%{
             state: :timed_out,
             http_status: 504,
             error_code: "queue_timeout",
             error_message: "Request timed out while waiting for admission"
           }) do
      :ok
    end
  rescue
    error -> {:error, error}
  end

  defp terminalize_caller_disconnect(entry) do
    attrs = %{
      state: :cancelled,
      error_code: "request_caller_disconnect",
      error_message: "Caller disconnected before admission"
    }

    metadata =
      :interrupted_before_dispatch
      |> error_metadata(entry.queue_key, elapsed_ms(entry))
      |> Map.put(:queued_at, entry.queued_at)

    with {:ok, _request} <- Requests.record_schedule(entry.request_id, metadata),
         :ok <-
           transition_terminal_state(entry.request_id, :cancelled,
             payload: %{reason: attrs.error_code}
           ),
         {:ok, _request} <-
           entry.request_id
           |> Requests.get_request!()
           |> Requests.mark_terminal(attrs) do
      :ok
    end
  rescue
    error -> {:error, error}
  end

  defp handle_queued_process_down(ticket_ref, monitor_ref, monitor_type, state) do
    case Map.fetch(state.entries, ticket_ref) do
      {:ok, entry} ->
        state = remove_monitor(state, monitor_ref)
        entry = apply_queued_down(entry, monitor_type)

        if terminal_pending?(entry) do
          put_entry_without_monitor_change(state, entry)
        else
          disconnect_queued_entry(entry, state)
        end

      :error ->
        remove_monitor(state, monitor_ref)
    end
  end

  defp apply_queued_down(entry, :awaiter),
    do: %{entry | await_from: nil, awaiter_monitor_ref: nil}

  defp apply_queued_down(entry, :caller), do: entry

  defp abandon_entry(entry, state) do
    if terminal_pending?(entry) do
      state
    else
      entry
      |> remove_entry(state)
      |> maybe_grant_next_global()
    end
  end

  defp timeout_queued_entry(entry, state) do
    metadata = timeout_metadata(entry)
    result = {:error, :queue_timeout, metadata}

    case terminalize_queue_timeout_result(entry, metadata) do
      :ok ->
        finalize_queued_terminalization(entry, state, result)

      {:error, reason} ->
        park_queued_terminalization(
          entry,
          state,
          :queue_timeout,
          metadata,
          result,
          "queued timeout terminalization",
          reason
        )
    end
  end

  defp disconnect_queued_entry(entry, state) do
    metadata = disconnect_metadata(entry)
    result = {:error, :request_caller_disconnect, metadata}

    case terminalize_caller_disconnect(entry) do
      :ok ->
        finalize_queued_terminalization(entry, state, result)

      {:error, reason} ->
        park_queued_terminalization(
          entry,
          state,
          :request_caller_disconnect,
          metadata,
          result,
          "queued caller disconnect terminalization",
          reason
        )
    end
  end

  defp terminalize_queue_timeout_result(entry, metadata) do
    if terminalize_queue_timeout?(entry),
      do: terminalize_queue_timeout(entry, metadata),
      else: :ok
  end

  defp finalize_queued_terminalization(entry, state, result) do
    cancel_terminal_retry(entry)
    reply_awaiter(entry, result)

    entry
    |> remove_entry(state)
    |> maybe_put_ticket_result(entry, result)
    |> maybe_grant_next_global()
  end

  defp park_queued_terminalization(entry, state, operation, metadata, result, label, reason) do
    log_terminalization_result({:error, reason}, label, entry)

    entry =
      entry
      |> cancel_and_put_terminal_retry()
      |> Map.merge(%{
        terminal_operation: operation,
        terminal_metadata: metadata,
        terminal_result: result
      })

    put_entry_without_monitor_change(state, entry)
  end

  defp retry_queued_terminalization(%{terminal_operation: :queue_timeout} = entry, state) do
    entry = %{entry | terminal_retry_ref: nil}

    case terminalize_queue_timeout_result(entry, entry.terminal_metadata) do
      :ok ->
        finalize_queued_terminalization(entry, state, entry.terminal_result)

      {:error, reason} ->
        park_queued_terminalization(
          entry,
          state,
          :queue_timeout,
          entry.terminal_metadata,
          entry.terminal_result,
          "queued timeout terminalization retry",
          reason
        )
    end
  end

  defp retry_queued_terminalization(
         %{terminal_operation: :request_caller_disconnect} = entry,
         state
       ) do
    entry = %{entry | terminal_retry_ref: nil}

    case terminalize_caller_disconnect(entry) do
      :ok ->
        finalize_queued_terminalization(entry, state, entry.terminal_result)

      {:error, reason} ->
        park_queued_terminalization(
          entry,
          state,
          :request_caller_disconnect,
          entry.terminal_metadata,
          entry.terminal_result,
          "queued caller disconnect terminalization retry",
          reason
        )
    end
  end

  defp retry_queued_terminalization(_entry, state), do: state

  defp cancel_and_put_terminal_retry(entry) do
    cancel_timer(entry.timeout_ref)
    cancel_terminal_retry(entry)

    retry_ref =
      Process.send_after(
        self(),
        {:queued_terminal_retry, entry.ticket_ref},
        terminal_retry_after_ms(entry)
      )

    %{entry | terminal_retry_ref: retry_ref}
  end

  defp put_entry_without_monitor_change(state, entry) do
    %{state | entries: Map.put(state.entries, entry.ticket_ref, entry)}
  end

  defp terminal_retry_after_ms(entry), do: max(entry.terminal_retry_after_ms || 100, 1)

  defp cancel_terminal_retry(%{terminal_retry_ref: retry_ref}) when is_reference(retry_ref) do
    Process.cancel_timer(retry_ref, async: true, info: false)
    :ok
  end

  defp cancel_terminal_retry(_entry), do: :ok

  defp disconnect_metadata(entry) do
    :interrupted_before_dispatch
    |> error_metadata(entry.queue_key, elapsed_ms(entry))
    |> Map.put(:queued_at, entry.queued_at)
  end

  defp terminalize_queue_timeout?(%{await_from: nil}), do: true

  defp terminalize_queue_timeout?(entry), do: pre_dispatch_request?(entry.request_id)

  defp pre_dispatch_request?(request_id) do
    case Repo.get(Request, request_id) do
      %Request{state: state} -> state in @pre_dispatch_states
      nil -> false
    end
  end

  defp handle_grant_owner_down(grant_id, monitor_ref, state) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, grant} ->
        handle_grant_owner_down_outcome(
          grant_owner_disconnect_outcome(grant),
          grant_id,
          monitor_ref,
          grant,
          state
        )

      :error ->
        remove_monitor(state, monitor_ref)
    end
  end

  defp handle_grant_owner_down_outcome(:release, grant_id, monitor_ref, grant, state) do
    state =
      state
      |> drop_active_grant(grant_id, grant.queue_key)
      |> remove_monitor(monitor_ref)

    maybe_grant_next_global(state)
  end

  defp handle_grant_owner_down_outcome(
         {:park, {:terminalization_failed, reason}},
         grant_id,
         monitor_ref,
         grant,
         state
       ) do
    log_grant_owner_terminalization({:error, reason}, grant.request_id)
    park_active_grant(state, grant_id, monitor_ref)
  end

  defp handle_grant_owner_down_outcome({:park, _reason}, grant_id, monitor_ref, _grant, state) do
    park_active_grant(state, grant_id, monitor_ref)
  end

  defp grant_owner_disconnect_outcome(%{request_id: request_id} = grant)
       when is_binary(request_id) do
    case Repo.get(Request, request_id) do
      %Request{} = request ->
        active_request_owner_disconnect_outcome(request, grant)

      nil ->
        :release
    end
  rescue
    error -> {:park, {:terminalization_failed, error}}
  end

  defp grant_owner_disconnect_outcome(_grant), do: :release

  defp active_request_owner_disconnect_outcome(%Request{state: state} = request, grant) do
    cond do
      state in @pre_dispatch_states ->
        terminalized_owner_disconnect_outcome(request, grant)

      state in @in_flight_states ->
        {:park, {:in_flight, state}}

      state in Request.terminal_states() ->
        :release

      true ->
        {:park, {:active_before_admission, state}}
    end
  end

  defp terminalized_owner_disconnect_outcome(request, grant) do
    case terminalize_grant_owner_disconnect_request(request, grant) do
      :ok -> :release
      {:error, reason} -> {:park, {:terminalization_failed, reason}}
    end
  end

  defp terminalize_grant_owner_disconnect_request(request, grant) do
    attrs = %{
      state: :cancelled,
      error_code: "request_caller_disconnect",
      error_message: "Caller disconnected before scheduling"
    }

    metadata =
      :interrupted_before_dispatch
      |> error_metadata(grant.queue_key)
      |> Map.put(:queued_at, grant.queued_at)
      |> reject_nil_values()

    with {:ok, _request} <- Requests.record_schedule(request, metadata),
         :ok <-
           transition_terminal_state(request.id, :cancelled, payload: %{reason: attrs.error_code}),
         {:ok, _request} <- Requests.mark_terminal(request, attrs) do
      :ok
    end
  end

  defp transition_terminal_state(request_id, state, opts \\ []) do
    case RequestServer.transition(request_id, state, opts) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :already_terminal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp log_grant_owner_terminalization({:error, reason}, request_id) do
    Logger.warning(
      "[QueueManager] active grant owner disconnect terminalization failed for " <>
        "#{request_id}: #{inspect(reason)}"
    )

    :ok
  end

  defp remove_monitor(state, monitor_ref) do
    %{state | monitors: Map.delete(state.monitors, monitor_ref)}
  end

  defp log_terminalization_result({:error, reason}, operation, entry) do
    Logger.warning(
      "[QueueManager] #{operation} failed for #{entry.public_id}: #{inspect(reason)}"
    )

    :ok
  end

  defp put_awaiter(entry, from) do
    clear_awaiter_monitor(entry)

    {awaiter_pid, _tag} = from
    awaiter_monitor_ref = Process.monitor(awaiter_pid)

    %{entry | await_from: from, awaiter_monitor_ref: awaiter_monitor_ref}
  end

  defp put_entry_update(state, entry) do
    monitors =
      state.monitors
      |> Map.delete(entry.monitor_ref)
      |> Map.put(entry.monitor_ref, {:caller, entry.ticket_ref})
      |> maybe_put_awaiter_monitor(entry)

    %{state | entries: Map.put(state.entries, entry.ticket_ref, entry), monitors: monitors}
  end

  defp maybe_put_awaiter_monitor(monitors, entry) do
    Map.put(monitors, entry.awaiter_monitor_ref, {:awaiter, entry.ticket_ref})
  end

  defp clear_awaiter_monitor(%{awaiter_monitor_ref: nil}), do: :ok

  defp clear_awaiter_monitor(entry) do
    Process.demonitor(entry.awaiter_monitor_ref, [:flush])
  end

  defp reply_awaiter(%{await_from: nil}, _result), do: :ok

  defp reply_awaiter(entry, result) do
    GenServer.reply(entry.await_from, result)
  end

  defp restart_metadata(request) do
    scheduler_decision = request.scheduler_decision || %{}

    %{
      queueing_enabled: true,
      queue_key: Map.get(scheduler_decision, "queue_key") || queue_key_from_request(request),
      queue_result: :interrupted_controller_restarted,
      queue_wait_ms: Map.get(scheduler_decision, "queue_wait_ms", 0),
      queued_at: Map.get(scheduler_decision, "queued_at")
    }
    |> reject_nil_values()
  end

  defp reconstruct_active_grants(state) do
    @recoverable_active_states
    |> list_requests_by_states()
    |> Enum.filter(&recoverable_active_grant?/1)
    |> Enum.reduce(state, &reconstruct_active_grant/2)
  end

  defp recoverable_active_grant?(%Request{state: state}) when state in @in_flight_states,
    do: true

  defp recoverable_active_grant?(_request), do: false

  defp reconstruct_active_grant(request, state) do
    queue_key = queue_key_from_request(request)
    grant_id = recovered_grant_id(request)

    put_recovered_grant(grant_id, queue_key, request, state)
  end

  defp recovered_grant_id(request) do
    case request.scheduler_decision || %{} do
      %{"queue_grant_id" => grant_id} when is_binary(grant_id) -> grant_id
      _metadata -> "recovered:#{request.id}"
    end
  end

  defp put_recovered_grant(grant_id, queue_key, request, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    lane = %{lane | active: Map.put(lane.active, grant_id, true)}
    grant = recovered_grant(queue_key, request)

    %{
      state
      | lanes: Map.put(state.lanes, queue_key, lane),
        grants: Map.put(state.grants, grant_id, grant)
    }
  end

  defp recovered_grant(queue_key, request) do
    %{
      queue_key: queue_key,
      request_id: request.id,
      tenant_id: request.tenant_id,
      recovered?: true
    }
    |> maybe_put_recovered_grant_node_id(request)
  end

  defp maybe_put_recovered_grant_node_id(grant, request) do
    case normalize_node_id(Map.get(request, :node_id)) do
      nil -> grant
      node_id -> Map.put(grant, :node_id, node_id)
    end
  end

  defp prune_recovered_grants(queue_key, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())

    lane.active
    |> Map.keys()
    |> Enum.reduce(state, &maybe_drop_recovered_grant(&1, &2, queue_key))
  end

  defp maybe_drop_recovered_grant(grant_id, state, queue_key) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, %{recovered?: true, request_id: request_id}} when is_binary(request_id) ->
        drop_recovered_grant_if_terminal(state, grant_id, queue_key, request_id)

      _other ->
        state
    end
  end

  defp drop_recovered_grant_if_terminal(state, grant_id, queue_key, request_id) do
    if terminal_request?(request_id) do
      drop_active_grant(state, grant_id, queue_key)
    else
      state
    end
  end

  defp prune_all_recovered_grants(state) do
    state.grants
    |> Enum.filter(fn {_grant_id, grant} -> grant[:recovered?] == true end)
    |> Enum.reduce(state, fn {grant_id, grant}, state ->
      if terminal_request?(grant.request_id) do
        state = drop_active_grant(state, grant_id, grant.queue_key)
        maybe_grant_next_global(state)
      else
        state
      end
    end)
  end

  defp schedule_recovered_prune(state) do
    if recovered_grants?(state) do
      Process.send_after(self(), :prune_recovered_grants, recovered_prune_interval_ms())
    end

    :ok
  end

  defp recovered_grants?(state) do
    Enum.any?(state.grants, fn {_grant_id, grant} -> grant[:recovered?] == true end)
  end

  defp recovered_prune_interval_ms do
    Orchard.Inference.queue_admission_config()
    |> Keyword.get(:poll_interval_ms, 100)
    |> max(1)
  end

  defp drop_active_grant(state, grant_id, queue_key) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    lane = %{lane | active: Map.delete(lane.active, grant_id)}
    {grant, grants} = Map.pop(state.grants, grant_id)

    %{
      state
      | lanes: Map.put(state.lanes, queue_key, lane),
        grants: grants,
        monitors: remove_grant_owner_monitor(state.monitors, grant)
    }
  end

  defp park_active_grant(state, grant_id, monitor_ref) do
    state =
      case Map.fetch(state.grants, grant_id) do
        {:ok, grant} ->
          grant =
            grant
            |> Map.delete(:owner_monitor_ref)
            |> Map.put(:recovered?, true)

          %{
            state
            | grants: Map.put(state.grants, grant_id, grant),
              monitors: Map.delete(state.monitors, monitor_ref)
          }

        :error ->
          remove_monitor(state, monitor_ref)
      end

    schedule_recovered_prune(state)
    state
  end

  defp remove_grant_owner_monitor(monitors, %{owner_monitor_ref: monitor_ref})
       when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    Map.delete(monitors, monitor_ref)
  end

  defp remove_grant_owner_monitor(monitors, _grant), do: monitors

  defp queue_key_from_request(request) do
    scheduler_decision = request.scheduler_decision || %{}

    Map.get(scheduler_decision, "queue_key") || request.requested_model || "unknown@unknown"
  end

  defp normalize_request(attrs) do
    model_id = Map.fetch!(attrs, :model_id)
    version = Map.fetch!(attrs, :version)

    %{
      request_id: Map.fetch!(attrs, :request_id),
      public_id: Map.fetch!(attrs, :public_id),
      tenant_id: Map.fetch!(attrs, :tenant_id),
      model_id: model_id,
      version: version,
      caller_pid: Map.get(attrs, :caller_pid, self()),
      max_active_per_tenant:
        normalize_max_active_per_tenant(Map.get(attrs, :max_active_per_tenant)),
      queue_key: queue_key(model_id, version)
    }
  end

  defp queue_config_for_request(config, %{max_active_per_tenant: limit})
       when is_integer(limit) and limit > 0 do
    %{config | max_active_per_tenant: limit}
  end

  defp queue_config_for_request(config, _request), do: config

  defp normalize_config(config) do
    config = Keyword.merge(Orchard.Inference.queue_admission_config(), config)

    %{
      capacity: max(config[:capacity] || 1, 0),
      max_wait_ms: max(config[:max_wait_ms] || 0, 0),
      max_active_per_tenant: normalize_max_active_per_tenant(config[:max_active_per_tenant]),
      max_queued_per_tenant: max(config[:max_queued_per_tenant] || 0, 0),
      poll_interval_ms: max(config[:poll_interval_ms] || 100, 1),
      tenant_default_weight: normalize_tenant_weight(config[:tenant_default_weight]),
      tenant_weights: normalize_tenant_weights(config[:tenant_weights] || %{})
    }
  end

  defp normalize_tenant_weights(weights) when is_map(weights) do
    weights
    |> Enum.reduce(%{}, fn {tenant_id, weight}, acc ->
      normalized_weight =
        weight
        |> normalize_tenant_weight()

      Map.put(acc, to_string(tenant_id), normalized_weight)
    end)
  end

  defp normalize_tenant_weights(_weights), do: %{}

  defp normalize_tenant_weight(weight) when is_integer(weight),
    do: weight |> max(1) |> min(@max_tenant_weight)

  defp normalize_tenant_weight(_weight), do: 1

  defp normalize_max_active_per_tenant(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_max_active_per_tenant(_limit), do: nil

  defp queue_key(model_id, version), do: "#{model_id}@#{version}"

  defp normalize_capacity_source_record({source, capacity, lanes}) when is_list(lanes) do
    lane_limits =
      Enum.reduce(lanes, %{}, fn {model_id, version, lane_capacity}, lane_limits ->
        Map.update(
          lane_limits,
          queue_key(model_id, version),
          max(lane_capacity, 0),
          &max(&1, lane_capacity)
        )
      end)

    {source, max(capacity, 0), lane_limits}
  end

  defp normalize_capacity_source_record({source, capacity, lane_limits})
       when is_map(lane_limits) do
    {source, max(capacity, 0),
     Map.new(lane_limits, fn {queue_key, limit} -> {queue_key, max(limit, 0)} end)}
  end

  defp normalize_node_capacity_observation(observation) do
    node_id = normalize_node_id(Map.get(observation, :node_id))

    %{
      clear_sources: Map.get(observation, :clear_sources, []),
      node_source: Map.get(observation, :node_source) || {:node, node_id},
      placement_source: Map.fetch!(observation, :placement_source),
      cold_source: Map.fetch!(observation, :cold_source),
      node_id: node_id,
      node_active: non_negative_integer(Map.get(observation, :node_active)),
      node_max: positive_integer(Map.get(observation, :node_max)),
      placements: normalize_node_capacity_placements(Map.get(observation, :placements, [])),
      reserve_unassigned_node_grants?:
        Map.get(observation, :reserve_unassigned_node_grants?, true) != false,
      reserve_unassigned_source_grants?:
        Map.get(observation, :reserve_unassigned_source_grants?, true) != false
    }
  end

  defp normalize_node_capacity_placements(placements) when is_list(placements) do
    Enum.reduce(placements, %{}, fn
      {model_id, version, status}, acc when is_binary(model_id) and is_binary(version) ->
        Map.put(acc, queue_key(model_id, version), normalize_node_placement_status(status))

      _entry, acc ->
        acc
    end)
  end

  defp normalize_node_capacity_placements(_placements), do: %{}

  defp normalize_node_placement_status(status) when status in [:ambiguous, :unavailable],
    do: status

  defp normalize_node_placement_status(status) when is_map(status) do
    max_concurrency =
      status
      |> map_value(:max_concurrency)
      |> positive_integer_or_zero()

    if max_concurrency > 0 do
      %{
        active: non_negative_integer(map_value(status, :active_request_count)),
        max: max_concurrency
      }
    else
      :unavailable
    end
  end

  defp normalize_node_placement_status(_status), do: :unavailable

  defp empty_lane,
    do: %{active: %{}, base_capacity: 0, blocked_until_monotonic_ms: nil, block_ref: nil}

  defp put_lane_capacity(queue_key, capacity, state) do
    base_capacity = max(capacity, 0)

    lane =
      state.lanes
      |> Map.get(queue_key, empty_lane())
      |> Map.put(:base_capacity, base_capacity)
      |> Map.put(:capacity, base_capacity + aggregate_capacity(queue_key, state))

    {lane, %{state | lanes: Map.put(state.lanes, queue_key, lane)}}
  end

  defp put_source_capacity(queue_key, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    capacity = Map.get(lane, :base_capacity, 0) + aggregate_capacity(queue_key, state)
    lane = Map.put(lane, :capacity, capacity)

    {lane, %{state | lanes: Map.put(state.lanes, queue_key, lane)}}
  end

  defp clear_lane_capacity_sources(queue_key, state) do
    %{
      state
      | capacity_sources: Map.delete(state.capacity_sources, queue_key),
        capacity_source_limits: delete_source_limit_lane(state.capacity_source_limits, queue_key)
    }
  end

  defp aggregate_capacity(queue_key, state) do
    state.capacity_sources
    |> Map.get(queue_key, %{})
    |> Map.values()
    |> Enum.sum()
  end

  defp capacity_source_for_next_grant(queue_key, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    base_capacity = Map.get(lane, :base_capacity, 0)

    if map_size(lane.active) < base_capacity do
      nil
    else
      available_capacity_source(queue_key, state)
    end
  end

  defp available_capacity_source(queue_key, state) do
    reservations = active_source_reservation_counts(queue_key, state)

    state.capacity_sources
    |> Map.get(queue_key, %{})
    |> Enum.sort_by(fn {source, _capacity} -> inspect(source) end)
    |> Enum.find_value(fn {source, capacity} ->
      if capacity > Map.get(reservations, source, 0), do: source
    end)
  end

  defp active_source_reservation_counts(queue_key, state) do
    Enum.reduce(state.grants, %{}, fn {_grant_id, grant}, reservations ->
      if grant[:queue_key] == queue_key and not is_nil(grant[:capacity_source]) do
        Map.update(reservations, grant.capacity_source, 1, &(&1 + 1))
      else
        reservations
      end
    end)
  end

  defp refresh_capacity_source_records(records, state) do
    Enum.reduce(records, state, fn {source, capacity, lane_limits}, state ->
      state
      |> put_capacity_source_record(source, capacity, lane_limits)
      |> rebalance_capacity_source(source)
    end)
  end

  defp put_capacity_source_record(state, source, capacity, lane_limits) do
    lane_limits =
      lane_limits
      |> Enum.reject(fn {_queue_key, limit} -> limit <= 0 end)
      |> Map.new()

    capacity = max(capacity, 0)

    capacity_source_limits =
      if capacity == 0 or map_size(lane_limits) == 0 do
        Map.delete(state.capacity_source_limits, source)
      else
        capacity = min(capacity, source_limit_capacity(lane_limits))
        Map.put(state.capacity_source_limits, source, %{capacity: capacity, lanes: lane_limits})
      end

    %{state | capacity_source_limits: capacity_source_limits}
  end

  defp source_limit_capacity(lane_limits) do
    lane_limits
    |> Map.values()
    |> Enum.sum()
  end

  defp refresh_node_capacity_sources_from_state(state, observation) do
    state = move_node_capacity_source_grants(state, observation)
    sources = [observation.node_source]
    reservations = active_node_source_reservations(state, sources)
    observed_count = observed_node_source_reservation_count(reservations, observation)
    idle_capacity = max(observation.node_max - observation.node_active, 0)

    {preserved_reservations, remaining_capacity} =
      preserve_node_source_reservations(reservations, observed_count, idle_capacity)

    reserved_node_grant_ids =
      reserved_node_grant_ids(state, observation, reservations, observed_count)

    remaining_capacity = max(remaining_capacity - length(reserved_node_grant_ids), 0)

    retained_capacity =
      pending_node_source_capacity(state, observation, preserved_reservations, remaining_capacity)

    state
    |> put_node_capacity_source_limit(
      observation.node_source,
      observation,
      preserved_reservations,
      retained_capacity,
      reserved_node_grant_ids
    )
    |> rebalance_capacity_source(observation.node_source)
  end

  defp move_node_capacity_source_grants(state, observation) do
    old_sources = MapSet.new([observation.placement_source, observation.cold_source])

    grants =
      Map.new(state.grants, fn {grant_id, grant} ->
        source = Map.get(grant, :capacity_source)

        if MapSet.member?(old_sources, source) do
          source_kind = migrated_node_source_kind(source, observation)

          grant =
            grant
            |> Map.put(:capacity_source, observation.node_source)
            |> Map.update(:capacity_source_kind, source_kind, &(&1 || source_kind))

          {grant_id, grant}
        else
          {grant_id, grant}
        end
      end)

    %{state | grants: grants}
  end

  defp migrated_node_source_kind(source, %{placement_source: source}), do: :placement
  defp migrated_node_source_kind(source, %{cold_source: source}), do: :cold
  defp migrated_node_source_kind(_source, _observation), do: nil

  defp active_node_source_reservations(state, sources) do
    source_set = MapSet.new(sources)

    state.grants
    |> Enum.flat_map(fn {grant_id, grant} ->
      source = Map.get(grant, :capacity_source)

      if MapSet.member?(source_set, source) do
        [
          %{
            grant_id: grant_id,
            source: source,
            queue_key: grant.queue_key,
            observed?: Map.get(grant, :capacity_source_observed?) == true,
            kind: Map.get(grant, :capacity_source_kind)
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(fn reservation ->
      {not reservation.observed?, inspect(reservation.source), reservation.queue_key,
       inspect(reservation.grant_id)}
    end)
  end

  defp observed_node_source_reservation_count(reservations, observation) do
    observed_reservations = Enum.filter(reservations, & &1.observed?)

    placement_covered =
      observed_reservations_covered_by_placements(observed_reservations, observation)

    remaining_observed = length(observed_reservations) - placement_covered
    remaining_active = max(observation.node_active - placement_covered, 0)

    placement_covered + min(remaining_observed, remaining_active)
  end

  defp observed_reservations_covered_by_placements(reservations, observation) do
    reservations
    |> Enum.group_by(& &1.queue_key)
    |> Enum.reduce(0, fn {queue_key, reservations}, count ->
      case Map.get(observation.placements, queue_key) do
        %{active: active} -> count + min(length(reservations), active)
        _status -> count
      end
    end)
  end

  defp preserve_node_source_reservations(reservations, observed_budget, idle_budget) do
    uncovered_reservations = max(length(reservations) - observed_budget, 0)
    {reservations, max(idle_budget - uncovered_reservations, 0)}
  end

  defp reserved_node_grant_ids(
         _state,
         %{node_id: nil},
         _source_reservations,
         _observed_source_count
       ),
       do: []

  defp reserved_node_grant_ids(
         state,
         observation,
         source_reservations,
         observed_source_count
       ) do
    source_grant_ids = source_reservations |> Enum.map(& &1.grant_id) |> MapSet.new()

    assigned_node_grant_reservation_ids(
      state,
      observation,
      source_grant_ids,
      observed_source_count
    ) ++ unassigned_node_grant_ids(state, observation, source_grant_ids)
  end

  defp assigned_node_grant_reservation_ids(
         state,
         observation,
         source_grant_ids,
         observed_source_count
       ) do
    observed_node_budget = max(observation.node_active - observed_source_count, 0)

    {observed_grant_ids, unobserved_grant_ids} =
      Enum.reduce(state.grants, {[], []}, fn {grant_id, grant}, {observed, unobserved} ->
        collect_assigned_node_grant_id(
          grant,
          grant_id,
          observation.node_id,
          source_grant_ids,
          {observed, unobserved}
        )
      end)

    observed_grant_ids = Enum.sort_by(observed_grant_ids, &inspect/1)
    unobserved_grant_ids = Enum.sort_by(unobserved_grant_ids, &inspect/1)

    unobserved_grant_ids ++ Enum.drop(observed_grant_ids, observed_node_budget)
  end

  defp collect_assigned_node_grant_id(grant, grant_id, node_id, source_grant_ids, counts) do
    cond do
      Map.get(grant, :node_id) != node_id -> counts
      MapSet.member?(source_grant_ids, grant_id) -> counts
      Map.get(grant, :node_observed?) == true -> collect_observed_grant_id(counts, grant_id)
      true -> collect_unobserved_grant_id(counts, grant_id)
    end
  end

  defp collect_observed_grant_id({observed, unobserved}, grant_id),
    do: {[grant_id | observed], unobserved}

  defp collect_unobserved_grant_id({observed, unobserved}, grant_id),
    do: {observed, [grant_id | unobserved]}

  defp unassigned_node_grant_ids(
         _state,
         %{reserve_unassigned_node_grants?: false},
         _source_grant_ids
       ),
       do: []

  defp unassigned_node_grant_ids(state, observation, source_grant_ids) do
    state.grants
    |> Enum.flat_map(fn {grant_id, grant} ->
      if is_nil(Map.get(grant, :node_id)) and not MapSet.member?(source_grant_ids, grant_id) and
           unassigned_node_grant_reserves_observation?(grant, observation) do
        [grant_id]
      else
        []
      end
    end)
    |> Enum.sort_by(&inspect/1)
  end

  defp unassigned_node_grant_reserves_observation?(
         %{capacity_source: source} = grant,
         %{reserve_unassigned_source_grants?: true}
       )
       when not is_nil(source),
       do: Map.get(grant, :capacity_source_observed?) != true

  defp unassigned_node_grant_reserves_observation?(_grant, %{
         reserve_unassigned_source_grants?: true
       }),
       do: true

  defp unassigned_node_grant_reserves_observation?(grant, _observation),
    do: is_nil(Map.get(grant, :capacity_source))

  defp put_node_capacity_source_limit(
         state,
         source,
         observation,
         preserved_reservations,
         retained_capacity,
         reserved_node_grant_ids
       ) do
    capacity =
      min(
        length(preserved_reservations) + retained_capacity + length(reserved_node_grant_ids),
        observation.node_max
      )

    if capacity <= 0 do
      %{state | capacity_source_limits: Map.delete(state.capacity_source_limits, source)}
    else
      reservation_counts = reservation_counts_by_queue(preserved_reservations)

      limit = %{
        capacity: capacity,
        lanes: :any,
        blocked_lanes: node_capacity_source_blocked_lanes(observation, preserved_reservations),
        lane_limits: node_capacity_source_lane_limits(observation.placements, reservation_counts),
        per_lane_limit: node_capacity_source_per_lane_limit(observation, preserved_reservations),
        node_id: observation.node_id,
        reserve_unassigned_node_grants?: observation.reserve_unassigned_node_grants?,
        reserve_unassigned_source_grants?: observation.reserve_unassigned_source_grants?,
        reserved_node_grants: MapSet.new(reserved_node_grant_ids)
      }

      %{state | capacity_source_limits: Map.put(state.capacity_source_limits, source, limit)}
    end
  end

  defp pending_node_source_capacity(_state, _observation, _reservations, 0), do: 0

  defp pending_node_source_capacity(state, observation, reservations, remaining_capacity) do
    reservation_counts = reservation_counts_by_queue(reservations)

    limit = %{
      lanes: :any,
      blocked_lanes: node_capacity_source_blocked_lanes(observation, reservations),
      lane_limits: node_capacity_source_lane_limits(observation.placements, reservation_counts),
      per_lane_limit: node_capacity_source_per_lane_limit(observation, reservations)
    }

    {_allocations, retained_capacity, _remaining_capacity} =
      state
      |> pending_node_source_entries()
      |> Enum.reduce({reservation_counts, 0, remaining_capacity}, fn entry,
                                                                     {allocations, retained,
                                                                      remaining} ->
        allocated = Map.get(allocations, entry.queue_key, 0)
        lane_limit = source_limit_lane_limit(limit, entry.queue_key, allocated)

        if remaining > 0 and allocated < lane_limit do
          {Map.put(allocations, entry.queue_key, allocated + 1), retained + 1, remaining - 1}
        else
          {allocations, retained, remaining}
        end
      end)

    retained_capacity
  end

  defp pending_node_source_entries(state) do
    state.entries
    |> Map.values()
    |> Enum.reject(&terminal_pending?/1)
    |> Enum.filter(&queued_process_alive?/1)
    |> Enum.sort_by(fn entry ->
      {Map.get(entry, :admission_sequence, 0), Map.get(entry, :enqueued_monotonic_ms, 0)}
    end)
  end

  defp reservation_counts_by_queue(reservations) do
    Enum.reduce(reservations, %{}, fn reservation, counts ->
      Map.update(counts, reservation.queue_key, 1, &(&1 + 1))
    end)
  end

  defp node_capacity_source_lane_limits(placements, reservation_counts) do
    placements
    |> Enum.reduce(%{}, fn
      {queue_key, %{active: active, max: max_concurrency}}, lane_limits ->
        reservations = Map.get(reservation_counts, queue_key, 0)
        spare = max(max_concurrency - active, 0)
        limit = max(reservations, min(max_concurrency, reservations + spare))

        if limit > 0, do: Map.put(lane_limits, queue_key, limit), else: lane_limits

      _placement, lane_limits ->
        lane_limits
    end)
  end

  defp node_capacity_source_blocked_lanes(observation, reservations) do
    observation.placements
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(stale_placement_reservation_lanes(observation, reservations))
  end

  defp stale_placement_reservation_lanes(observation, reservations) do
    reservations
    |> Enum.filter(fn reservation ->
      reservation.kind == :placement and
        not loaded_node_capacity_placement?(
          Map.get(observation.placements, reservation.queue_key)
        )
    end)
    |> Enum.map(& &1.queue_key)
    |> MapSet.new()
  end

  defp loaded_node_capacity_placement?(%{active: _active, max: _max}), do: true
  defp loaded_node_capacity_placement?(_status), do: false

  defp node_capacity_source_per_lane_limit(observation, reservations) do
    placement_queue_keys = MapSet.new(Map.keys(observation.placements))

    reservations
    |> Enum.reject(fn reservation -> reservation.kind == :placement end)
    |> reservation_counts_by_queue()
    |> Enum.reject(fn {queue_key, _count} -> MapSet.member?(placement_queue_keys, queue_key) end)
    |> Enum.map(fn {_queue_key, count} -> count end)
    |> Enum.max(fn -> 1 end)
    |> max(1)
  end

  defp rebalance_capacity_sources(state) do
    state.capacity_source_limits
    |> Map.keys()
    |> Enum.sort_by(&inspect/1)
    |> Enum.reduce(state, fn source, state -> rebalance_capacity_source(state, source) end)
  end

  defp rebalance_capacity_source(state, source) do
    previous_queue_keys = capacity_source_queue_keys(state, source)

    case Map.fetch(state.capacity_source_limits, source) do
      {:ok, %{capacity: capacity} = limit} ->
        capacity = effective_capacity_source_capacity(source, limit, state, capacity)
        reservations = active_source_reservation_counts_by_queue(source, state)

        if drop_retained_node_capacity_source_limit?(limit, reservations, state) do
          state = %{
            state
            | capacity_source_limits: Map.delete(state.capacity_source_limits, source)
          }

          put_capacity_source_allocations(state, source, %{}, previous_queue_keys)
        else
          eligible_reservations = eligible_source_reservations(reservations, limit)

          {allocations, remaining_capacity} =
            reserve_source_capacity(capacity, limit, eligible_reservations)

          allocations =
            state
            |> allocate_source_capacity(limit, allocations, remaining_capacity)

          put_capacity_source_allocations(state, source, allocations, previous_queue_keys)
        end

      :error ->
        put_capacity_source_allocations(state, source, %{}, previous_queue_keys)
    end
  end

  defp effective_capacity_source_capacity(source, %{lanes: :any} = limit, state, capacity) do
    reserved_capacity = retained_node_grant_reservation_count(source, limit, state)
    max(capacity - reserved_capacity, 0)
  end

  defp effective_capacity_source_capacity(_source, _limit, _state, capacity), do: capacity

  defp retained_node_grant_reservation_count(source, limit, state) do
    node_id = Map.get(limit, :node_id) || capacity_source_node_id(source)

    limit
    |> Map.get(:reserved_node_grants, MapSet.new())
    |> Enum.count(fn grant_id ->
      state.grants
      |> Map.get(grant_id)
      |> retained_node_grant_reserves_source?(node_id, source, limit)
    end)
  end

  defp retained_node_grant_reserves_source?(_grant, nil, _source, _limit), do: false
  defp retained_node_grant_reserves_source?(nil, _node_id, _source, _limit), do: false

  defp retained_node_grant_reserves_source?(grant, node_id, source, limit) do
    cond do
      Map.get(grant, :capacity_source) == source ->
        false

      Map.get(grant, :node_id) == node_id ->
        true

      is_nil(Map.get(grant, :node_id)) ->
        retained_unassigned_node_grant_reserves_source?(grant, limit)

      true ->
        false
    end
  end

  defp retained_unassigned_node_grant_reserves_source?(grant, limit) do
    if Map.get(limit, :reserve_unassigned_node_grants?, true) == false do
      false
    else
      case Map.get(grant, :capacity_source) do
        nil ->
          true

        _source ->
          Map.get(limit, :reserve_unassigned_source_grants?, true) and
            Map.get(grant, :capacity_source_observed?) != true
      end
    end
  end

  defp drop_retained_node_capacity_source_limit?(%{lanes: :any}, reservations, state) do
    map_size(reservations) == 0 and pending_node_source_entries(state) == []
  end

  defp drop_retained_node_capacity_source_limit?(_limit, _reservations, _state), do: false

  defp active_source_reservation_counts_by_queue(source, state) do
    Enum.reduce(state.grants, %{}, fn {_grant_id, grant}, reservations ->
      if Map.get(grant, :capacity_source) == source do
        Map.update(reservations, grant.queue_key, 1, &(&1 + 1))
      else
        reservations
      end
    end)
  end

  defp eligible_source_reservations(reservations, %{lanes: :any}), do: reservations

  defp eligible_source_reservations(reservations, %{lanes: lane_limits}) do
    reservations
    |> Enum.filter(fn {queue_key, _count} -> Map.get(lane_limits, queue_key, 0) > 0 end)
    |> Map.new()
  end

  defp reserve_source_capacity(capacity, limit, reservations) do
    reservations
    |> Enum.sort_by(fn {queue_key, _count} -> queue_key end)
    |> Enum.reduce({%{}, capacity}, fn {queue_key, count}, {allocations, remaining} ->
      reserved_capacity =
        count
        |> min(source_limit_lane_limit(limit, queue_key, count))
        |> min(remaining)

      allocations =
        if reserved_capacity > 0 do
          Map.put(allocations, queue_key, reserved_capacity)
        else
          allocations
        end

      {allocations, max(remaining - reserved_capacity, 0)}
    end)
  end

  defp allocate_source_capacity(_state, _limit, allocations, remaining_capacity)
       when remaining_capacity <= 0,
       do: allocations

  defp allocate_source_capacity(state, limit, allocations, remaining_capacity) do
    case next_source_allocatable_entry(state, limit, allocations) do
      {:ok, entry, state} ->
        allocated = Map.get(allocations, entry.queue_key, 0)

        state
        |> simulate_promotable_entry_grant(entry)
        |> allocate_source_capacity(
          limit,
          Map.put(allocations, entry.queue_key, allocated + 1),
          remaining_capacity - 1
        )

      :blocked ->
        allocations
    end
  end

  defp next_source_allocatable_entry(state, limit, allocations) do
    ring = tenant_ring(state)

    if ring == [] do
      :blocked
    else
      scan_source_tenant_ring(
        ring,
        state,
        limit,
        allocations,
        0,
        rem(state.tenant_rr_index, length(ring))
      )
    end
  end

  defp scan_source_tenant_ring(ring, _state, _limit, _allocations, scanned, _index)
       when scanned >= length(ring),
       do: :blocked

  defp scan_source_tenant_ring(ring, state, limit, allocations, scanned, index) do
    tenant_id = Enum.at(ring, index)

    case tenant_head_entry(state, tenant_id) do
      {:ok, entry} ->
        maybe_select_source_allocatable_entry(
          entry,
          ring,
          state,
          limit,
          allocations,
          scanned,
          index
        )

      :empty ->
        scan_source_tenant_ring(
          ring,
          state,
          limit,
          allocations,
          scanned + 1,
          next_ring_index(ring, index)
        )

      {:stale, ticket_ref} ->
        scan_without_stale_source_ticket(state, limit, allocations, tenant_id, ticket_ref)
    end
  end

  defp maybe_select_source_allocatable_entry(
         entry,
         ring,
         state,
         limit,
         allocations,
         scanned,
         index
       ) do
    if source_allocatable_entry?(entry, state, limit, allocations) do
      {:ok, entry, %{state | tenant_rr_index: index + 1}}
    else
      scan_next_source_tenant(ring, state, limit, allocations, scanned, index)
    end
  end

  defp source_allocatable_entry?(entry, state, limit, allocations) do
    lane = Map.get(state.lanes, entry.queue_key, empty_lane())
    allocated = Map.get(allocations, entry.queue_key, 0)
    lane_limit = source_limit_lane_limit(limit, entry.queue_key, allocated)

    cond do
      terminal_pending?(entry) -> false
      is_nil(entry.await_from) -> false
      not queued_process_alive?(entry) -> false
      lane_blocked?(lane) -> false
      not tenant_active_capacity?(state, entry, entry) -> false
      allocated >= lane_limit -> false
      true -> true
    end
  end

  defp scan_next_source_tenant(ring, state, limit, allocations, scanned, index) do
    scan_source_tenant_ring(
      ring,
      state,
      limit,
      allocations,
      scanned + 1,
      next_ring_index(ring, index)
    )
  end

  defp scan_without_stale_source_ticket(state, limit, allocations, tenant_id, ticket_ref) do
    entry = %{tenant_id: tenant_id, ticket_ref: ticket_ref}

    state
    |> Map.put(:tenant_queues, remove_from_tenant_queues(state.tenant_queues, entry))
    |> then(fn state ->
      %{
        state
        | tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry)
      }
    end)
    |> next_source_allocatable_entry(limit, allocations)
  end

  defp source_limit_lane_limit(%{lanes: :any} = limit, queue_key, allocated) do
    blocked_lanes = Map.get(limit, :blocked_lanes, MapSet.new())
    lane_limits = Map.get(limit, :lane_limits, %{})
    per_lane_limit = Map.get(limit, :per_lane_limit, 1)

    cond do
      Map.has_key?(lane_limits, queue_key) ->
        max(Map.fetch!(lane_limits, queue_key), allocated)

      MapSet.member?(blocked_lanes, queue_key) and allocated == 0 ->
        0

      true ->
        max(per_lane_limit, allocated)
    end
  end

  defp source_limit_lane_limit(%{lanes: lane_limits}, queue_key, _allocated),
    do: Map.get(lane_limits, queue_key, 0)

  defp put_capacity_source_allocations(state, source, allocations, previous_queue_keys) do
    queue_keys =
      allocations
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(previous_queue_keys))
      |> MapSet.to_list()

    capacity_sources =
      Enum.reduce(queue_keys, state.capacity_sources, fn queue_key, capacity_sources ->
        sources = Map.get(capacity_sources, queue_key, %{})

        sources =
          case Map.get(allocations, queue_key, 0) do
            capacity when capacity > 0 -> Map.put(sources, source, capacity)
            _capacity -> Map.delete(sources, source)
          end

        put_or_delete_sources(capacity_sources, queue_key, sources)
      end)

    state = %{state | capacity_sources: capacity_sources}

    Enum.reduce(queue_keys, state, fn queue_key, state ->
      {_lane, state} = put_source_capacity(queue_key, state)
      state
    end)
  end

  defp capacity_source_queue_keys(state, source) do
    state.capacity_sources
    |> Enum.filter(fn {_queue_key, sources} -> Map.has_key?(sources, source) end)
    |> Enum.map(fn {queue_key, _sources} -> queue_key end)
  end

  defp delete_source_limit_lane(capacity_source_limits, queue_key) do
    capacity_source_limits
    |> Enum.reduce(%{}, fn
      {source, %{lanes: :any} = limit}, limits ->
        Map.put(limits, source, limit)

      {source, %{capacity: capacity, lanes: lanes}}, limits ->
        lanes = Map.delete(lanes, queue_key)

        if map_size(lanes) == 0 do
          limits
        else
          Map.put(limits, source, %{
            capacity: min(capacity, source_limit_capacity(lanes)),
            lanes: lanes
          })
        end
    end)
  end

  defp mark_capacity_source_observed_in_state(grant_id, state) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, grant} ->
        grant =
          if is_nil(Map.get(grant, :capacity_source)) do
            grant
          else
            Map.put(grant, :capacity_source_observed?, true)
          end

        grant = Map.put(grant, :node_observed?, true)
        %{state | grants: Map.put(state.grants, grant_id, grant)}

      _other ->
        state
    end
  end

  defp mark_grant_node_in_state(grant_id, node_id, state) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, grant} ->
        normalized_node_id = normalize_node_id(node_id)
        {grant, previous_source} = reconcile_grant_capacity_source_node(grant, normalized_node_id)
        grant = Map.put(grant, :node_id, normalized_node_id)
        state = %{state | grants: Map.put(state.grants, grant_id, grant)}

        state =
          if is_nil(previous_source),
            do: state,
            else: expire_retained_capacity_source_limit(state, previous_source)

        maybe_grant_next_global(state)

      _other ->
        state
    end
  end

  defp expire_retained_capacity_source_limit(state, source) do
    previous_queue_keys = capacity_source_queue_keys(state, source)

    case Map.fetch(state.capacity_source_limits, source) do
      {:ok, %{capacity: capacity} = limit} ->
        reservation_capacity =
          source
          |> active_source_reservation_counts_by_queue(state)
          |> Map.values()
          |> Enum.sum()
          |> min(capacity)

        if reservation_capacity <= 0 do
          state = %{
            state
            | capacity_source_limits: Map.delete(state.capacity_source_limits, source)
          }

          put_capacity_source_allocations(state, source, %{}, previous_queue_keys)
        else
          state = %{
            state
            | capacity_source_limits:
                Map.put(state.capacity_source_limits, source, %{
                  limit
                  | capacity: reservation_capacity
                })
          }

          rebalance_capacity_source(state, source)
        end

      :error ->
        put_capacity_source_allocations(state, source, %{}, previous_queue_keys)
    end
  end

  defp reconcile_grant_capacity_source_node(grant, nil), do: {grant, nil}

  defp reconcile_grant_capacity_source_node(grant, node_id) do
    source = Map.get(grant, :capacity_source)

    case capacity_source_node_id(source) do
      nil ->
        {grant, nil}

      ^node_id ->
        {grant, nil}

      _other_node_id ->
        grant =
          grant
          |> Map.delete(:capacity_source)
          |> Map.delete(:capacity_source_kind)
          |> Map.delete(:capacity_source_observed?)

        {grant, source}
    end
  end

  defp clear_capacity_source_from_state(source, state) do
    clear_capacity_sources_from_state([source], state, true)
  end

  defp clear_capacity_sources_from_state(sources, state, promote?) do
    source_set = MapSet.new(sources)

    {capacity_sources, queue_keys} =
      Enum.reduce(state.capacity_sources, {%{}, []}, fn {queue_key, lane_sources},
                                                        {capacity_sources, queue_keys} ->
        remaining_sources =
          Map.reject(lane_sources, fn {source, _capacity} ->
            MapSet.member?(source_set, source)
          end)

        if map_size(remaining_sources) == map_size(lane_sources) do
          {Map.put(capacity_sources, queue_key, lane_sources), queue_keys}
        else
          capacity_sources = put_or_delete_sources(capacity_sources, queue_key, remaining_sources)
          {capacity_sources, [queue_key | queue_keys]}
        end
      end)

    state =
      {capacity_sources, queue_keys}
      |> apply_cleared_capacity_sources(%{
        state
        | capacity_source_limits: Map.drop(state.capacity_source_limits, sources)
      })

    if promote?, do: maybe_grant_next_global(state), else: state
  end

  defp apply_cleared_capacity_sources({capacity_sources, queue_keys}, state) do
    state = %{state | capacity_sources: capacity_sources}

    Enum.reduce(queue_keys, state, fn queue_key, state ->
      {_lane, state} = put_source_capacity(queue_key, state)
      state
    end)
  end

  defp put_or_delete_sources(capacity_sources, queue_key, sources) when map_size(sources) == 0,
    do: Map.delete(capacity_sources, queue_key)

  defp put_or_delete_sources(capacity_sources, queue_key, sources),
    do: Map.put(capacity_sources, queue_key, sources)

  defp active_capacity?(lane, capacity) do
    map_size(lane.active) < capacity and not lane_blocked?(lane)
  end

  defp tenant_active_capacity?(state, %{tenant_id: tenant_id}, %{
         max_active_per_tenant: limit
       }) do
    is_nil(limit) or active_grants_for_tenant(state, tenant_id) < limit
  end

  defp active_grants_for_tenant(state, tenant_id) do
    Enum.count(state.grants, fn {_grant_id, grant} -> grant[:tenant_id] == tenant_id end)
  end

  defp tenant_queue_full?(state, tenant_id, max_queued_per_tenant) do
    Map.get(state.tenant_counts, tenant_id, 0) >= max_queued_per_tenant
  end

  defp tenant_has_queued_entries?(state, tenant_id) do
    case Map.get(state.tenant_queues, tenant_id) do
      %{queue: [_head | _tail]} -> true
      _other -> false
    end
  end

  defp queue_key_has_queued_entries?(state, queue_key) do
    Enum.any?(state.entries, fn {_ticket_ref, entry} -> entry.queue_key == queue_key end)
  end

  defp grant_immediate(request, config, state) do
    {admission_sequence, state} = take_admission_sequence(state)
    started_monotonic_ms = monotonic_ms()
    grant = build_grant(state, request.queue_key, :immediate, nil, started_monotonic_ms)

    {grant,
     put_immediate_grant(grant, request, config, started_monotonic_ms, admission_sequence, state)}
  end

  defp enqueue_request(request, config, state) do
    {admission_sequence, state} = take_admission_sequence(state)
    ticket_ref = make_ref()
    enqueued_monotonic_ms = monotonic_ms()
    queued_at = now_iso8601()
    monitor_ref = Process.monitor(request.caller_pid)
    queue_deadline_monotonic_ms = enqueued_monotonic_ms + config.max_wait_ms

    timeout_ref = Process.send_after(self(), {:queue_timeout, ticket_ref}, config.max_wait_ms)

    ticket = %Ticket{
      server: state.server,
      ticket_ref: ticket_ref,
      queue_key: request.queue_key,
      queued_at: queued_at,
      enqueued_monotonic_ms: enqueued_monotonic_ms,
      max_wait_ms: config.max_wait_ms
    }

    entry = %{
      ticket_ref: ticket_ref,
      request_id: request.request_id,
      public_id: request.public_id,
      tenant_id: request.tenant_id,
      model_id: request.model_id,
      version: request.version,
      queue_key: request.queue_key,
      caller_pid: request.caller_pid,
      await_from: nil,
      awaiter_monitor_ref: nil,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
      queued_at: queued_at,
      enqueued_monotonic_ms: enqueued_monotonic_ms,
      admission_sequence: admission_sequence,
      queue_deadline_monotonic_ms: queue_deadline_monotonic_ms,
      terminal_operation: nil,
      terminal_metadata: nil,
      terminal_result: nil,
      terminal_retry_ref: nil,
      terminal_retry_after_ms: config.poll_interval_ms,
      max_active_per_tenant: config.max_active_per_tenant
    }

    {ticket, put_entry(entry, state)}
  end

  defp queued_model_lanes_from_state(state) do
    queued_model_lanes_from_state(state, true)
  end

  defp queued_model_lanes_from_state(state, unique?) do
    state
    |> promotable_entries_in_grant_order()
    |> Enum.flat_map(&entry_model_lane/1)
    |> maybe_unique_model_lanes(unique?)
  end

  defp maybe_unique_model_lanes(lanes, true), do: Enum.uniq(lanes)
  defp maybe_unique_model_lanes(lanes, _unique?), do: lanes

  defp promotable_entries_in_grant_order(state) do
    collect_promotable_entries(state, [])
  end

  defp collect_promotable_entries(state, entries) do
    case next_promotable_entry(state) do
      {:ok, entry, state} ->
        state
        |> simulate_promotable_entry_grant(entry)
        |> collect_promotable_entries([entry | entries])

      :blocked ->
        Enum.reverse(entries)
    end
  end

  defp next_promotable_entry(state) do
    ring = tenant_ring(state)

    if ring == [] do
      :blocked
    else
      scan_promotable_tenant_ring(ring, state, 0, rem(state.tenant_rr_index, length(ring)))
    end
  end

  defp scan_promotable_tenant_ring(ring, _state, scanned, _index)
       when scanned >= length(ring),
       do: :blocked

  defp scan_promotable_tenant_ring(ring, state, scanned, index) do
    tenant_id = Enum.at(ring, index)

    case tenant_head_entry(state, tenant_id) do
      {:ok, entry} ->
        maybe_select_promotable_entry(entry, ring, state, scanned, index)

      :empty ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      {:stale, ticket_ref} ->
        scan_without_stale_promotable_ticket(ring, state, tenant_id, ticket_ref)
    end
  end

  defp maybe_select_promotable_entry(entry, ring, state, scanned, index) do
    lane = Map.get(state.lanes, entry.queue_key, empty_lane())

    cond do
      terminal_pending?(entry) ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      is_nil(entry.await_from) ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      not queued_process_alive?(entry) ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      lane_blocked?(lane) ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      not tenant_active_capacity?(state, entry, entry) ->
        scan_promotable_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      true ->
        {:ok, entry, %{state | tenant_rr_index: index + 1}}
    end
  end

  defp scan_without_stale_promotable_ticket(_ring, state, tenant_id, ticket_ref) do
    entry = %{tenant_id: tenant_id, ticket_ref: ticket_ref}

    %{
      state
      | tenant_queues: remove_from_tenant_queues(state.tenant_queues, entry),
        tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry)
    }
    |> next_promotable_entry()
  end

  defp simulate_promotable_entry_grant(state, entry) do
    grant_id = {:queued_model_lanes, entry.ticket_ref}

    %{
      state
      | tenant_queues: remove_from_tenant_queues(state.tenant_queues, entry),
        tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry),
        entries: Map.delete(state.entries, entry.ticket_ref),
        grants:
          Map.put(state.grants, grant_id, %{
            queue_key: entry.queue_key,
            tenant_id: entry.tenant_id
          }),
        tenant_counts: decrement_tenant_count(state.tenant_counts, entry.tenant_id)
    }
  end

  defp entry_model_lane(%{model_id: model_id, version: version})
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "",
       do: [{model_id, version}]

  defp entry_model_lane(%{queue_key: queue_key}) when is_binary(queue_key),
    do: queue_key_model_lane(queue_key)

  defp entry_model_lane(_entry), do: []

  defp active_capacity_source_lanes_from_state(source, state) do
    state.capacity_sources
    |> Enum.filter(fn {_queue_key, sources} -> Map.get(sources, source, 0) > 0 end)
    |> Enum.flat_map(fn {queue_key, _sources} -> queue_key_model_lane(queue_key) end)
    |> Enum.uniq()
  end

  defp active_capacity_source_reservations_from_state(source, state) do
    state.grants
    |> Enum.filter(fn {_grant_id, grant} -> Map.get(grant, :capacity_source) == source end)
    |> Enum.group_by(fn {_grant_id, grant} -> grant.queue_key end)
    |> Enum.flat_map(fn {queue_key, grants} ->
      Enum.map(queue_key_model_lane(queue_key), fn {model_id, version} ->
        {model_id, version, length(grants)}
      end)
    end)
  end

  defp queue_key_model_lane(queue_key) do
    case String.split(queue_key, "@", parts: 2) do
      [model_id, version] when model_id != "" and version != "" -> [{model_id, version}]
      _other -> []
    end
  end

  defp normalize_node_id(node_id) when is_binary(node_id) and node_id != "", do: node_id
  defp normalize_node_id(_node_id), do: nil

  defp capacity_source_node_id({:node, node_id}) when is_binary(node_id), do: node_id
  defp capacity_source_node_id({:node, node_id, _kind}) when is_binary(node_id), do: node_id
  defp capacity_source_node_id(_source), do: nil

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: 1

  defp positive_integer_or_zero(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_zero(_value), do: 0

  defp put_entry(entry, state, opts \\ []) do
    position = Keyword.get(opts, :position, :back)
    tenant_id = entry.tenant_id
    tenant_queue = Map.get(state.tenant_queues, tenant_id, %{queue: []})
    queue = put_ticket_in_tenant_queue(tenant_queue.queue, entry, position, state.entries)
    tenant_queues = Map.put(state.tenant_queues, tenant_id, %{tenant_queue | queue: queue})

    state = %{
      state
      | tenant_queues: tenant_queues,
        tenant_order: maybe_append_tenant_order(state, tenant_id),
        entries: Map.put(state.entries, entry.ticket_ref, entry),
        monitors: Map.put(state.monitors, entry.monitor_ref, {:caller, entry.ticket_ref}),
        tenant_counts: Map.update(state.tenant_counts, tenant_id, 1, &(&1 + 1))
    }

    schedule_queue_tick(state)
  end

  defp put_ticket_in_tenant_queue(queue, entry, :front, _entries),
    do: [entry.ticket_ref | queue]

  defp put_ticket_in_tenant_queue(queue, entry, :back, _entries),
    do: queue ++ [entry.ticket_ref]

  defp put_ticket_in_tenant_queue(queue, entry, :admission_order, entries) do
    {before, after_} =
      Enum.split_while(queue, fn ticket_ref ->
        case Map.fetch(entries, ticket_ref) do
          {:ok, existing_entry} -> entry_order_key(existing_entry) <= entry_order_key(entry)
          :error -> true
        end
      end)

    before ++ [entry.ticket_ref | after_]
  end

  defp entry_order_key(entry),
    do: {entry.enqueued_monotonic_ms, Map.get(entry, :admission_sequence, 0)}

  defp take_admission_sequence(state) do
    sequence = state.next_admission_sequence
    {sequence, %{state | next_admission_sequence: sequence + 1}}
  end

  defp maybe_append_tenant_order(state, tenant_id) do
    if tenant_has_queued_entries?(state, tenant_id) do
      state.tenant_order
    else
      state.tenant_order ++ [tenant_id]
    end
  end

  defp release_grant(grant_id, state) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, %{queue_key: queue_key}} ->
        state = drop_active_grant(state, grant_id, queue_key)
        maybe_grant_next_global(state)

      :error ->
        state
    end
  end

  defp requeue_grant(%Grant{} = grant, request, config, state) do
    case Map.fetch(state.grants, grant.grant_id) do
      {:ok, grant_state} ->
        requeue_active_grant(grant, grant_state, request, config, state)

      :error ->
        metadata = error_metadata(:invalid_requeue, request.queue_key)
        {{:error, :invalid_requeue, metadata}, state}
    end
  end

  defp requeue_active_grant(grant, grant_state, request, config, state) do
    cond do
      grant_state.queue_key != request.queue_key ->
        metadata = error_metadata(:invalid_requeue, request.queue_key)
        {{:error, :invalid_requeue, metadata}, state}

      grant_state.request_id != request.request_id or grant_state.public_id != request.public_id or
          grant_state.tenant_id != request.tenant_id ->
        metadata = error_metadata(:invalid_requeue, request.queue_key)
        {{:error, :invalid_requeue, metadata}, state}

      not Process.alive?(request.caller_pid) ->
        state = drop_active_grant(state, grant.grant_id, grant_state.queue_key)
        metadata = disconnect_metadata(grant_state)

        {{:error, :request_caller_disconnect, metadata}, maybe_grant_next_global(state)}

      true ->
        requeue_live_grant(grant, grant_state, request, config, state)
    end
  end

  defp requeue_live_grant(grant, grant_state, request, config, state) do
    now_ms = monotonic_ms()
    remaining_ms = grant_state.queue_deadline_monotonic_ms - now_ms
    queued_at = grant_state.queued_at || now_iso8601()

    state =
      state
      |> drop_active_grant(grant.grant_id, grant_state.queue_key)
      |> expire_requeued_capacity_source(grant_state)

    if remaining_ms <= 0 do
      metadata = timeout_metadata(grant_state, queued_at)
      terminalize_requeued_timeout(request, grant_state, queued_at, config, metadata)
      {{:error, :queue_timeout, metadata}, maybe_grant_next_global(state)}
    else
      {ticket, state} =
        request
        |> requeue_entry(config, grant_state, queued_at, remaining_ms)
        |> put_requeued_entry(state)

      state =
        request.queue_key
        |> block_lane_retry(config.poll_interval_ms, state)
        |> maybe_grant_next_global()

      {{:queued, ticket}, state}
    end
  end

  defp requeue_entry(request, config, grant_state, queued_at, remaining_ms) do
    ticket_ref = make_ref()
    monitor_ref = Process.monitor(request.caller_pid)
    timeout_ref = Process.send_after(self(), {:queue_timeout, ticket_ref}, remaining_ms)

    ticket = %Ticket{
      server: grant_state.server,
      ticket_ref: ticket_ref,
      queue_key: request.queue_key,
      queued_at: queued_at,
      enqueued_monotonic_ms: grant_state.enqueued_monotonic_ms,
      max_wait_ms: config.max_wait_ms
    }

    entry = %{
      ticket_ref: ticket_ref,
      request_id: request.request_id,
      public_id: request.public_id,
      tenant_id: request.tenant_id,
      model_id: request.model_id,
      version: request.version,
      queue_key: request.queue_key,
      caller_pid: request.caller_pid,
      await_from: nil,
      awaiter_monitor_ref: nil,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
      queued_at: queued_at,
      enqueued_monotonic_ms: grant_state.enqueued_monotonic_ms,
      admission_sequence: Map.get(grant_state, :admission_sequence, 0),
      queue_deadline_monotonic_ms: grant_state.queue_deadline_monotonic_ms,
      terminal_operation: nil,
      terminal_metadata: nil,
      terminal_result: nil,
      terminal_retry_ref: nil,
      terminal_retry_after_ms: config.poll_interval_ms,
      max_active_per_tenant: config.max_active_per_tenant
    }

    {ticket, entry}
  end

  defp expire_requeued_capacity_source(state, %{capacity_source: source}) when not is_nil(source),
    do: expire_retained_capacity_source_limit(state, source)

  defp expire_requeued_capacity_source(state, _grant_state), do: state

  defp put_requeued_entry({ticket, entry}, state),
    do: {ticket, put_entry(entry, state, position: :admission_order)}

  defp maybe_grant_next_global(state) do
    state = rebalance_capacity_sources(state)

    case grant_one_queued_entry(state) do
      {:granted, state} -> maybe_grant_next_global(state)
      {:removed, state} -> maybe_grant_next_global(state)
      :blocked -> schedule_queue_tick(state)
    end
  end

  defp grant_one_queued_entry(state) do
    ring = tenant_ring(state)

    if ring == [] do
      :blocked
    else
      scan_tenant_ring(ring, state, 0, rem(state.tenant_rr_index, length(ring)))
    end
  end

  defp scan_tenant_ring(ring, _state, scanned, _index) when scanned >= length(ring), do: :blocked

  defp scan_tenant_ring(ring, state, scanned, index) do
    tenant_id = Enum.at(ring, index)

    case tenant_head_entry(state, tenant_id) do
      {:ok, entry} -> maybe_grant_tenant_head(entry, ring, state, scanned, index)
      :empty -> scan_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))
      {:stale, ticket_ref} -> {:removed, remove_stale_tenant_ticket(state, tenant_id, ticket_ref)}
    end
  end

  defp maybe_grant_tenant_head(%{terminal_operation: operation}, ring, state, scanned, index)
       when not is_nil(operation),
       do: scan_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

  defp maybe_grant_tenant_head(%{await_from: nil}, ring, state, scanned, index) do
    scan_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))
  end

  defp maybe_grant_tenant_head(entry, ring, state, scanned, index) do
    lane = Map.get(state.lanes, entry.queue_key, empty_lane())

    cond do
      not queued_process_alive?(entry) ->
        {:removed, disconnect_queued_entry(entry, state)}

      not lane_has_capacity?(lane) or lane_blocked?(lane) ->
        scan_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      not tenant_active_capacity?(state, entry, entry) ->
        scan_tenant_ring(ring, state, scanned + 1, next_ring_index(ring, index))

      true ->
        state = %{grant_queued_entry(entry, state) | tenant_rr_index: index + 1}
        {:granted, state}
    end
  end

  defp next_ring_index(ring, index), do: rem(index + 1, length(ring))

  defp tenant_head_entry(state, tenant_id) do
    case Map.get(state.tenant_queues, tenant_id) do
      %{queue: [ticket_ref | _rest]} ->
        case Map.fetch(state.entries, ticket_ref) do
          {:ok, entry} -> {:ok, entry}
          :error -> {:stale, ticket_ref}
        end

      _other ->
        :empty
    end
  end

  defp tenant_ring(state), do: tenant_ring(state, state.tenant_queues)

  defp tenant_ring(state, tenant_queues) do
    config = Orchard.Inference.queue_admission_config() |> normalize_config()

    state.tenant_order
    |> Enum.filter(&tenant_queue_has_entries?(tenant_queues, &1))
    |> Enum.flat_map(fn tenant_id ->
      List.duplicate(tenant_id, tenant_weight(tenant_id, config))
    end)
  end

  defp tenant_queue_has_entries?(tenant_queues, tenant_id) do
    case Map.get(tenant_queues, tenant_id) do
      %{queue: [_head | _tail]} -> true
      _other -> false
    end
  end

  defp tenant_weight(tenant_id, config) do
    Map.get(config.tenant_weights, to_string(tenant_id), config.tenant_default_weight)
  end

  defp queued_process_alive?(entry) do
    Process.alive?(entry.caller_pid) and awaiter_alive?(entry)
  end

  defp terminal_pending?(%{terminal_operation: operation}), do: operation != nil
  defp terminal_pending?(_entry), do: false

  defp awaiter_alive?(%{await_from: nil}), do: true

  defp awaiter_alive?(%{await_from: {awaiter_pid, _tag}}), do: Process.alive?(awaiter_pid)

  defp grant_queued_entry(entry, state) do
    capacity_source = capacity_source_for_next_grant(entry.queue_key, state)
    capacity_source_kind = capacity_source_kind_for_grant(entry.queue_key, capacity_source, state)

    grant =
      build_grant(state, entry.queue_key, :queued, entry.queued_at, entry.enqueued_monotonic_ms)

    state = promote_entry_to_grant(entry, grant, capacity_source, capacity_source_kind, state)
    reply_awaiter(entry, {:ok, grant})
    state
  end

  defp capacity_source_kind_for_grant(_queue_key, nil, _state), do: nil

  defp capacity_source_kind_for_grant(queue_key, source, state) do
    case Map.get(state.capacity_source_limits, source) do
      %{lane_limits: lane_limits} when is_map(lane_limits) ->
        if Map.has_key?(lane_limits, queue_key), do: :placement, else: :cold

      %{lanes: lanes} when is_map(lanes) ->
        if Map.has_key?(lanes, queue_key), do: :placement, else: nil

      %{lanes: :any} ->
        :cold

      _limit ->
        nil
    end
  end

  defp promote_entry_to_grant(entry, grant, capacity_source, capacity_source_kind, state) do
    cancel_timer(entry.timeout_ref)
    Process.demonitor(entry.monitor_ref, [:flush])

    lane = Map.get(state.lanes, entry.queue_key, empty_lane())

    lane = %{lane | active: Map.put(lane.active, grant.grant_id, true)}

    monitors =
      state.monitors
      |> Map.delete(entry.monitor_ref)
      |> Map.put(entry.awaiter_monitor_ref, {:grant_owner, grant.grant_id})

    grants =
      Map.put(state.grants, grant.grant_id, %{
        queue_key: grant.queue_key,
        request_id: entry.request_id,
        public_id: entry.public_id,
        tenant_id: entry.tenant_id,
        owner_monitor_ref: entry.awaiter_monitor_ref,
        queued_at: entry.queued_at,
        enqueued_monotonic_ms: entry.enqueued_monotonic_ms,
        admission_sequence: Map.get(entry, :admission_sequence, 0),
        queue_deadline_monotonic_ms: entry.queue_deadline_monotonic_ms,
        server: state.server,
        capacity_source: capacity_source,
        capacity_source_kind: capacity_source_kind,
        capacity_source_observed?: false
      })

    %{
      state
      | lanes: Map.put(state.lanes, grant.queue_key, lane),
        tenant_queues: remove_from_tenant_queues(state.tenant_queues, entry),
        tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry),
        entries: Map.delete(state.entries, entry.ticket_ref),
        monitors: monitors,
        grants: grants,
        tenant_counts: decrement_tenant_count(state.tenant_counts, entry.tenant_id)
    }
    |> maybe_cancel_queue_tick()
  end

  defp put_immediate_grant(
         %Grant{} = grant,
         request,
         config,
         started_monotonic_ms,
         admission_sequence,
         state
       ) do
    owner_monitor_ref = Process.monitor(request.caller_pid)
    lane = Map.get(state.lanes, grant.queue_key, empty_lane())
    lane = %{lane | active: Map.put(lane.active, grant.grant_id, true)}

    grant_state = %{
      queue_key: grant.queue_key,
      request_id: request.request_id,
      public_id: request.public_id,
      tenant_id: request.tenant_id,
      owner_monitor_ref: owner_monitor_ref,
      queued_at: nil,
      enqueued_monotonic_ms: started_monotonic_ms,
      admission_sequence: admission_sequence,
      queue_deadline_monotonic_ms: started_monotonic_ms + config.max_wait_ms,
      server: state.server
    }

    %{
      state
      | lanes: Map.put(state.lanes, grant.queue_key, lane),
        monitors: Map.put(state.monitors, owner_monitor_ref, {:grant_owner, grant.grant_id}),
        grants: Map.put(state.grants, grant.grant_id, grant_state)
    }
  end

  defp remove_entry(entry, state, opts \\ []) do
    if Keyword.get(opts, :cancel_timer?, true), do: cancel_timer(entry.timeout_ref)

    cancel_terminal_retry(entry)

    if Keyword.get(opts, :demonitor?, true) do
      Process.demonitor(entry.monitor_ref, [:flush])
      clear_awaiter_monitor(entry)
    end

    monitors = remove_entry_monitors(state.monitors, entry)

    %{
      state
      | tenant_queues: remove_from_tenant_queues(state.tenant_queues, entry),
        tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry),
        entries: Map.delete(state.entries, entry.ticket_ref),
        monitors: monitors,
        tenant_counts: decrement_tenant_count(state.tenant_counts, entry.tenant_id)
    }
    |> maybe_cancel_queue_tick()
  end

  defp remove_stale_tenant_ticket(state, tenant_id, ticket_ref) do
    entry = %{tenant_id: tenant_id, ticket_ref: ticket_ref}

    %{
      state
      | tenant_queues: remove_from_tenant_queues(state.tenant_queues, entry),
        tenant_order: remove_empty_tenants(state.tenant_order, state.tenant_queues, entry)
    }
    |> maybe_cancel_queue_tick()
  end

  defp remove_from_tenant_queues(tenant_queues, entry) do
    case Map.fetch(tenant_queues, entry.tenant_id) do
      {:ok, tenant_queue} ->
        queue = Enum.reject(tenant_queue.queue, &(&1 == entry.ticket_ref))

        if queue == [] do
          Map.delete(tenant_queues, entry.tenant_id)
        else
          Map.put(tenant_queues, entry.tenant_id, %{tenant_queue | queue: queue})
        end

      :error ->
        tenant_queues
    end
  end

  defp remove_empty_tenants(tenant_order, tenant_queues, entry) do
    tenant_queues = remove_from_tenant_queues(tenant_queues, entry)

    if Map.has_key?(tenant_queues, entry.tenant_id) do
      tenant_order
    else
      Enum.reject(tenant_order, &(&1 == entry.tenant_id))
    end
  end

  defp remove_entry_monitors(monitors, entry) do
    monitors
    |> Map.delete(entry.monitor_ref)
    |> maybe_delete_awaiter_monitor(entry)
  end

  defp maybe_delete_awaiter_monitor(monitors, %{awaiter_monitor_ref: nil}), do: monitors

  defp maybe_delete_awaiter_monitor(monitors, entry) do
    Map.delete(monitors, entry.awaiter_monitor_ref)
  end

  defp lane_has_capacity?(lane) do
    capacity =
      case Map.get(lane, :capacity) do
        value when is_integer(value) ->
          max(value, 0)

        _other ->
          Orchard.Inference.queue_admission_config() |> Keyword.get(:capacity, 1) |> max(1)
      end

    map_size(lane.active) < capacity
  end

  defp lane_blocked?(%{block_ref: block_ref}) when is_reference(block_ref), do: true
  defp lane_blocked?(_lane), do: false

  defp block_lane_retry(queue_key, poll_interval_ms, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    block_ref = make_ref()
    Process.send_after(self(), {:lane_retry, queue_key, block_ref}, poll_interval_ms)

    lane = %{
      lane
      | blocked_until_monotonic_ms: monotonic_ms() + poll_interval_ms,
        block_ref: block_ref
    }

    put_lane(state, queue_key, lane)
  end

  defp put_lane(state, queue_key, lane) do
    %{state | lanes: Map.put(state.lanes, queue_key, lane)}
  end

  defp schedule_queue_tick(%{scheduler_tick_ref: tick_ref} = state) when is_reference(tick_ref),
    do: state

  defp schedule_queue_tick(state) do
    if queues_empty?(state) do
      state
    else
      poll_interval_ms =
        Orchard.Inference.queue_admission_config()
        |> Keyword.get(:poll_interval_ms, 100)
        |> max(1)

      %{state | scheduler_tick_ref: Process.send_after(self(), :queue_tick, poll_interval_ms)}
    end
  end

  defp maybe_cancel_queue_tick(state) do
    if queues_empty?(state) do
      cancel_timer(state.scheduler_tick_ref)
      %{state | scheduler_tick_ref: nil, tenant_rr_index: 0}
    else
      state
    end
  end

  defp queues_empty?(state), do: map_size(state.tenant_queues) == 0

  defp decrement_tenant_count(tenant_counts, tenant_id) do
    case Map.get(tenant_counts, tenant_id, 0) do
      count when count <= 1 -> Map.delete(tenant_counts, tenant_id)
      count -> Map.put(tenant_counts, tenant_id, count - 1)
    end
  end

  defp build_grant(state, queue_key, queue_result, queued_at, started_monotonic_ms) do
    %Grant{
      server: state.server,
      grant_id: Ecto.UUID.generate(),
      queue_key: queue_key,
      queue_result: queue_result,
      queued_at: queued_at,
      queue_granted_at: now_iso8601(),
      queue_wait_ms: elapsed_ms(started_monotonic_ms)
    }
  end

  defp timeout_metadata(%Ticket{} = ticket) do
    :queue_timeout
    |> error_metadata(ticket.queue_key, elapsed_ms(ticket.enqueued_monotonic_ms))
    |> Map.put(:queued_at, ticket.queued_at)
  end

  defp timeout_metadata(entry) do
    :queue_timeout
    |> error_metadata(entry.queue_key, elapsed_ms(entry))
    |> Map.put(:queued_at, entry.queued_at)
  end

  defp timeout_metadata(grant_state, queued_at) do
    :queue_timeout
    |> error_metadata(grant_state.queue_key, elapsed_ms(grant_state.enqueued_monotonic_ms))
    |> Map.put(:queued_at, queued_at)
  end

  defp terminalize_requeued_timeout(request, grant_state, queued_at, config, metadata) do
    entry = %{
      request_id: request.request_id,
      queue_key: request.queue_key,
      queued_at: queued_at,
      enqueued_monotonic_ms: grant_state.enqueued_monotonic_ms,
      terminal_retry_after_ms: config.poll_interval_ms
    }

    case terminalize_queue_timeout(entry, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[QueueManager] requeued grant timeout terminalization failed for " <>
            "#{request.public_id}: #{inspect(reason)}"
        )
    end
  end

  defp elapsed_ms(%{enqueued_monotonic_ms: enqueued_monotonic_ms}),
    do: elapsed_ms(enqueued_monotonic_ms)

  defp elapsed_ms(started_monotonic_ms), do: max(monotonic_ms() - started_monotonic_ms, 0)

  defp cancel_timer(timer_ref) when is_reference(timer_ref),
    do: Process.cancel_timer(timer_ref, async: true, info: false)

  defp cancel_timer(_timer_ref), do: false

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
