defmodule Orchard.RuntimeEndpoint.DistributionExpiryGuard do
  @moduledoc """
  Stops an exact-pair TLS Distribution runtime when its launch grant expires.
  """

  use GenServer

  alias Orchard.RuntimeEndpoint.{BeamNodeName, DistributionLaunch}

  @expired_cookie :orchard_expired_peer_grant
  @max_timer_ms :timer.hours(24)
  @shutdown_grace_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    manifest_path = Keyword.get(opts, :manifest_path)
    launch_loader = Keyword.get(opts, :launch_loader, &DistributionLaunch.load/1)

    with true <- is_binary(manifest_path) and manifest_path != "",
         {:ok, manifest} <- launch_loader.(manifest_path),
         {:ok, peer} <- peer_node(manifest),
         %DateTime{} = expires_at <- value(manifest, :expires_at) do
      state = %{
        cookie_setter: Keyword.get(opts, :cookie_setter, &Node.set_cookie/2),
        disconnect: Keyword.get(opts, :disconnect, &Node.disconnect/1),
        expired?: false,
        expires_at: expires_at,
        fail_closed: Keyword.get(opts, :fail_closed, &fail_closed/0),
        hard_stop: Keyword.get(opts, :hard_stop, &hard_stop/0),
        now: Keyword.get(opts, :now, &DateTime.utc_now/0),
        peer: peer,
        shutdown_grace_ms: Keyword.get(opts, :shutdown_grace_ms, @shutdown_grace_ms),
        stop_distribution: Keyword.get(opts, :stop_distribution, &Node.stop/0)
      }

      {:ok, schedule_check(state)}
    else
      {:error, :beam_target_unknown} -> {:stop, :beam_target_unknown}
      _other -> {:stop, :beam_distribution_expiry_guard_invalid}
    end
  rescue
    _error -> {:stop, :beam_distribution_expiry_guard_invalid}
  catch
    _kind, _reason -> {:stop, :beam_distribution_expiry_guard_invalid}
  end

  @impl true
  def handle_info(:check_expiry, %{expired?: true} = state), do: {:noreply, state}

  def handle_info(:check_expiry, state) do
    if DateTime.compare(state.now.(), state.expires_at) == :lt do
      {:noreply, schedule_check(state)}
    else
      cookie_result = safe_call(state.cookie_setter, [state.peer, @expired_cookie])
      _disconnect_result = safe_call(state.disconnect, [state.peer])
      stop_result = safe_call(state.stop_distribution, [])

      if cookie_result == true and stop_result == :ok do
        {:noreply, %{state | expired?: true}}
      else
        watchdog_result =
          safe_call(&start_halt_watchdog/2, [state.hard_stop, state.shutdown_grace_ms])

        if watchdog_result != :ok do
          _hard_stop_result = safe_call(state.hard_stop, [])
        end

        _fail_closed_result = safe_call(state.fail_closed, [])
        {:noreply, %{state | expired?: true}}
      end
    end
  end

  defp schedule_check(state) do
    delay =
      state.expires_at
      |> DateTime.diff(state.now.(), :millisecond)
      |> max(0)
      |> min(@max_timer_ms)

    Process.send_after(self(), :check_expiry, delay)
    state
  end

  defp peer_node(manifest) do
    peer =
      case value(manifest, :role) do
        :controller ->
          {value(manifest, :node_beam_name), "orchard_node_agent_", value(manifest, :node_id)}

        :node_agent ->
          {value(manifest, :controller_beam_name), "orchard_controller_",
           value(manifest, :controller_id)}

        _role ->
          nil
      end

    case peer do
      {name, prefix, id} -> BeamNodeName.to_atom(name, prefix, id)
      nil -> {:error, :beam_distribution_expiry_guard_invalid}
    end
  end

  defp safe_call(fun, args) do
    apply(fun, args)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp start_halt_watchdog(hard_stop, shutdown_grace_ms) do
    {:ok, _pid} =
      Task.start(fn ->
        Process.sleep(shutdown_grace_ms)
        safe_call(hard_stop, [])
      end)

    :ok
  end

  defp fail_closed, do: System.stop(1)
  @spec hard_stop() :: no_return()
  defp hard_stop, do: System.halt(1)
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
