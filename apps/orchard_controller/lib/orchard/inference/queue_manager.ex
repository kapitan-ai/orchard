defmodule Orchard.Inference.QueueManager do
  @moduledoc """
  BEAM-local controller admission owner for the bounded queue-first slice.

  The owner grants at most `capacity` active requests per `{model_id, version}`
  lane, queues same-lane callers up to a tenant-global cap, and monitors queued
  callers so disconnected clients cannot be scheduled later.
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
            entries: %{},
            monitors: %{},
            grants: %{},
            tenant_counts: %{},
            ticket_results: %{},
            owner_runtime: false

  @pre_dispatch_states [:admitted, :queued]
  @in_flight_states [:scheduled, :dispatching, :running, :streaming]
  @recoverable_active_states @in_flight_states
  @ticket_result_ttl_ms 60_000
  @ticket_result_max_count 1_024
  @manager_restart_wait_ms 1_000
  @manager_restart_poll_ms 10

  @type admission_request :: %{
          request_id: Ecto.UUID.t() | String.t(),
          public_id: String.t(),
          tenant_id: Ecto.UUID.t() | String.t(),
          model_id: String.t(),
          version: String.t(),
          caller_pid: pid()
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

  def handle_call({:acquire, request, config}, {_waiter_pid, _tag}, state) do
    state = prune_recovered_grants(request.queue_key, state)
    lane = Map.get(state.lanes, request.queue_key, empty_lane())

    cond do
      active_capacity?(lane, config.capacity) ->
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
    {result, state} = requeue_grant(grant, request, config, state)
    {:reply, result, state}
  end

  def handle_call({:await, %Ticket{} = ticket}, from, state) do
    case Map.fetch(state.entries, ticket.ticket_ref) do
      {:ok, entry} ->
        entry = put_awaiter(entry, from)

        state =
          state
          |> put_entry_update(entry)
          |> then(&maybe_grant_next(ticket.queue_key, &1))

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
        |> then(&maybe_grant_next(queue_key, &1))
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
      |> then(&maybe_grant_next(entry.queue_key, &1))
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
    |> then(&maybe_grant_next(entry.queue_key, &1))
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

    maybe_grant_next(grant.queue_key, state)
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

    put_recovered_grant(grant_id, queue_key, request.id, state)
  end

  defp recovered_grant_id(request) do
    case request.scheduler_decision || %{} do
      %{"queue_grant_id" => grant_id} when is_binary(grant_id) -> grant_id
      _metadata -> "recovered:#{request.id}"
    end
  end

  defp put_recovered_grant(grant_id, queue_key, request_id, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())
    lane = %{lane | active: Map.put(lane.active, grant_id, true)}

    %{
      state
      | lanes: Map.put(state.lanes, queue_key, lane),
        grants:
          Map.put(state.grants, grant_id, %{
            queue_key: queue_key,
            request_id: request_id,
            recovered?: true
          })
    }
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
        maybe_grant_next(grant.queue_key, state)
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
      queue_key: queue_key(model_id, version)
    }
  end

  defp normalize_config(config) do
    config = Keyword.merge(Orchard.Inference.queue_admission_config(), config)

    %{
      capacity: max(config[:capacity] || 1, 1),
      max_wait_ms: max(config[:max_wait_ms] || 0, 0),
      max_queued_per_tenant: max(config[:max_queued_per_tenant] || 0, 0),
      poll_interval_ms: max(config[:poll_interval_ms] || 100, 1)
    }
  end

  defp queue_key(model_id, version), do: "#{model_id}@#{version}"

  defp empty_lane, do: %{active: %{}, queue: [], blocked_until_monotonic_ms: nil, block_ref: nil}

  defp active_capacity?(lane, capacity) do
    map_size(lane.active) < capacity and lane.queue == [] and not lane_blocked?(lane)
  end

  defp tenant_queue_full?(state, tenant_id, max_queued_per_tenant) do
    Map.get(state.tenant_counts, tenant_id, 0) >= max_queued_per_tenant
  end

  defp grant_immediate(request, config, state) do
    started_monotonic_ms = monotonic_ms()
    grant = build_grant(state, request.queue_key, :immediate, nil, started_monotonic_ms)
    {grant, put_immediate_grant(grant, request, config, started_monotonic_ms, state)}
  end

  defp enqueue_request(request, config, state) do
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
      queue_key: request.queue_key,
      caller_pid: request.caller_pid,
      await_from: nil,
      awaiter_monitor_ref: nil,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
      queued_at: queued_at,
      enqueued_monotonic_ms: enqueued_monotonic_ms,
      queue_deadline_monotonic_ms: queue_deadline_monotonic_ms,
      terminal_operation: nil,
      terminal_metadata: nil,
      terminal_result: nil,
      terminal_retry_ref: nil,
      terminal_retry_after_ms: config.poll_interval_ms
    }

    {ticket, put_entry(entry, state)}
  end

  defp put_entry(entry, state) do
    lane = Map.get(state.lanes, entry.queue_key, empty_lane())
    lane = %{lane | queue: lane.queue ++ [entry.ticket_ref]}

    %{
      state
      | lanes: Map.put(state.lanes, entry.queue_key, lane),
        entries: Map.put(state.entries, entry.ticket_ref, entry),
        monitors: Map.put(state.monitors, entry.monitor_ref, {:caller, entry.ticket_ref}),
        tenant_counts: Map.update(state.tenant_counts, entry.tenant_id, 1, &(&1 + 1))
    }
  end

  defp release_grant(grant_id, state) do
    case Map.fetch(state.grants, grant_id) do
      {:ok, %{queue_key: queue_key}} ->
        state = drop_active_grant(state, grant_id, queue_key)
        maybe_grant_next(queue_key, state)

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

        {{:error, :request_caller_disconnect, metadata},
         maybe_grant_next(grant_state.queue_key, state)}

      true ->
        requeue_live_grant(grant, grant_state, request, config, state)
    end
  end

  defp requeue_live_grant(grant, grant_state, request, config, state) do
    now_ms = monotonic_ms()
    remaining_ms = grant_state.queue_deadline_monotonic_ms - now_ms
    queued_at = grant_state.queued_at || now_iso8601()
    state = drop_active_grant(state, grant.grant_id, grant_state.queue_key)

    if remaining_ms <= 0 do
      metadata = timeout_metadata(grant_state, queued_at)
      terminalize_requeued_timeout(request, grant_state, queued_at, config, metadata)
      {{:error, :queue_timeout, metadata}, maybe_grant_next(grant_state.queue_key, state)}
    else
      {ticket, state} =
        request
        |> requeue_entry(config, grant_state, queued_at, remaining_ms)
        |> put_requeued_entry(state)

      state = block_lane_retry(request.queue_key, config.poll_interval_ms, state)
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
      queue_key: request.queue_key,
      caller_pid: request.caller_pid,
      await_from: nil,
      awaiter_monitor_ref: nil,
      monitor_ref: monitor_ref,
      timeout_ref: timeout_ref,
      queued_at: queued_at,
      enqueued_monotonic_ms: grant_state.enqueued_monotonic_ms,
      queue_deadline_monotonic_ms: grant_state.queue_deadline_monotonic_ms,
      terminal_operation: nil,
      terminal_metadata: nil,
      terminal_result: nil,
      terminal_retry_ref: nil,
      terminal_retry_after_ms: config.poll_interval_ms
    }

    {ticket, entry}
  end

  defp put_requeued_entry({ticket, entry}, state), do: {ticket, put_entry(entry, state)}

  defp maybe_grant_next(queue_key, state) do
    lane = Map.get(state.lanes, queue_key, empty_lane())

    cond do
      not lane_has_capacity?(lane) ->
        state

      lane_blocked?(lane) ->
        state

      lane.queue == [] ->
        state

      true ->
        grant_next_awaiting_entry(queue_key, lane, state)
    end
  end

  defp grant_next_awaiting_entry(queue_key, lane, state) do
    case lane.queue do
      [] ->
        state

      [ticket_ref | rest] ->
        case Map.fetch(state.entries, ticket_ref) do
          {:ok, %{terminal_operation: operation}} when not is_nil(operation) ->
            state

          {:ok, %{await_from: nil}} ->
            state

          {:ok, entry} ->
            maybe_grant_awaiting_entry(queue_key, lane, rest, entry, state)

          :error ->
            lane = %{lane | queue: rest}
            state = %{state | lanes: Map.put(state.lanes, queue_key, lane)}
            maybe_grant_next(queue_key, state)
        end
    end
  end

  defp maybe_grant_awaiting_entry(queue_key, lane, rest, entry, state) do
    if queued_process_alive?(entry) do
      grant_live_queued_entry(queue_key, lane, rest, entry, state)
    else
      disconnect_queued_entry(entry, state)
    end
  end

  defp grant_live_queued_entry(queue_key, lane, rest, entry, state) do
    lane = %{lane | queue: rest}
    state = put_lane(state, queue_key, lane)
    grant_queued_entry(entry, state)
  end

  defp queued_process_alive?(entry) do
    Process.alive?(entry.caller_pid) and awaiter_alive?(entry)
  end

  defp terminal_pending?(%{terminal_operation: operation}), do: operation != nil
  defp terminal_pending?(_entry), do: false

  defp awaiter_alive?(%{await_from: nil}), do: true

  defp awaiter_alive?(%{await_from: {awaiter_pid, _tag}}), do: Process.alive?(awaiter_pid)

  defp grant_queued_entry(entry, state) do
    grant =
      build_grant(state, entry.queue_key, :queued, entry.queued_at, entry.enqueued_monotonic_ms)

    state = promote_entry_to_grant(entry, grant, state)
    reply_awaiter(entry, {:ok, grant})
    state
  end

  defp promote_entry_to_grant(entry, grant, state) do
    cancel_timer(entry.timeout_ref)
    Process.demonitor(entry.monitor_ref, [:flush])

    lane = Map.get(state.lanes, entry.queue_key, empty_lane())

    lane = %{
      lane
      | active: Map.put(lane.active, grant.grant_id, true),
        queue: Enum.reject(lane.queue, &(&1 == entry.ticket_ref))
    }

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
        queue_deadline_monotonic_ms: entry.queue_deadline_monotonic_ms,
        server: state.server
      })

    %{
      state
      | lanes: Map.put(state.lanes, grant.queue_key, lane),
        entries: Map.delete(state.entries, entry.ticket_ref),
        monitors: monitors,
        grants: grants,
        tenant_counts: decrement_tenant_count(state.tenant_counts, entry.tenant_id)
    }
  end

  defp put_immediate_grant(%Grant{} = grant, request, config, started_monotonic_ms, state) do
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

    lane = Map.get(state.lanes, entry.queue_key, empty_lane())
    lane = %{lane | queue: Enum.reject(lane.queue, &(&1 == entry.ticket_ref))}
    monitors = remove_entry_monitors(state.monitors, entry)

    %{
      state
      | lanes: Map.put(state.lanes, entry.queue_key, lane),
        entries: Map.delete(state.entries, entry.ticket_ref),
        monitors: monitors,
        tenant_counts: decrement_tenant_count(state.tenant_counts, entry.tenant_id)
    }
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
      Orchard.Inference.queue_admission_config()
      |> Keyword.get(:capacity, 1)
      |> max(1)

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

  defp cancel_timer(timeout_ref), do: Process.cancel_timer(timeout_ref, async: true, info: false)

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
