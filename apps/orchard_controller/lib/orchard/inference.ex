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

  @spec prefix_cache_scoring_config() :: keyword()
  def prefix_cache_scoring_config do
    Keyword.merge(
      [enabled: false, timeout_ms: 150, ranking_mode: :observe_only, max_ranking_candidates: 2],
      config()[:prefix_cache_scoring] || []
    )
  end

  @spec prefix_cache_scoring_enabled?() :: boolean()
  def prefix_cache_scoring_enabled? do
    scoring_enabled? = prefix_cache_scoring_config()[:enabled] == true

    scoring_enabled? and
      cache_affinity_enabled?() and
      CacheAffinity.live_fingerprint_match_enabled?(cache_affinity_config())
  end

  @spec prefix_cache_scoring_ranking_mode() :: :observe_only | :tie_only
  def prefix_cache_scoring_ranking_mode do
    case prefix_cache_scoring_config()[:ranking_mode] do
      :observe_only -> :observe_only
      "observe_only" -> :observe_only
      :tie_only -> :tie_only
      "tie_only" -> :tie_only
      _other -> :observe_only
    end
  end

  @spec prefix_cache_scoring_ranking_active?() :: boolean()
  def prefix_cache_scoring_ranking_active? do
    prefix_cache_scoring_enabled?() and prefix_cache_scoring_ranking_mode() == :tie_only
  end

  # `1` is intentionally allowed as a diagnostic soft-disable for tie-only challenger scoring;
  # values above `2` are accepted but the effective runtime cap for this slice is `2`.
  @spec prefix_cache_scoring_max_ranking_candidates() :: pos_integer()
  def prefix_cache_scoring_max_ranking_candidates do
    case prefix_cache_scoring_config()[:max_ranking_candidates] do
      max_candidates when is_integer(max_candidates) and max_candidates > 0 ->
        min(max_candidates, 2)

      _other ->
        2
    end
  end

  @spec prefix_cache_scoring_timeout_ms() :: pos_integer()
  def prefix_cache_scoring_timeout_ms do
    case prefix_cache_scoring_config()[:timeout_ms] do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> 150
    end
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

  @spec tokenizer_safe_mode() :: :off | :on | :reject
  def tokenizer_safe_mode do
    case config()[:tokenizer_safe_mode] || :off do
      :off ->
        :off

      "off" ->
        :off

      :on ->
        :on

      "on" ->
        :on

      :reject ->
        :reject

      "reject" ->
        :reject

      other ->
        raise ArgumentError,
              "Orchard inference tokenizer_safe_mode must be :off, :on, or :reject, got: #{inspect(other)}"
    end
  end

  @spec tokenizer_safe_mode_prefer_capable_workers?() :: boolean()
  def tokenizer_safe_mode_prefer_capable_workers? do
    config()[:tokenizer_safe_mode_prefer_capable] == true
  end

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
      tenant_default_weight: 1,
      tenant_weights: %{},
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
