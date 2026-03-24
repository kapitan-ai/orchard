defmodule Orchard.Node.RuntimeAdapter do
  @moduledoc """
  Behaviour for node-local runtime adapters owned by worker processes.

  Adapter implementations send runtime messages back to the owning worker
  process using this mailbox protocol:

    * `{:runtime_adapter_event, generation_ref, %Orchard.InferenceEvent{}}`
    * `{:runtime_adapter_done, generation_ref}`

  `Accepted` remains owned by the gRPC runtime server so the node-runtime RPC
  contract stays explicit at the boundary.
  """

  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef

  @type generation_ref :: reference()
  @type adapter_state :: term()

  @callback load_model(ModelRef.t(), keyword()) :: {:ok, adapter_state()} | {:error, term()}
  @callback unload_model(adapter_state(), keyword()) :: :ok | {:error, term()}

  @callback get_status(adapter_state(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback start_generation(adapter_state(), ExecuteInferenceRequest.t(), keyword()) ::
              {:ok, generation_ref(), adapter_state()} | {:error, term()}

  @callback cancel_generation(adapter_state(), generation_ref(), keyword()) ::
              {:ok, adapter_state()} | {:error, term()}

  @callback finish_generation(adapter_state(), generation_ref(), keyword()) :: adapter_state()

  @spec impl() :: module()
  def impl, do: Orchard.Node.runtime_adapter_impl()

  defmodule Unimplemented do
    @moduledoc false

    @behaviour Orchard.Node.RuntimeAdapter

    @impl true
    def get_status(_adapter_state, _opts), do: {:error, :runtime_adapter_not_implemented}

    @impl true
    def load_model(_model_ref, _opts), do: {:error, :runtime_adapter_not_implemented}

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, _request, _opts),
      do: {:error, :runtime_adapter_not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end
end
