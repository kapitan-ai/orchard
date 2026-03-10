defmodule Orchard.Node.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor for per-model runtime worker processes.
  """

  use DynamicSupervisor

  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.WorkerProcess

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_worker(ModelRef.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_worker(%ModelRef{} = model_ref, opts \\ []) do
    child_opts = Keyword.put(opts, :model_ref, model_ref)

    spec =
      Supervisor.child_spec(
        {WorkerProcess, child_opts},
        restart: :temporary
      )

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
