defmodule Orchard.Scheduler.SingleNode do
  @moduledoc """
  Injectable single-node scheduling seam for M1.
  """

  alias Orchard.CanonicalRequest

  @callback schedule(CanonicalRequest.t()) :: {:ok, map()} | {:error, term()}

  def schedule(%CanonicalRequest{} = request) do
    case Orchard.Inference.scheduler() do
      __MODULE__ -> default_schedule(request)
      module -> module.schedule(request)
    end
  end

  def target, do: Orchard.Inference.runtime_client_target()

  defp default_schedule(%CanonicalRequest{} = request) do
    target = target()
    node_id = resolve_node_id(target)

    {:ok,
     %{
       strategy: :single_node,
       request_id: request.public_id,
       runtime_client_target: target,
       request_timeout_ms: Orchard.Inference.request_timeout_ms(),
       model_load_timeout_ms: Orchard.Inference.model_load_timeout_ms(),
       node_id: node_id
     }}
  end

  defp resolve_node_id(target) do
    case Orchard.Nodes.lookup_by_target(target) do
      %{id: id} -> id
      nil -> nil
    end
  rescue
    _ -> nil
  end
end
