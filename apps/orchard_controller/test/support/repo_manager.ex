defmodule Orchard.TestSupport.RepoManager do
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
    case Process.whereis(Repo) do
      nil ->
        {:ok, _pid} = Repo.start_link()

      _pid ->
        :ok
    end

    Sandbox.mode(Repo, :manual)
    state
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
