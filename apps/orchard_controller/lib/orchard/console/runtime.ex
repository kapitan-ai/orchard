defmodule OrchardConsole.Runtime do
  @moduledoc """
  Console-facing wrapper for controller → node runtime status snapshots.

  Wraps the configured Runtime Endpoint client connect/status/disconnect flow
  into a single `snapshot/0` call that normalizes endpoint observations or
  legacy status responses, sorts loaded models, and returns operator-safe
  error snapshots.

  The underlying client module is injectable via `:runtime_endpoint_client_impl`
  or the legacy `:runtime_client_impl` in the `:orchard_controller, :console`
  config for testing.
  """

  alias Orchard.Inference
  alias Orchard.Runtime.PrefixCacheStatus
  alias Orchard.RuntimeEndpoint.{Observation, Placement, Target}

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

  @type runtime_memory_budget :: %{
          display_state: :observed | :invalid,
          model_ref: String.t(),
          mode: String.t(),
          budget_available: boolean() | nil,
          headroom_available: boolean() | nil,
          status_code: String.t(),
          status_message: String.t() | nil,
          target_working_set_bytes: non_neg_integer() | nil,
          resident_memory_bytes: non_neg_integer() | nil,
          kv_cache_bytes_per_token: non_neg_integer() | nil,
          prefill_workspace_bytes_per_token: non_neg_integer() | nil
        }

  @type snapshot :: %{
          worker_state: worker_state(),
          loaded_models: [loaded_model()],
          active_request_count: non_neg_integer(),
          node_metadata: node_metadata() | nil,
          runtime_health: runtime_health() | nil,
          supports_prompt_token_ids: boolean(),
          runtime_memory_budgets: [runtime_memory_budget()],
          runtime_memory_budgets_truncated_count: non_neg_integer(),
          runtime_prefix_cache_statuses: [PrefixCacheStatus.t()]
        }

  @type error_snapshot :: %{
          status: :unavailable | :timeout | :error,
          code: String.t(),
          message: String.t(),
          worker_state: :unknown,
          loaded_models: [],
          active_request_count: 0,
          node_metadata: nil,
          runtime_health: nil,
          supports_prompt_token_ids: false,
          runtime_memory_budgets: [],
          runtime_memory_budgets_truncated_count: 0,
          runtime_prefix_cache_statuses: []
        }

  @doc """
  Fetches a runtime status snapshot from the configured node.

  On success, also performs a best-effort `Orchard.Nodes.observe_status/3`
  to update trusted node inventory or record an admission candidate, and to
  refresh queue capacity.
  Observation failures never convert a successful status read into an error
  snapshot.

  Returns `{:ok, snapshot}` on success or `{:error, error_snapshot}` with
  an operator-safe error description on failure. Never raises for expected
  transport/gRPC errors.
  """
  @spec snapshot() :: {:ok, snapshot()} | {:error, error_snapshot()}
  def snapshot, do: snapshot([])

  @type cluster_target_snapshot :: %{
          target: Target.t() | keyword(),
          status: :ok | :unavailable | :timeout | :error,
          message: String.t() | nil,
          worker_state: worker_state(),
          loaded_models: [loaded_model()],
          active_request_count: non_neg_integer(),
          node_metadata: node_metadata() | nil,
          runtime_health: runtime_health() | nil,
          supports_prompt_token_ids: boolean(),
          runtime_memory_budgets: [runtime_memory_budget()],
          runtime_memory_budgets_truncated_count: non_neg_integer(),
          runtime_prefix_cache_statuses: [PrefixCacheStatus.t()]
        }

  @doc """
  Probes all configured runtime targets and returns an ordered list of snapshots.

  Each entry corresponds to one target from `Inference.runtime_endpoint_targets/0`.
  Successful probes trigger best-effort `observe_status/3` via the existing
  `snapshot/1` path, including queue capacity refresh.
  Per-target failures are isolated - one failed target never aborts the cluster
  result.

  Options:
  - `:targets` - explicit ordered target list (default: `Inference.runtime_endpoint_targets/0`)
  - `:observed_at` - shared timestamp for all probes (default: `DateTime.utc_now()`)
  - `:timeout` - forwarded to each `snapshot/1` call
  """
  @spec cluster_snapshot() :: [cluster_target_snapshot()]
  def cluster_snapshot, do: cluster_snapshot([])

  @spec cluster_snapshot(keyword()) :: [cluster_target_snapshot()]
  def cluster_snapshot(opts) do
    targets = Keyword.get_lazy(opts, :targets, &Inference.runtime_endpoint_targets/0)
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
      runtime_health: nil,
      supports_prompt_token_ids: false,
      runtime_memory_budgets: [],
      runtime_memory_budgets_truncated_count: 0,
      runtime_prefix_cache_statuses: []
    }
  end

  @doc """
  Fetches a runtime status snapshot with optional overrides.

  Options:
  - `:target` - override runtime target (default: first Runtime Endpoint target)
  - `:observed_at` - override observation timestamp (default: `DateTime.utc_now()`)
  - `:timeout` - status RPC timeout in milliseconds (default: client default)
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, error_snapshot()}
  def snapshot(opts) do
    target = Keyword.get_lazy(opts, :target, &default_runtime_target/0)
    {client, client_target} = runtime_client(target)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    status_opts = if timeout = opts[:timeout], do: [timeout: timeout], else: []

    snapshot_target(client, target, client_target, observed_at, status_opts)
  end

  defp default_runtime_target do
    case Inference.runtime_endpoint_targets() do
      [target | _] -> target
      [] -> nil
    end
  end

  defp snapshot_target(_client, nil, _client_target, _observed_at, _status_opts) do
    {:error,
     error_snapshot(:error, "runtime_target_unconfigured", "runtime target is not configured")}
  end

  defp snapshot_target(client, target, client_target, observed_at, status_opts) do
    case safe_connect(client, client_target, target) do
      {:ok, channel} ->
        read_target_status(client, channel, target, observed_at, status_opts)

      {:error, reason} ->
        {:error, error_snapshot_for(reason)}
    end
  end

  defp read_target_status(client, channel, target, observed_at, status_opts) do
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

  # ---------------------------------------------------------------------------
  # Safe transport wrappers
  #
  # Runtime client calls can exit (e.g., GenServer call to a dead process) or
  # raise unexpectedly. These wrappers ensure transport-layer instability
  # is always converted to tagged error tuples so callers never crash.
  # ---------------------------------------------------------------------------

  defp safe_connect(client, client_target, target) do
    client.connect(client_target)
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
  catch
    kind, reason ->
      require Logger
      Logger.warning("Node observation #{kind} during runtime snapshot: #{inspect(reason)}")
      :noop
  end

  # ---------------------------------------------------------------------------
  # Response normalization
  # ---------------------------------------------------------------------------

  defp normalize_response(%Observation{} = observation) do
    %{
      worker_state: normalize_worker_state(observation.worker_state),
      loaded_models: normalize_observation_loaded_models(observation),
      active_request_count: normalize_count(observation.aggregate_active_request_count),
      node_metadata: normalize_node_metadata(observation),
      runtime_health: normalize_runtime_health(observation),
      supports_prompt_token_ids: observation.supports_prompt_token_ids == true,
      runtime_memory_budgets: normalize_runtime_memory_budgets(observation),
      runtime_memory_budgets_truncated_count: runtime_memory_budgets_truncated_count(observation),
      runtime_prefix_cache_statuses: normalize_runtime_prefix_cache_statuses(observation)
    }
  end

  defp normalize_response(response) do
    %{
      worker_state: normalize_worker_state(response.worker_state),
      loaded_models: normalize_loaded_models(response.loaded_models),
      active_request_count: normalize_count(response.active_request_count),
      node_metadata: normalize_node_metadata(response),
      runtime_health: normalize_runtime_health(response),
      supports_prompt_token_ids: supports_prompt_token_ids?(response),
      runtime_memory_budgets: normalize_runtime_memory_budgets(response),
      runtime_memory_budgets_truncated_count: runtime_memory_budgets_truncated_count(response),
      runtime_prefix_cache_statuses: normalize_runtime_prefix_cache_statuses(response)
    }
  end

  # Atom enum values from generated protobuf
  defp normalize_worker_state(:WORKER_STATE_STARTING), do: :starting
  defp normalize_worker_state(:WORKER_STATE_IDLE), do: :idle
  defp normalize_worker_state(:WORKER_STATE_BUSY), do: :busy
  defp normalize_worker_state(:WORKER_STATE_STOPPING), do: :stopping
  defp normalize_worker_state(:WORKER_STATE_FAILED), do: :failed
  defp normalize_worker_state(:WORKER_STATE_STOPPED), do: :stopped
  defp normalize_worker_state(state) when state in [:starting, :idle, :busy], do: state
  defp normalize_worker_state(state) when state in [:stopping, :failed, :stopped], do: state
  defp normalize_worker_state(:unknown), do: :unknown
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

  defp normalize_observation_loaded_models(%Observation{placements: placements})
       when is_list(placements) do
    placements
    |> Enum.filter(&Placement.loaded?/1)
    |> Enum.map(&loaded_model_from_placement/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{&1.model_id, &1.version})
  end

  defp normalize_observation_loaded_models(_observation), do: []

  defp loaded_model_from_placement(%Placement{model_ref: %{model_id: model_id, version: version}})
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "" do
    %{model_id: model_id, version: version}
  end

  defp loaded_model_from_placement(_placement), do: nil

  defp normalize_count(n) when is_integer(n) and n >= 0, do: n
  defp normalize_count(_), do: 0

  defp supports_prompt_token_ids?(%{supports_prompt_token_ids: true}), do: true
  defp supports_prompt_token_ids?(%{"supports_prompt_token_ids" => true}), do: true
  defp supports_prompt_token_ids?(_), do: false

  # ---------------------------------------------------------------------------
  # Node metadata / runtime health normalization
  # ---------------------------------------------------------------------------

  defp normalize_node_metadata(%Observation{metadata: metadata}) when metadata == %{}, do: nil

  defp normalize_node_metadata(%Observation{metadata: metadata}) when is_map(metadata),
    do: do_normalize_metadata(metadata)

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

  defp normalize_runtime_health(%Observation{health: health}) when health == %{}, do: nil

  defp normalize_runtime_health(%Observation{health: health}) when is_map(health),
    do: do_normalize_health(health)

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
  # Observe-only runtime memory budget normalization
  # ---------------------------------------------------------------------------

  @memory_budget_limit 20
  @max_model_ref_length 160
  @max_mode_length 40
  @max_status_code_length 80
  @max_status_message_length 240

  defp normalize_runtime_memory_budgets(response) do
    case Map.get(response, :runtime_memory_budgets, []) do
      budgets when is_list(budgets) ->
        budgets
        |> Enum.take(@memory_budget_limit)
        |> Enum.map(&normalize_runtime_memory_budget/1)

      _ ->
        []
    end
  end

  defp runtime_memory_budgets_truncated_count(response) do
    case Map.get(response, :runtime_memory_budgets, []) do
      budgets when is_list(budgets) ->
        max(length(budgets) - @memory_budget_limit, 0)

      _ ->
        0
    end
  end

  defp normalize_runtime_prefix_cache_statuses(response) do
    case Map.get(response, :runtime_prefix_cache_statuses, []) do
      statuses when is_list(statuses) ->
        statuses
        |> Enum.map(&PrefixCacheStatus.normalize/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_runtime_memory_budget(budget) when is_map(budget) do
    %{
      display_state: :observed,
      model_ref: normalize_budget_model_ref(Map.get(budget, :model_ref)),
      mode: bounded_string(Map.get(budget, :mode), "unknown", @max_mode_length),
      budget_available: normalize_budget_boolean(Map.get(budget, :budget_available)),
      headroom_available: normalize_budget_boolean(Map.get(budget, :headroom_available)),
      status_code:
        bounded_string(Map.get(budget, :status_code), "unreported", @max_status_code_length),
      status_message:
        bounded_optional_string(Map.get(budget, :status_message), @max_status_message_length),
      target_working_set_bytes:
        normalize_budget_integer(Map.get(budget, :target_working_set_bytes)),
      resident_memory_bytes: normalize_budget_integer(Map.get(budget, :resident_memory_bytes)),
      kv_cache_bytes_per_token:
        normalize_budget_integer(Map.get(budget, :kv_cache_bytes_per_token)),
      prefill_workspace_bytes_per_token:
        normalize_budget_integer(Map.get(budget, :prefill_workspace_bytes_per_token))
    }
  end

  defp normalize_runtime_memory_budget(_budget) do
    %{
      display_state: :invalid,
      model_ref: "unknown model",
      mode: "unknown",
      budget_available: nil,
      headroom_available: nil,
      status_code: "invalid_status",
      status_message: "memory budget telemetry payload was malformed",
      target_working_set_bytes: nil,
      resident_memory_bytes: nil,
      kv_cache_bytes_per_token: nil,
      prefill_workspace_bytes_per_token: nil
    }
  end

  defp normalize_budget_model_ref(value) do
    case budget_model_ref_label(value) do
      nil -> "unknown model"
      label -> String.slice(label, 0, @max_model_ref_length)
    end
  end

  defp budget_model_ref_label(%{model_id: id, version: version})
       when is_binary(id) and id != "" and is_binary(version) and version != "",
       do: "#{id}@#{version}"

  defp budget_model_ref_label(%{model_id: id}) when is_binary(id) and id != "", do: id
  defp budget_model_ref_label(value) when is_binary(value) and value != "", do: value
  defp budget_model_ref_label(_), do: nil

  defp normalize_budget_boolean(value) when is_boolean(value), do: value
  defp normalize_budget_boolean(_), do: nil

  defp normalize_budget_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_budget_integer(_), do: nil

  defp bounded_string(value, _fallback, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  defp bounded_string(_value, fallback, _limit), do: fallback

  defp bounded_optional_string(value, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  defp bounded_optional_string(_value, _limit), do: nil

  # ---------------------------------------------------------------------------
  # Error snapshots
  # ---------------------------------------------------------------------------

  defp error_snapshot_for({:connect_failed, _reason}),
    do: error_snapshot(:unavailable, "node_unavailable", "node runtime is unavailable")

  defp error_snapshot_for(:node_unavailable),
    do: error_snapshot(:unavailable, "node_unavailable", "node runtime is unavailable")

  defp error_snapshot_for(:node_timeout),
    do: error_snapshot(:timeout, "node_timeout", "node status request timed out")

  defp error_snapshot_for(:beam_distribution_unavailable),
    do:
      error_snapshot(
        :unavailable,
        "beam_distribution_unavailable",
        "BEAM distribution is unavailable"
      )

  defp error_snapshot_for(:beam_distribution_disabled),
    do:
      error_snapshot(
        :unavailable,
        "beam_distribution_disabled",
        "BEAM distribution is disabled"
      )

  defp error_snapshot_for(:unknown_beam_node),
    do: error_snapshot(:unavailable, "unknown_beam_node", "BEAM node is unavailable")

  defp error_snapshot_for({:unsupported_transport, _transport}),
    do: error_snapshot(:error, "unsupported_runtime_transport", "node status request failed")

  defp error_snapshot_for({:beam_rpc_error, _reason}),
    do: error_snapshot(:error, "beam_rpc_error", "node status request failed")

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
      runtime_health: nil,
      supports_prompt_token_ids: false,
      runtime_memory_budgets: [],
      runtime_memory_budgets_truncated_count: 0,
      runtime_prefix_cache_statuses: []
    }
  end

  # ---------------------------------------------------------------------------
  # Config seam
  # ---------------------------------------------------------------------------

  defp runtime_client(%Target{transport: :beam} = target) do
    console_config = Application.get_env(:orchard_controller, :console, [])

    client =
      console_config[:runtime_endpoint_client_impl] ||
        Inference.runtime_endpoint_client()

    {client, target}
  end

  defp runtime_client(%Target{transport: :grpc_compat, address: address} = target) do
    console_config = Application.get_env(:orchard_controller, :console, [])

    cond do
      client = console_config[:runtime_endpoint_client_impl] ->
        {client, target}

      client = console_config[:runtime_client_impl] ->
        {client, address}

      true ->
        {Inference.runtime_endpoint_client(), target}
    end
  end

  defp runtime_client(target) do
    console_config = Application.get_env(:orchard_controller, :console, [])

    cond do
      client = console_config[:runtime_endpoint_client_impl] ->
        {client, target}

      client = console_config[:runtime_client_impl] ->
        {client, target}

      true ->
        {Inference.runtime_endpoint_client(), target}
    end
  end

  defp nodes_impl do
    Application.get_env(:orchard_controller, :console, [])
    |> Keyword.get(:nodes_impl, Orchard.Nodes)
  end
end
