defmodule Orchard.Scheduler.SingleNode do
  @moduledoc """
  Injectable single-node scheduling seam for M1.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference

  @callback schedule(CanonicalRequest.t()) :: {:ok, map()} | {:error, term()}

  def schedule(%CanonicalRequest{} = request) do
    case Inference.configured_scheduler_impl() do
      nil -> default_schedule(request)
      __MODULE__ -> default_schedule(request)
      module -> module.schedule(request)
    end
  end

  def target, do: Orchard.Inference.runtime_client_target()

  @doc """
  Build a single-node schedule map directly, without delegation.

  Public so that `MultiNode` can call this as a recursion-safe fallback
  when cluster scheduling is unavailable.

  The 1-arity version uses the configured singular `runtime_client_target`.
  The 2-arity version accepts an explicit target, used by `MultiNode` to
  preserve the actual plural target during fallback.
  """
  def default_schedule(%CanonicalRequest{} = request) do
    default_schedule(request, target())
  end

  def default_schedule(%CanonicalRequest{} = request, target) do
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
