defmodule Orchard.Node do
  @moduledoc """
  Runtime configuration helpers for the node-agent inference boundary.
  """

  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Licensing
  alias Orchard.Node.{FakeRuntimeAdapter, WorkerRuntimeAdapter}

  @default_worker_executable "orchard-worker-mlx"
  @default_worker_backend "mlx"
  @default_worker_ready_timeout_ms 5_000
  @default_worker_load_timeout_ms 120_000
  @default_worker_shutdown_timeout_ms 1_000
  @default_worker_prefix_cache_mode "kv"
  @default_worker_prefix_cache_max_entries 8
  @default_worker_prefix_cache_max_bytes 0
  @default_worker_generation_mode "batch"
  @default_worker_max_concurrent_requests_per_model "auto"
  @default_worker_auto_max_concurrent_requests_per_model 3
  @default_worker_memory_budget_mode "observe"
  @default_worker_memory_budget_utilization 0.90
  @default_worker_memory_budget_overhead_bytes 1_073_741_824
  @worker_socket_prefix "orchard-worker-"
  @worker_socket_suffix ".sock"
  @worker_log_prefix "orchard-worker-"
  @worker_log_suffix ".log"
  @worker_identity_hash_length 16

  def runtime_config do
    Application.fetch_env!(:orchard_node_agent, :runtime)
  end

  # --- Node identity and metadata helpers ---

  @doc "Returns the resolved node UUID. Available after Identity.ensure_identity!/0."
  def node_id, do: runtime_config()[:node_id]

  @doc "Returns the configured display name, or falls back to hostname."
  def display_name do
    case runtime_config()[:display_name] do
      name when is_binary(name) and name != "" -> name
      _ -> hostname()
    end
  end

  @doc "Returns the OS hostname, falling back to listen_host_string on error."
  def hostname do
    case :net_adm.localhost() do
      name when is_list(name) -> List.to_string(name)
    end
  end

  @doc "Returns the node-agent version string."
  def agent_version, do: Orchard.NodeAgent.version()

  @doc "Returns the listen host as a string suitable for proto metadata."
  def listen_host_string do
    case listen_host() do
      host when is_binary(host) ->
        host

      addr when is_tuple(addr) ->
        # Handles both IPv4 {a,b,c,d} and IPv6 {a,b,c,d,e,f,g,h} tuples
        addr |> :inet.ntoa() |> List.to_string()

      other ->
        to_string(other)
    end
  end

  # --- Existing config helpers ---

  def listen_address, do: runtime_config()[:listen_address]
  def node_identity_root, do: runtime_config()[:node_identity_root]
  def grpc_security, do: runtime_config()[:grpc_security] || :plaintext_compatibility
  def listen_host, do: listen_address()[:host]
  def listen_port, do: listen_address()[:port]
  def models_root, do: runtime_config()[:models_root]
  def worker_socket_dir, do: runtime_config()[:worker_socket_dir]
  def worker_executable, do: runtime_config()[:worker_executable] || @default_worker_executable
  def worker_backend, do: runtime_config()[:worker_backend] || @default_worker_backend

  def worker_ready_timeout_ms do
    runtime_config()[:worker_ready_timeout_ms] || @default_worker_ready_timeout_ms
  end

  def worker_load_timeout_ms do
    runtime_config()[:worker_load_timeout_ms] || @default_worker_load_timeout_ms
  end

  def worker_shutdown_timeout_ms do
    runtime_config()[:worker_shutdown_timeout_ms] || @default_worker_shutdown_timeout_ms
  end

  def fake_runtime?, do: runtime_config()[:fake_runtime?]

  @spec max_loaded_models() :: pos_integer() | nil
  def max_loaded_models do
    case runtime_config()[:max_loaded_models] do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  def hf_config, do: runtime_config()[:hf] || []

  def s3_config, do: runtime_config()[:s3] || []

  def runtime_adapter_impl do
    runtime_config()[:runtime_adapter_impl] || default_runtime_adapter_impl()
  end

  @spec license_enforcement() :: Licensing.enforcement()
  def license_enforcement, do: Licensing.enforcement_mode()

  @spec licensing_impl() :: module()
  def licensing_impl do
    runtime_config()[:licensing_impl] || Licensing
  end

  def worker_prefix_cache_mode do
    case runtime_value(:worker_prefix_cache_mode, @default_worker_prefix_cache_mode) do
      mode when mode in ["disabled", "kv", "trie"] -> mode
      other -> raise "invalid worker_prefix_cache_mode: #{inspect(other)}"
    end
  end

  def worker_prefix_cache_max_entries do
    case runtime_value(
           :worker_prefix_cache_max_entries,
           @default_worker_prefix_cache_max_entries
         ) do
      n when is_integer(n) and n >= 1 -> n
      other -> raise "invalid worker_prefix_cache_max_entries: #{inspect(other)}"
    end
  end

  def worker_prefix_cache_max_bytes do
    case runtime_value(:worker_prefix_cache_max_bytes, @default_worker_prefix_cache_max_bytes) do
      n when is_integer(n) and n >= 0 -> n
      other -> raise "invalid worker_prefix_cache_max_bytes: #{inspect(other)}"
    end
  end

  def worker_generation_mode do
    case runtime_value(:worker_generation_mode, @default_worker_generation_mode) do
      mode when mode in ["stream", "batch"] -> mode
      other -> raise "invalid worker_generation_mode: #{inspect(other)}"
    end
  end

  def worker_max_concurrent_requests_per_model do
    case runtime_value(
           :worker_max_concurrent_requests_per_model,
           @default_worker_max_concurrent_requests_per_model
         ) do
      "auto" ->
        "auto"

      n when is_integer(n) and n >= 1 ->
        n

      n when is_binary(n) ->
        parse_positive_int_string(n, :worker_max_concurrent_requests_per_model)

      other ->
        raise "invalid worker_max_concurrent_requests_per_model: #{inspect(other)}"
    end
  end

  def worker_auto_max_concurrent_requests_per_model do
    case runtime_value(
           :worker_auto_max_concurrent_requests_per_model,
           @default_worker_auto_max_concurrent_requests_per_model
         ) do
      n when is_integer(n) and n >= 1 ->
        n

      n when is_binary(n) ->
        parse_positive_int_string(n, :worker_auto_max_concurrent_requests_per_model)

      other ->
        raise "invalid worker_auto_max_concurrent_requests_per_model: #{inspect(other)}"
    end
  end

  def effective_worker_request_limit do
    case runtime_adapter_impl() do
      WorkerRuntimeAdapter ->
        request_limit_for_generation_mode(worker_generation_mode())

      _other ->
        batch_admission? =
          runtime_value(:test_only_allow_batch_admission_for_non_worker_adapters?, false) == true

        if batch_admission? do
          request_limit_for_generation_mode(worker_generation_mode())
        else
          1
        end
    end
  end

  defp request_limit_for_generation_mode("batch") do
    case worker_max_concurrent_requests_per_model() do
      "auto" -> worker_auto_max_concurrent_requests_per_model()
      n -> n
    end
  end

  defp request_limit_for_generation_mode(_mode), do: 1

  defp parse_positive_int_string(value, config_key) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> n
      _other -> raise "invalid #{config_key}: #{inspect(value)}"
    end
  end

  def worker_memory_budget_mode do
    case runtime_value(:worker_memory_budget_mode, @default_worker_memory_budget_mode) do
      mode when mode in ["disabled", "observe", "enforce"] -> mode
      other -> raise "invalid worker_memory_budget_mode: #{inspect(other)}"
    end
  end

  def worker_memory_budget_utilization do
    value =
      runtime_value(:worker_memory_budget_utilization, @default_worker_memory_budget_utilization)

    utilization =
      cond do
        is_float(value) -> value
        is_integer(value) -> value / 1
        true -> raise "invalid worker_memory_budget_utilization: #{inspect(value)}"
      end

    if utilization <= 0.0 or utilization > 1.0 do
      raise "invalid worker_memory_budget_utilization: #{inspect(value)}"
    end

    utilization
  end

  def worker_memory_budget_overhead_bytes do
    case runtime_value(
           :worker_memory_budget_overhead_bytes,
           @default_worker_memory_budget_overhead_bytes
         ) do
      n when is_integer(n) and n >= 0 -> n
      other -> raise "invalid worker_memory_budget_overhead_bytes: #{inspect(other)}"
    end
  end

  def worker_log_dir, do: runtime_config()[:worker_log_dir]

  def worker_socket_path(%ModelRef{model_id: model_id, version: version}) do
    worker_socket_path(model_id, version)
  end

  def worker_socket_path(model_id, version) when is_binary(model_id) and is_binary(version) do
    digest = worker_identity_digest(model_id, version)

    Path.join(
      worker_socket_dir(),
      @worker_socket_prefix <> digest <> @worker_socket_suffix
    )
  end

  def worker_log_path(%ModelRef{model_id: model_id, version: version}) do
    worker_log_path(model_id, version)
  end

  def worker_log_path(model_id, version) when is_binary(model_id) and is_binary(version) do
    digest = worker_identity_digest(model_id, version)

    Path.join(
      worker_log_dir(),
      @worker_log_prefix <> digest <> @worker_log_suffix
    )
  end

  defp worker_identity_digest(model_id, version) do
    :crypto.hash(:sha256, model_id <> "@" <> version)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @worker_identity_hash_length)
  end

  defp runtime_value(key, default) do
    case Keyword.fetch(runtime_config(), key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> default
    end
  end

  defp default_runtime_adapter_impl do
    if fake_runtime?() do
      FakeRuntimeAdapter
    else
      WorkerRuntimeAdapter
    end
  end
end
