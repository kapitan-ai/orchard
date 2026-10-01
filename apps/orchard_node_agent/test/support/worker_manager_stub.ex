defmodule Orchard.Node.WorkerManagerStub do
  @moduledoc "Acknowledges custody and forwards worker events in isolated WorkerProcess tests."
  use GenServer

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call({:checkpoint_runtime_custody, _key, worker}, {worker, _tag}, owner),
    do: {:reply, :ok, owner}

  @impl true
  def handle_info(event, owner) do
    send(owner, event)
    {:noreply, owner}
  end
end
