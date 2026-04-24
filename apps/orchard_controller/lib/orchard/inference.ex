defmodule Orchard.Inference do
  @moduledoc """
  Controller-side inference supervision subtree and seam lookup helpers.
  """

  use Supervisor

  alias Orchard.Inference.{CacheAffinity, QueueManager}
  alias Orchard.Requests.Supervisor, as: RequestsSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Orchard.Requests.Registry},
      RequestsSupervisor,
      {QueueManager, startup_reconciliation: {:once, queue_manager_boot_token()}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp queue_manager_boot_token do
    {__MODULE__, System.unique_integer([:monotonic, :positive])}
  end

  @spec config() :: keyword()
  def config do
    Application.fetch_env!(:orchard_controller, :inference)
  end

  @spec tokenizer_client() :: module()
  def tokenizer_client do
    config()[:tokenizer_client_impl] || Orchard.Tokenizer.Client
  end

  @spec scheduler() :: module()
  def scheduler do
    configured_scheduler_impl() || auto_scheduler()
  end

  @spec queue_manager() :: module()
  def queue_manager do
    config()[:queue_manager_impl] || QueueManager
  end

  @spec queue_admission_config() :: keyword()
  def queue_admission_config do
    Keyword.merge(default_queue_admission_config(), config()[:queue_admission] || [])
  end

  @spec cache_affinity_config() :: keyword()
  def cache_affinity_config do
    config()
    |> Keyword.get(:cache_affinity, [])
    |> CacheAffinity.normalize_config()
  end

  @spec cache_affinity_enabled?() :: boolean()
  def cache_affinity_enabled? do
    cache_affinity_config()
    |> CacheAffinity.enabled?()
  end

  @spec cache_introspection_config() :: keyword()
  def cache_introspection_config do
    Keyword.merge([enabled: false], config()[:cache_introspection] || [])
  end

  @spec cache_introspection_enabled?() :: boolean()
  def cache_introspection_enabled? do
    cache_introspection_config()[:enabled] == true
  end

  @spec memory_admission_config() :: keyword()
  def memory_admission_config do
    Keyword.merge([enabled: false], config()[:memory_admission] || [])
  end

  @spec memory_admission_enabled?() :: boolean()
  def memory_admission_enabled? do
    memory_admission_config()[:enabled] == true
  end

  @spec queue_admission_enabled?() :: boolean()
  def queue_admission_enabled? do
    config = queue_admission_config()
    config[:enabled] == true and queue_admission_owner?()
  end

  @spec queue_admission_owner?() :: boolean()
  def queue_admission_owner? do
    config = queue_admission_config()
    config[:owner_runtime] == true and config[:single_controller_ack] == true
  end

  @spec configured_scheduler_impl() :: module() | nil
  def configured_scheduler_impl do
    config()[:scheduler_impl]
  end

  @spec request_supervisor() :: module()
  def request_supervisor, do: RequestsSupervisor

  @spec artifacts_root() :: String.t() | nil
  def artifacts_root, do: config()[:artifacts_root]
  @spec tokenizer_mode() :: atom() | nil
  def tokenizer_mode, do: config()[:tokenizer_mode]

  @spec tokenizer_executable() :: String.t() | nil
  def tokenizer_executable, do: config()[:tokenizer_executable]

  @spec runtime_client_target() :: keyword() | nil
  def runtime_client_target, do: config()[:runtime_client_target]

  @spec runtime_client_targets() :: [keyword()]
  def runtime_client_targets do
    case config()[:runtime_client_targets] do
      targets when is_list(targets) and targets != [] -> dedup_targets(targets)
      _ -> [runtime_client_target()]
    end
  end

  @spec request_timeout_ms() :: pos_integer() | nil
  def request_timeout_ms, do: config()[:request_timeout_ms]

  @spec model_load_timeout_ms() :: pos_integer()
  def model_load_timeout_ms, do: config()[:model_load_timeout_ms] || 120_000

  @spec node_freshness_threshold_ms() :: pos_integer()
  def node_freshness_threshold_ms, do: config()[:node_freshness_threshold_ms] || 30_000

  @spec node_unreachable_threshold_ms() :: pos_integer()
  def node_unreachable_threshold_ms, do: config()[:node_unreachable_threshold_ms] || 15_000

  defp default_queue_admission_config do
    [
      enabled: false,
      max_wait_ms: 3_000,
      max_queued_per_tenant: 32,
      poll_interval_ms: 100,
      capacity: 1,
      owner_runtime: false,
      single_controller_ack: false
    ]
  end

  defp auto_scheduler do
    case runtime_client_targets() do
      targets when length(targets) > 1 -> Orchard.Scheduler.MultiNode
      _ -> Orchard.Scheduler.SingleNode
    end
  end

  defp dedup_targets(targets) do
    Enum.uniq_by(targets, fn target ->
      {Keyword.get(target, :host), Keyword.get(target, :port)}
    end)
  end
end
