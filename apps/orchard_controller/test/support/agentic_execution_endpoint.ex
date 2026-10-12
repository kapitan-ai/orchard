defmodule Orchard.TestSupport.AgenticExecutionEndpoint do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.GrpcCompatibilityClient, as: Client

  defdelegate connect(target), to: Client
  defdelegate disconnect(connection), to: Client
  defdelegate status(connection, opts), to: Client
  defdelegate ensure_model_loaded(connection, request, opts), to: Client
  defdelegate unload_model(connection, request, opts), to: Client
  defdelegate cancel_inference(connection, request, opts), to: Client
  defdelegate score_prefix_cache(connection, request, opts), to: Client

  @spec execute_inference(term(), map(), keyword()) :: {:ok, reference()}
  def execute_inference(connection, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    fixture = Application.fetch_env!(:orchard_controller, :agentic_execution_fixture)
    send(fixture.owner, {:agentic_execution_started, request})
    relay = spawn_link(fn -> relay(owner, fixture, []) end)
    Client.execute_inference(connection, request, Keyword.put(opts, :owner, relay))
  end

  defp relay(owner, fixture, events) do
    receive do
      {:runtime_endpoint_event, ref, id, event} ->
        emitted = fault_events(event, fixture[:fault])
        Enum.each(emitted, &send(owner, {:runtime_endpoint_event, ref, id, &1}))
        relay(owner, fixture, Enum.reverse(emitted) ++ events)

      {:runtime_endpoint_done, _ref, _result} = message ->
        send(fixture.owner, {:agentic_runtime_trace, Enum.reverse(events)})
        send(owner, message)
    end
  end

  defp fault_events(event, fault) do
    case {InferenceEvent.terminal?(event), fault} do
      {true, "missing_terminal"} -> []
      {true, "duplicate_terminal"} -> [event, event]
      {true, "post_terminal_text"} -> [event, InferenceEvent.output_text_delta("forbidden")]
      _other -> [event]
    end
  end
end

defmodule Orchard.TestSupport.AgenticExecutionManagedEndpoint do
  @moduledoc false

  alias Orchard.TestSupport.RetryAPI.RuntimeClient, as: Client

  defdelegate connect(target), to: Client
  defdelegate disconnect(connection), to: Client
  defdelegate status(connection, opts), to: Client
  defdelegate ensure_model_loaded(connection, request, opts), to: Client
  defdelegate unload_model(connection, request, opts), to: Client
  defdelegate cancel_inference(connection, request, opts), to: Client
  defdelegate score_prefix_cache(connection, request, opts), to: Client

  @spec execute_inference(term(), map(), keyword()) :: {:ok, reference()}
  def execute_inference(connection, request, opts) do
    send(self(), {:agentic_managed_identity, request})
    Client.execute_inference(connection, request, opts)
  end
end

defmodule Orchard.TestSupport.AgenticExecutionCapacityScheduler do
  @moduledoc false

  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.DispatchCapacity.{ConformanceFixture, Evaluator}
  alias Orchard.Inference

  @impl true
  def schedule(request, opts) do
    node_id = Application.fetch_env!(:orchard_node_agent, :runtime)[:node_id]

    input = %{
      ConformanceFixture.input()
      | aggregate_active_count: {:valid, 0},
        controller_dispatch_ceiling: {:valid, 1},
        controller_accounted_allocation: 0
    }

    if node_id in Keyword.get(opts, :exclude_node_ids, []) do
      {:error, :cluster_busy}
    else
      {:ok,
       %{
         strategy: :single_node,
         request_id: request.public_id,
         runtime_client_target: Inference.runtime_client_target(),
         request_timeout_ms: Inference.request_timeout_ms(),
         model_load_timeout_ms: Inference.model_load_timeout_ms(),
         node_id: node_id,
         selected_tier: :loaded,
         dispatch_capacity_authority:
           Application.fetch_env!(:orchard_controller, :agentic_execution_fixture)[:authority],
         dispatch_capacity_input: input,
         dispatch_capacity_evaluation: Evaluator.evaluate(input),
         dispatch_capacity_acquisition_input_provider: fn -> input end,
         dispatch_capacity_input_provider: fn -> input end
       }}
    end
  end
end
