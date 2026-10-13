defmodule Orchard.RuntimeEndpoint.ConnectionIncarnation do
  @moduledoc """
  Process-local authenticated BEAM connection observation fence.

  A Node Agent generates one random incarnation for each locally observed OTP
  connection instance. A Controller binds that value to its own node-local OTP
  connection identifier. Neither value is persisted or grants authority.
  """

  use GenServer

  @encoded_bytes 16
  @incarnation_pattern ~r/\A[A-Za-z0-9_-]{22}\z/
  @monitor_options %{connection_id: true, node_type: :visible}

  @type connection_id :: integer()
  @type incarnation :: String.t()
  @type role :: :controller | :node_agent

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec connection_id(node(), GenServer.server()) ::
          {:ok, connection_id()} | {:error, :connection_not_current}
  def connection_id(peer, server \\ __MODULE__) when is_atom(peer) do
    GenServer.call(server, {:connection_id, peer})
  end

  @spec issue(node(), GenServer.server()) ::
          {:ok, %{connection_id: connection_id(), incarnation: incarnation()}}
          | {:error, atom()}
  def issue(peer, server \\ __MODULE__) when is_atom(peer) do
    GenServer.call(server, {:issue, peer})
  end

  @spec bind(node(), connection_id(), String.t(), GenServer.server()) ::
          :ok | {:error, atom()}
  def bind(peer, connection_id, incarnation, server \\ __MODULE__)
      when is_atom(peer) and is_integer(connection_id) and is_binary(incarnation) do
    GenServer.call(server, {:bind, peer, connection_id, incarnation})
  end

  @spec current?(node(), connection_id(), String.t(), GenServer.server()) :: boolean()
  def current?(peer, connection_id, incarnation, server \\ __MODULE__)
      when is_atom(peer) and is_integer(connection_id) and is_binary(incarnation) do
    GenServer.call(server, {:current?, peer, connection_id, incarnation})
  end

  @spec fence(node(), connection_id(), String.t(), (-> result), GenServer.server()) ::
          result | {:error, atom()}
        when result: term()
  def fence(peer, connection_id, incarnation, fun, server \\ __MODULE__)
      when is_atom(peer) and is_integer(connection_id) and is_binary(incarnation) and
             is_function(fun, 0) do
    registry = GenServer.whereis(server) || server

    case GenServer.call(registry, {:acquire_fence, peer, connection_id, incarnation}) do
      {:ok, token, guard} ->
        execute_fence(guard, registry, peer, token, fun)

      {:error, _reason} = error ->
        error
    end
  end

  @spec invalidate(node(), connection_id() | :any, GenServer.server()) :: :ok
  def invalidate(peer, connection_id \\ :any, server \\ __MODULE__) when is_atom(peer) do
    GenServer.call(server, {:invalidate, peer, connection_id})
  end

  @spec valid_incarnation?(term()) :: boolean()
  def valid_incarnation?(value),
    do: is_binary(value) and Regex.match?(@incarnation_pattern, value)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    role = Keyword.fetch!(opts, :role)
    true = role in [:controller, :node_agent]
    monitor = Keyword.get(opts, :monitor, &:net_kernel.monitor_nodes/2)

    case monitor.(true, @monitor_options) do
      :ok ->
        disconnect_existing_peers(opts)

        {:ok,
         %{
           role: role,
           entries: %{},
           fences: %{},
           connection_id_provider:
             Keyword.get(opts, :connection_id_provider, &default_connection_id/1),
           random_bytes: Keyword.get(opts, :random_bytes, &:crypto.strong_rand_bytes/1),
           monitor: monitor
         }}

      ignored when ignored in [:ignored, :error] ->
        {:stop, :beam_distribution_unavailable}

      {:error, reason} ->
        {:stop, {:beam_connection_monitor_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.fences, fn {_peer, fence} -> Process.exit(fence.guard, :shutdown) end)
    _result = state.monitor.(false, @monitor_options)
    :ok
  end

  @impl true
  def handle_call({:connection_id, peer}, _from, state) do
    {:reply, current_connection_id(state, peer), state}
  end

  def handle_call({:issue, peer}, _from, %{role: :node_agent} = state) do
    case current_connection_id(state, peer) do
      {:ok, connection_id} ->
        {entry, state} = issue_for_connection(state, peer, connection_id)
        {:reply, {:ok, entry}, state}

      {:error, _reason} = error ->
        {:reply, error, delete_entry(state, peer)}
    end
  end

  def handle_call({:issue, _peer}, _from, state) do
    {:reply, {:error, :connection_incarnation_role_invalid}, state}
  end

  def handle_call(
        {:bind, peer, connection_id, incarnation},
        _from,
        %{role: :controller} = state
      ) do
    if Map.has_key?(state.fences, peer) do
      {:reply, {:error, :connection_incarnation_not_current}, state}
    else
      with true <- valid_incarnation?(incarnation),
           {:ok, ^connection_id} <- current_connection_id(state, peer) do
        bind_current_connection(state, peer, connection_id, incarnation)
      else
        _other -> {:reply, {:error, :connection_incarnation_not_current}, state}
      end
    end
  end

  def handle_call({:bind, _peer, _connection_id, _incarnation}, _from, state) do
    {:reply, {:error, :connection_incarnation_role_invalid}, state}
  end

  def handle_call({:current?, peer, connection_id, incarnation}, _from, state) do
    current =
      valid_incarnation?(incarnation) and
        current_connection_id(state, peer) == {:ok, connection_id} and
        Map.get(state.entries, peer) == %{
          connection_id: connection_id,
          incarnation: incarnation
        }

    {:reply, current, retain_current_entry(state, peer, current)}
  end

  def handle_call({:acquire_fence, peer, connection_id, incarnation}, {owner, _tag}, state) do
    current =
      valid_incarnation?(incarnation) and
        current_connection_id(state, peer) == {:ok, connection_id} and
        Map.get(state.entries, peer) == %{
          connection_id: connection_id,
          incarnation: incarnation
        }

    case {current, Map.has_key?(state.fences, peer)} do
      {true, false} ->
        token = make_ref()
        monitor_ref = Process.monitor(owner)
        registry = self()
        guard = spawn_link(fn -> fence_guard(registry, peer, token) end)

        fence = %{
          connection_id: connection_id,
          events: [],
          guard: guard,
          monitor_ref: monitor_ref,
          owner: owner,
          token: token
        }

        {:reply, {:ok, token, guard}, put_in(state, [:fences, peer], fence)}

      _other ->
        {:reply, {:error, :connection_incarnation_not_current},
         retain_current_entry(state, peer, current)}
    end
  end

  def handle_call({:release_fence, peer, token}, _from, state) do
    case Map.get(state.fences, peer) do
      %{token: ^token} = fence ->
        Process.demonitor(fence.monitor_ref, [:flush])
        close_fence_guard(fence)
        {:reply, :ok, release_fence(state, peer, fence)}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:invalidate, peer, :any}, _from, state) do
    {:reply, :ok, queue_or_apply(state, peer, {:invalidate, :any})}
  end

  def handle_call({:invalidate, peer, connection_id}, _from, state) do
    {:reply, :ok, queue_or_apply(state, peer, {:invalidate, connection_id})}
  end

  @impl true
  def handle_info({:nodedown, peer, %{connection_id: connection_id}}, state) do
    {:noreply, queue_or_apply(state, peer, {:nodedown, connection_id})}
  end

  def handle_info({:nodeup, peer, %{connection_id: connection_id}}, state) do
    {:noreply, queue_or_apply(state, peer, {:nodeup, connection_id})}
  end

  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    case Enum.find(state.fences, fn {_peer, fence} ->
           fence.monitor_ref == monitor_ref and fence.owner == owner
         end) do
      {peer, fence} ->
        Process.exit(fence.guard, :shutdown)

        retained_fence = %{fence | monitor_ref: nil, owner: nil}
        {:noreply, put_in(state, [:fences, peer], retained_fence)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, guard, _reason}, state) do
    case Enum.find(state.fences, fn {_peer, fence} -> fence.guard == guard end) do
      {peer, fence} ->
        demonitor_owner(fence)
        {:noreply, release_fence(state, peer, fence)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp issue_for_connection(state, peer, connection_id) do
    case Map.get(state.entries, peer) do
      %{connection_id: ^connection_id} = entry ->
        {entry, state}

      _other ->
        incarnation = state.random_bytes.(@encoded_bytes) |> Base.url_encode64(padding: false)
        entry = %{connection_id: connection_id, incarnation: incarnation}
        {entry, put_entry(state, peer, entry)}
    end
  end

  defp bind_current_connection(state, peer, connection_id, incarnation) do
    entry = %{connection_id: connection_id, incarnation: incarnation}

    case Map.get(state.entries, peer) do
      nil ->
        {:reply, :ok, put_entry(state, peer, entry)}

      ^entry ->
        {:reply, :ok, state}

      %{connection_id: ^connection_id} ->
        conflicted = %{connection_id: connection_id, conflicted?: true}

        {:reply, {:error, :connection_incarnation_not_current},
         put_entry(state, peer, conflicted)}

      _other ->
        {:reply, {:error, :connection_incarnation_not_current}, delete_entry(state, peer)}
    end
  end

  defp retain_current_entry(state, _peer, true), do: state

  defp retain_current_entry(state, peer, false) do
    case {Map.get(state.entries, peer), current_connection_id(state, peer)} do
      {%{connection_id: connection_id}, {:ok, connection_id}} -> state
      _other -> delete_entry(state, peer)
    end
  end

  defp current_connection_id(state, peer) do
    case state.connection_id_provider.(peer) do
      connection_id when is_integer(connection_id) -> {:ok, connection_id}
      _other -> {:error, :connection_not_current}
    end
  end

  defp default_connection_id(peer) do
    :connected
    |> :erlang.nodes(%{connection_id: true})
    |> Enum.find_value(fn
      {^peer, %{connection_id: connection_id}} when is_integer(connection_id) -> connection_id
      _other -> nil
    end)
  end

  defp invalidate_event(state, peer, connection_id) do
    case Map.get(state.entries, peer) do
      %{connection_id: ^connection_id} -> delete_entry(state, peer)
      _other -> state
    end
  end

  defp invalidate_replaced_entry(state, peer, connection_id) do
    case Map.get(state.entries, peer) do
      %{connection_id: ^connection_id} -> state
      _other -> delete_entry(state, peer)
    end
  end

  defp queue_or_apply(state, peer, event) do
    case Map.get(state.fences, peer) do
      nil -> apply_event(state, peer, event)
      fence -> put_in(state, [:fences, peer, :events], fence.events ++ [event])
    end
  end

  defp apply_event(state, peer, {:invalidate, :any}), do: delete_entry(state, peer)

  defp apply_event(state, peer, {:invalidate, connection_id}),
    do: invalidate_event(state, peer, connection_id)

  defp apply_event(state, peer, {:nodedown, connection_id}),
    do: invalidate_event(state, peer, connection_id)

  defp apply_event(state, peer, {:nodeup, connection_id}),
    do: invalidate_replaced_entry(state, peer, connection_id)

  defp release_fence(state, peer, fence) do
    state = update_in(state.fences, &Map.delete(&1, peer))
    Enum.reduce(fence.events, state, &apply_event(&2, peer, &1))
  end

  defp disconnect_existing_peers(opts) do
    peers = Keyword.get(opts, :connected_peers, fn -> Node.list(:connected) end).()
    disconnect = Keyword.get(opts, :disconnect, &:erlang.disconnect_node/1)
    Enum.each(peers, disconnect)
  end

  defp execute_fence(guard, registry, peer, token, fun) do
    monitor_ref = Process.monitor(guard)
    request_ref = make_ref()
    send(guard, {:execute, self(), request_ref, fun})

    receive do
      {^request_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^guard, reason} ->
        exit({:connection_incarnation_fence_lost, reason})
    end
  after
    release_fence_safely(registry, peer, token)
  end

  defp close_fence_guard(fence) do
    send(fence.guard, :close)
  end

  defp demonitor_owner(%{monitor_ref: monitor_ref}) when is_reference(monitor_ref),
    do: Process.demonitor(monitor_ref, [:flush])

  defp demonitor_owner(_fence), do: :ok

  defp fence_guard(registry, peer, token) do
    receive do
      {:execute, caller, request_ref, fun} ->
        result = fun.()
        :ok = GenServer.call(registry, {:release_fence, peer, token})
        send(caller, {request_ref, result})
    end
  end

  defp release_fence_safely(registry, peer, token) do
    GenServer.call(registry, {:release_fence, peer, token})
  catch
    :exit, _reason -> :ok
  end

  defp put_entry(state, peer, entry), do: put_in(state, [:entries, peer], entry)
  defp delete_entry(state, peer), do: update_in(state.entries, &Map.delete(&1, peer))
end
