defmodule Orchard.Governance.PortalPasswordVerifier do
  @moduledoc """
  Bounded pool for portal password hashing work.

  Two workers and a queue of 32. Saturation returns `{:error, :throttled}`
  without running the job.
  """

  use GenServer

  @max_workers 2
  @max_queue 32
  @call_timeout_ms 5_000

  @type run_error :: :throttled

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec run((-> result)) :: result | {:error, run_error()} when result: term()
  def run(fun) when is_function(fun, 0) do
    timeout = call_timeout_ms() + 100

    GenServer.call(__MODULE__, {:run, fun}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :throttled}
    :exit, {:noproc, _} -> {:error, :throttled}
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{running: %{}, queue: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:run, fun}, from, state) do
    cond do
      map_size(state.running) < max_workers() ->
        {:noreply, start_job(state, from, fun)}

      :queue.len(state.queue) < max_queue() ->
        {:noreply, %{state | queue: :queue.in({from, fun}, state.queue)}}

      true ->
        {:reply, {:error, :throttled}, state}
    end
  end

  @impl GenServer
  def handle_info({:job_done, pid, result}, state) do
    case Map.pop(state.running, pid) do
      {nil, _running} ->
        {:noreply, state}

      {from, running} ->
        GenServer.reply(from, result)
        {:noreply, dequeue_next(%{state | running: running})}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state.running, pid) do
      {nil, _running} ->
        {:noreply, state}

      {from, running} ->
        GenServer.reply(from, {:error, {:verifier_crash, reason}})
        {:noreply, dequeue_next(%{state | running: running})}
    end
  end

  defp start_job(state, from, fun) do
    parent = self()

    {pid, _ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:job_done, self(), result})
      end)

    %{state | running: Map.put(state.running, pid, from)}
  end

  defp dequeue_next(state) do
    case :queue.out(state.queue) do
      {{:value, {from, fun}}, queue} ->
        start_job(%{state | queue: queue}, from, fun)

      {:empty, queue} ->
        %{state | queue: queue}
    end
  end

  defp max_workers do
    portal_config() |> Keyword.get(:verifier_workers, @max_workers)
  end

  defp max_queue do
    portal_config() |> Keyword.get(:verifier_queue, @max_queue)
  end

  defp call_timeout_ms do
    portal_config() |> Keyword.get(:verifier_timeout_ms, @call_timeout_ms)
  end

  defp portal_config do
    Application.get_env(:orchard_controller, :portal, [])
  end
end
