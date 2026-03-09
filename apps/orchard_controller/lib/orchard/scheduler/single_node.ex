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
    {:ok,
     %{
       strategy: :single_node,
       request_id: request.public_id,
       runtime_client_target: target(),
       request_timeout_ms: Orchard.Inference.request_timeout_ms()
     }}
  end
end
