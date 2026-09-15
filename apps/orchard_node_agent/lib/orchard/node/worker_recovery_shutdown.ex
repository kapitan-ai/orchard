defmodule Orchard.Node.WorkerRecoveryShutdown do
  @moduledoc "Checkpoints intentional stops while ModelManager and runtime custody are still supervised."
  use GenServer

  alias Orchard.Node.ModelManager

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 15_000}

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    # Missing acknowledgement leaves the prior nonclean checkpoint authoritative.
    ModelManager.prepare_shutdown()
  catch
    :exit, _reason -> :ok
  end
end
