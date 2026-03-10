defmodule Orchard.Dispatch.NodeRuntimeClient do
  @moduledoc """
  Injectable seam for controller dispatch into the node runtime boundary.

  **Deprecated:** This module retains the R1-era callback/injectable pattern
  for tests that need a lightweight fake. Real dispatch goes through
  `RequestDispatcher` which uses `GrpcNodeRuntimeClient` directly.
  Scheduled for removal after M1.
  """

  @callback status() :: {:ok, map()} | {:error, term()}
  @callback ensure_model_loaded(term()) :: {:ok, map()} | {:error, term()}
  @callback execute_inference(term()) :: {:ok, map()} | {:error, term()}
  @callback cancel_inference(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}

  def status do
    case Orchard.Inference.node_runtime_client() do
      __MODULE__ -> default_status()
      module -> module.status()
    end
  end

  def ensure_model_loaded(request) do
    case Orchard.Inference.node_runtime_client() do
      __MODULE__ -> default_ensure_model_loaded(request)
      module -> module.ensure_model_loaded(request)
    end
  end

  def execute_inference(request) do
    case Orchard.Inference.node_runtime_client() do
      __MODULE__ -> default_execute_inference(request)
      module -> module.execute_inference(request)
    end
  end

  def cancel_inference(request_id, controller_session_id \\ nil) do
    case Orchard.Inference.node_runtime_client() do
      __MODULE__ -> default_cancel_inference(request_id, controller_session_id)
      module -> module.cancel_inference(request_id, controller_session_id)
    end
  end

  def target, do: Orchard.Inference.runtime_client_target()

  defp default_status do
    {:ok, %{target: target(), status: :not_connected}}
  end

  defp default_ensure_model_loaded(_request), do: {:error, :not_implemented}
  defp default_execute_inference(_request), do: {:error, :not_implemented}

  defp default_cancel_inference(request_id, controller_session_id) do
    {:ok,
     %{
       request_id: request_id,
       controller_session_id: controller_session_id,
       cancelled: false,
       reason: :not_implemented
     }}
  end
end
