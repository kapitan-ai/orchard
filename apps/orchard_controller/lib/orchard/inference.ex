defmodule Orchard.Inference do
  @moduledoc """
  Controller-side inference supervision subtree and seam lookup helpers.
  """

  use Supervisor

  alias Orchard.Requests.Supervisor, as: RequestsSupervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Orchard.Requests.Registry},
      RequestsSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def config do
    Application.fetch_env!(:orchard_controller, :inference)
  end

  def tokenizer_client do
    config()[:tokenizer_client_impl] || Orchard.Tokenizer.Client
  end

  def scheduler do
    configured_scheduler_impl() || auto_scheduler()
  end

  def configured_scheduler_impl do
    config()[:scheduler_impl]
  end

  def request_supervisor, do: RequestsSupervisor

  def artifacts_root, do: config()[:artifacts_root]
  def tokenizer_mode, do: config()[:tokenizer_mode]
  def tokenizer_executable, do: config()[:tokenizer_executable]
  def runtime_client_target, do: config()[:runtime_client_target]

  def runtime_client_targets do
    case config()[:runtime_client_targets] do
      targets when is_list(targets) and targets != [] -> dedup_targets(targets)
      _ -> [runtime_client_target()]
    end
  end

  def request_timeout_ms, do: config()[:request_timeout_ms]
  def model_load_timeout_ms, do: config()[:model_load_timeout_ms] || 120_000
  def node_freshness_threshold_ms, do: config()[:node_freshness_threshold_ms] || 30_000
  def node_unreachable_threshold_ms, do: config()[:node_unreachable_threshold_ms] || 15_000

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
