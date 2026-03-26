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

  @type node_metadata :: %{
          node_id: String.t() | nil,
          display_name: String.t() | nil,
          hostname: String.t() | nil,
          listen_host: String.t() | nil,
          listen_port: pos_integer() | nil,
          agent_version: String.t() | nil,
          worker_backend: String.t() | nil
        }

  @type runtime_health :: %{
          ready: boolean(),
          health_code: String.t() | nil,
          health_message: String.t() | nil,
          affected_model: String.t() | nil
        }

  @type snapshot :: %{
          worker_state: worker_state(),
          loaded_models: [loaded_model()],
          active_request_count: non_neg_integer(),
          node_metadata: node_metadata() | nil,
          runtime_health: runtime_health() | nil
        }

  @type error_snapshot :: %{
          status: :unavailable | :timeout | :error,
          code: String.t(),
          message: String.t(),
          worker_state: :unknown,
          loaded_models: [],
          active_request_count: 0,
          node_metadata: nil,
          runtime_health: nil
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

  @type cluster_target_snapshot :: %{
          target: keyword(),
          status: :ok | :unavailable | :timeout | :error,
          message: String.t() | nil,
          worker_state: worker_state(),
          loaded_models: [loaded_model()],
          active_request_count: non_neg_integer(),
          node_metadata: node_metadata() | nil,
          runtime_health: runtime_health() | nil
        }

  @doc """
  Probes all configured runtime targets and returns an ordered list of snapshots.

  Each entry corresponds to one target from `Inference.runtime_client_targets/0`.
  Successful probes trigger best-effort `observe_status/3` via the existing
  `snapshot/1` path. Per-target failures are isolated — one failed target
  never aborts the cluster result.

  Options:
  - `:targets` — explicit ordered target list (default: `Inference.runtime_client_targets/0`)
  - `:observed_at` — shared timestamp for all probes (default: `DateTime.utc_now()`)
  - `:timeout` — forwarded to each `snapshot/1` call
  """
  @spec cluster_snapshot() :: [cluster_target_snapshot()]
  def cluster_snapshot, do: cluster_snapshot([])

  @spec cluster_snapshot(keyword()) :: [cluster_target_snapshot()]
  def cluster_snapshot(opts) do
    targets = Keyword.get(opts, :targets, Inference.runtime_client_targets())
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    timeout = opts[:timeout]

    Enum.map(targets, fn target ->
      probe_target(target, observed_at, timeout)
    end)
  end

  defp probe_target(target, observed_at, timeout) do
    snapshot_opts =
      [target: target, observed_at: observed_at]
      |> then(fn o -> if timeout, do: Keyword.put(o, :timeout, timeout), else: o end)

    case snapshot(snapshot_opts) do
      {:ok, snap} ->
        Map.merge(snap, %{target: target, status: :ok, message: nil})

      {:error, error_snap} ->
        Map.merge(error_snap, %{target: target})
    end
  rescue
    error ->
      require Logger
      Logger.warning("Cluster snapshot failed for target #{inspect(target)}: #{inspect(error)}")
      probe_target_error_snapshot(target)
  catch
    kind, reason ->
      require Logger

      Logger.warning("Cluster snapshot #{kind} for target #{inspect(target)}: #{inspect(reason)}")

      probe_target_error_snapshot(target)
  end

  defp probe_target_error_snapshot(target) do
    %{
      target: target,
      status: :error,
      code: "snapshot_exception",
      message: "unexpected error probing target",
      worker_state: :unknown,
      loaded_models: [],
      active_request_count: 0,
      node_metadata: nil,
      runtime_health: nil
    }
  end

  @doc """
  Fetches a runtime status snapshot with optional overrides.

  Options:
  - `:target` — override runtime target (default: from inference config)
  - `:observed_at` — override observation timestamp (default: `DateTime.utc_now()`)
  - `:timeout` — status RPC timeout in milliseconds (default: client default)
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, error_snapshot()}
  def snapshot(opts) do
    client = runtime_client_impl()
    target = Keyword.get(opts, :target, Inference.runtime_client_target())
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    status_opts = if timeout = opts[:timeout], do: [timeout: timeout], else: []

    case safe_connect(client, target) do
      {:ok, channel} ->
        try do
          case safe_status(client, channel, status_opts, target) do
            {:ok, response} ->
              observe_status_best_effort(target, response, observed_at)
              {:ok, normalize_response(response)}

            {:error, reason} ->
              {:error, error_snapshot_for(reason)}
          end
        after
          safe_disconnect(client, channel, target)
        end

      {:error, {:connect_failed, _reason}} ->
        {:error, error_snapshot(:unavailable, "node_unavailable", "node runtime is unavailable")}

      {:error, _reason} ->
        {:error, error_snapshot(:error, "runtime_error", "node status request failed")}
    end
  end

  # ---------------------------------------------------------------------------
  # Safe transport wrappers
  #
  # gRPC client calls can exit (e.g., GenServer call to a dead process) or
  # raise unexpectedly. These wrappers ensure transport-layer instability
  # is always converted to tagged error tuples so callers never crash.
  # ---------------------------------------------------------------------------

  defp safe_connect(client, target) do
    client.connect(target)
  catch
    kind, reason ->
      require Logger

      Logger.warning("Runtime connect #{kind} for #{inspect(target)}: #{inspect(reason)}")

      {:error, {:connect_failed, {:unexpected, kind, reason}}}
  end

  defp safe_status(client, channel, opts, target) do
    client.status(channel, opts)
  catch
    kind, reason ->
      require Logger

      Logger.warning("Runtime status #{kind} for #{inspect(target)}: #{inspect(reason)}")

      {:error, :node_unavailable}
  end

  defp safe_disconnect(client, channel, target) do
    client.disconnect(channel)
  catch
    kind, reason ->
      require Logger

      Logger.warning("Runtime disconnect #{kind} for #{inspect(target)}: #{inspect(reason)}")

      :ok
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
      active_request_count: normalize_count(response.active_request_count),
      node_metadata: normalize_node_metadata(response),
      runtime_health: normalize_runtime_health(response)
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
  # Node metadata / runtime health normalization
  # ---------------------------------------------------------------------------

  defp normalize_node_metadata(%{node_metadata: nil}), do: nil

  defp normalize_node_metadata(%{node_metadata: meta}) when is_map(meta),
    do: do_normalize_metadata(meta)

  defp normalize_node_metadata(_), do: nil

  defp do_normalize_metadata(meta) do
    %{
      node_id: non_empty_string(Map.get(meta, :node_id)),
      display_name: non_empty_string(Map.get(meta, :display_name)),
      hostname: non_empty_string(Map.get(meta, :hostname)),
      listen_host: non_empty_string(Map.get(meta, :listen_host)),
      listen_port: normalize_port(Map.get(meta, :listen_port)),
      agent_version: non_empty_string(Map.get(meta, :agent_version)),
      worker_backend: non_empty_string(Map.get(meta, :worker_backend))
    }
  end

  defp normalize_runtime_health(%{runtime_health: nil}), do: nil

  defp normalize_runtime_health(%{runtime_health: health}) when is_map(health),
    do: do_normalize_health(health)

  defp normalize_runtime_health(_), do: nil

  defp do_normalize_health(health) do
    %{
      ready: Map.get(health, :ready, false) == true,
      health_code: non_empty_string(Map.get(health, :health_code)),
      health_message: non_empty_string(Map.get(health, :health_message)),
      affected_model: normalize_affected_model(Map.get(health, :affected_model))
    }
  end

  # affected_model is a ModelRef (model_id + version), not a plain string.
  # Normalize to display string "model_id@version" for UI/API consumption.
  defp normalize_affected_model(nil), do: nil

  defp normalize_affected_model(%{model_id: id, version: vsn})
       when is_binary(id) and id != "" and is_binary(vsn) and vsn != "",
       do: "#{id}@#{vsn}"

  defp normalize_affected_model(%{model_id: id}) when is_binary(id) and id != "", do: id
  defp normalize_affected_model(value) when is_binary(value) and value != "", do: value
  defp normalize_affected_model(_), do: nil

  defp non_empty_string(value) when is_binary(value) and value != "", do: value
  defp non_empty_string(_), do: nil

  defp normalize_port(port) when is_integer(port) and port in 1..65_535, do: port
  defp normalize_port(_), do: nil

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
      active_request_count: 0,
      node_metadata: nil,
      runtime_health: nil
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
