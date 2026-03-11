defmodule Orchard.Node.FakeRuntimeAdapter do
  @moduledoc """
  Deterministic fake runtime adapter used by tests and early M1 runtime wiring.
  """

  @behaviour Orchard.Node.RuntimeAdapter

  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.InferenceEvent
  alias Orchard.InferenceEvent.Usage

  @impl true
  def load_model(%ModelRef{model_id: "fail-load/" <> _} = _model_ref, _opts) do
    {:error, :simulated_load_failure}
  end

  def load_model(%ModelRef{} = model_ref, _opts) do
    {:ok, %{model_ref: model_ref, generations: %{}}}
  end

  @impl true
  def unload_model(_adapter_state, _opts), do: :ok

  @impl true
  def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    generation_ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        emit_generation(owner, generation_ref, request)
      end)

    generations =
      Map.put(adapter_state.generations, generation_ref, %{pid: pid, owner: owner})

    {:ok, generation_ref, %{adapter_state | generations: generations}}
  end

  @impl true
  def cancel_generation(adapter_state, generation_ref, _opts) do
    case Map.pop(adapter_state.generations, generation_ref) do
      {nil, _generations} ->
        {:ok, adapter_state}

      {%{pid: pid, owner: owner}, generations} ->
        Process.exit(pid, :kill)
        send(owner, {:runtime_adapter_event, generation_ref, cancelled_event()})
        send(owner, {:runtime_adapter_done, generation_ref})
        {:ok, %{adapter_state | generations: generations}}
    end
  end

  @impl true
  def finish_generation(adapter_state, generation_ref, _opts) do
    generations = Map.delete(adapter_state.generations, generation_ref)
    %{adapter_state | generations: generations}
  end

  defp emit_generation(owner, generation_ref, %ExecuteInferenceRequest{} = request) do
    Enum.each(fake_events(request), fn event ->
      send(owner, {:runtime_adapter_event, generation_ref, event})
    end)

    send(owner, {:runtime_adapter_done, generation_ref})
  end

  defp fake_events(%ExecuteInferenceRequest{} = request) do
    usage = %Usage{
      input_tokens: request.input_tokens,
      output_tokens: 2,
      total_tokens: request.input_tokens + 2
    }

    [
      InferenceEvent.output_text_delta("orchard "),
      InferenceEvent.output_text_delta("ready"),
      InferenceEvent.completed(:finish_reason_stop, usage)
    ]
  end

  defp cancelled_event do
    InferenceEvent.failed("cancelled", "request cancelled", false)
  end
end
