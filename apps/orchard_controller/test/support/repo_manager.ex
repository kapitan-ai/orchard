defmodule Orchard.TestSupport.RepoManager do
  @moduledoc false

  use GenServer

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def ensure_repo_started do
    GenServer.call(__MODULE__, :ensure_repo_started, 30_000)
  end

  def stop_repo do
    GenServer.call(__MODULE__, :stop_repo, 30_000)
  end

  @spec run_bounded_failure_probe((-> result), pos_integer()) :: result when result: var
  def run_bounded_failure_probe(fun, timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        try do
          {:returned, fun.()}
        rescue
          error in Mix.Error -> {:raised, error, __STACKTRACE__}
        end
      end)

    try do
      case Task.yield(task, timeout_ms) do
        {:ok, {:returned, result}} ->
          result

        {:ok, {:raised, error, stacktrace}} ->
          reraise error, stacktrace

        {:exit, reason} ->
          raise "repo failure probe exited: #{inspect(reason)}"

        nil ->
          Task.shutdown(task, :brutal_kill)
          raise "repo failure probe exceeded #{timeout_ms}ms"
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  @impl true
  def init(:ok) do
    {:ok, %{}, {:continue, :ensure_repo_started}}
  end

  @impl true
  def handle_continue(:ensure_repo_started, state) do
    {:noreply, ensure_repo_started(state)}
  end

  @impl true
  def handle_call(:ensure_repo_started, _from, state) do
    {:reply, :ok, ensure_repo_started(state)}
  end

  @impl true
  def handle_call(:stop_repo, _from, state) do
    {:reply, :ok, stop_repo(state)}
  end

  defp ensure_repo_started(state) do
    state = start_repo_if_needed(state)

    try do
      Sandbox.mode(Repo, :manual)
      state
    rescue
      error in RuntimeError -> recover_non_sandbox_repo(error, __STACKTRACE__, state)
    end
  end

  defp start_repo_if_needed(state) do
    case Process.whereis(Repo) do
      nil ->
        {:ok, _pid} = Repo.start_link()

      _pid ->
        :ok
    end

    state
  end

  defp recover_non_sandbox_repo(error, stacktrace, state) do
    if String.starts_with?(error.message, "cannot invoke sandbox operation with pool ") do
      state
      |> stop_repo()
      |> start_repo_if_needed()
      |> then(fn restarted_state ->
        :ok = Sandbox.mode(Repo, :manual)
        restarted_state
      end)
    else
      reraise error, stacktrace
    end
  end

  defp stop_repo(state) do
    case Process.whereis(Repo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.stop(pid, :normal, 5_000)
        catch
          :exit, reason ->
            raise "failed to stop Orchard.Repo: #{inspect(reason)}"
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> raise "Orchard.Repo did not stop within timeout"
        end

        Process.demonitor(ref, [:flush])
    end

    if Process.whereis(Repo) != nil do
      raise "Orchard.Repo is still running after stop"
    end

    state
  end
end
