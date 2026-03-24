defmodule OrchardConsole.Runtime do
  @moduledoc """
  Console-facing wrapper for controller → node runtime status snapshots.

  Wraps `Orchard.Dispatch.GrpcNodeRuntimeClient` connect/status/disconnect
  into a single `snapshot/0` call that normalizes protobuf enums, sorts
  loaded models, and returns operator-safe error snapshots.

  The underlying client module is injectable via `:runtime_client_impl`
  in the `:orchard_controller, :console` config for testing.
  """

  alias Orchard.Inference

  @type worker_state :: :starting | :idle | :busy | :stopping | :failed | :stopped | :unknown

  @type loaded_model :: %{model_id: String.t(), version: String.t()}

  @type snapshot :: %{
          worker_state: worker_state(),
          loaded_models: [loaded_model()],
          active_request_count: non_neg_integer()
        }

  @type error_snapshot :: %{
          status: :unavailable | :timeout | :error,
          code: String.t(),
          message: String.t(),
          worker_state: :unknown,
          loaded_models: [],
          active_request_count: 0
        }

  @doc """
  Fetches a runtime status snapshot from the configured node.

  On success, also performs a best-effort `Orchard.Nodes.observe_status/3`
  to persist node inventory data. Observation failures never convert a
  successful status read into an error snapshot.

  Returns `{:ok, snapshot}` on success or `{:error, error_snapshot}` with
  an operator-safe error description on failure. Never raises for expected
  transport/gRPC errors.
  """
  @spec snapshot() :: {:ok, snapshot()} | {:error, error_snapshot()}
  def snapshot, do: snapshot([])

  @doc """
  Fetches a runtime status snapshot with optional overrides.

  Options:
  - `:target` — override runtime target (default: from inference config)
  - `:observed_at` — override observation timestamp (default: `DateTime.utc_now()`)
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, error_snapshot()}
  def snapshot(opts) do
    client = runtime_client_impl()
    target = Keyword.get(opts, :target, Inference.runtime_client_target())
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    case client.connect(target) do
      {:ok, channel} ->
        try do
          case client.status(channel) do
            {:ok, response} ->
              observe_status_best_effort(target, response, observed_at)
              {:ok, normalize_response(response)}

            {:error, reason} ->
              {:error, error_snapshot_for(reason)}
          end
        after
          client.disconnect(channel)
        end

      {:error, {:connect_failed, _reason}} ->
        {:error, error_snapshot(:unavailable, "node_unavailable", "node runtime is unavailable")}

      {:error, _reason} ->
        {:error, error_snapshot(:error, "runtime_error", "node status request failed")}
    end
  end

  defp observe_status_best_effort(target, response, observed_at) do
    nodes_impl().observe_status(target, response, observed_at)
  rescue
    error ->
      require Logger

      Logger.warning("Node observation failed during runtime snapshot: #{inspect(error)}")

      :noop
  end

  # ---------------------------------------------------------------------------
  # Response normalization
  # ---------------------------------------------------------------------------

  defp normalize_response(response) do
    %{
      worker_state: normalize_worker_state(response.worker_state),
      loaded_models: normalize_loaded_models(response.loaded_models),
      active_request_count: normalize_count(response.active_request_count)
    }
  end

  # Atom enum values from generated protobuf
  defp normalize_worker_state(:WORKER_STATE_STARTING), do: :starting
  defp normalize_worker_state(:WORKER_STATE_IDLE), do: :idle
  defp normalize_worker_state(:WORKER_STATE_BUSY), do: :busy
  defp normalize_worker_state(:WORKER_STATE_STOPPING), do: :stopping
  defp normalize_worker_state(:WORKER_STATE_FAILED), do: :failed
  defp normalize_worker_state(:WORKER_STATE_STOPPED), do: :stopped
  # Integer fallbacks for forward compatibility
  defp normalize_worker_state(1), do: :starting
  defp normalize_worker_state(2), do: :idle
  defp normalize_worker_state(3), do: :busy
  defp normalize_worker_state(4), do: :stopping
  defp normalize_worker_state(5), do: :failed
  defp normalize_worker_state(6), do: :stopped
  defp normalize_worker_state(_), do: :unknown

  defp normalize_loaded_models(models) when is_list(models) do
    models
    |> Enum.map(fn model ->
      %{
        model_id: if(is_binary(model.model_id), do: model.model_id, else: ""),
        version: if(is_binary(model.version), do: model.version, else: "")
      }
    end)
    |> Enum.sort_by(&{&1.model_id, &1.version})
  end

  defp normalize_loaded_models(_), do: []

  defp normalize_count(n) when is_integer(n) and n >= 0, do: n
  defp normalize_count(_), do: 0

  # ---------------------------------------------------------------------------
  # Error snapshots
  # ---------------------------------------------------------------------------

  defp error_snapshot_for(:node_unavailable),
    do: error_snapshot(:unavailable, "node_unavailable", "node runtime is unavailable")

  defp error_snapshot_for(:node_timeout),
    do: error_snapshot(:timeout, "node_timeout", "node status request timed out")

  defp error_snapshot_for({:rpc_error, status, _message}) when is_atom(status),
    do: error_snapshot(:error, "rpc_#{status}", "node status request failed")

  defp error_snapshot_for({:rpc_error, _detail}),
    do: error_snapshot(:error, "rpc_error", "node status request failed")

  defp error_snapshot_for(_),
    do: error_snapshot(:error, "runtime_error", "node status request failed")

  defp error_snapshot(status, code, message) do
    %{
      status: status,
      code: code,
      message: message,
      worker_state: :unknown,
      loaded_models: [],
      active_request_count: 0
    }
  end

  # ---------------------------------------------------------------------------
  # Config seam
  # ---------------------------------------------------------------------------

  defp runtime_client_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:runtime_client_impl, Orchard.Dispatch.GrpcNodeRuntimeClient)
  end

  defp nodes_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:nodes_impl, Orchard.Nodes)
  end
end
