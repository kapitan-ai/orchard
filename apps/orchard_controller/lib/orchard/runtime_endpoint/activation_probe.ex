defmodule Orchard.RuntimeEndpoint.ActivationProbe do
  @moduledoc """
  Leader-side status probes for Runtime Endpoint Nodes and configured discovery targets.

  For admitted and active inventory, refreshes authenticated heartbeats and capacity
  evidence on a bounded interval independent of request traffic, and demotes idle Node
  loss through transport failure recording plus a heartbeat-age sweep (ADR 0015 /
  issue #148).

  When trusted admitted/active inventory is empty and static runtime target fallback is
  enabled, also probes configured Runtime Endpoint targets and persists successful
  unauthenticated observations as `pending_observed` admission candidates (issue #192).
  Discovery never auto-admits a Node.
  """

  use GenServer

  require Logger

  alias Orchard.ControlPlane
  alias Orchard.Inference
  alias Orchard.NodeHeartbeats
  alias Orchard.Nodes
  alias Orchard.RuntimeEndpoint.{BeamClient, GrpcCompatibilityClient, Target}

  @default_interval_ms 5_000
  @default_timeout_ms 5_000
  @min_interval_ms 1_000
  @transport_clients [BeamClient, GrpcCompatibilityClient]

  @type result :: %{required(:target_id) => String.t(), required(:status) => :observed}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Configured probe interval in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: configured_interval()

  @doc """
  Asserts the probe interval is strictly below freshness and unreachable thresholds.

  Raises `ArgumentError` when the given interval would void the detection bound.
  `init/1` clamps instead of raising so a threshold misconfiguration degrades
  liveness detection rather than blocking Controller boot. Clamping holds a 1s
  floor; thresholds too small to admit a safe interval fall back to the default
  interval and log an error rather than busy-looping the probe timer.
  """
  @spec assert_interval_contract!(pos_integer()) :: :ok
  def assert_interval_contract!(interval \\ interval_ms())
      when is_integer(interval) and interval > 0 do
    unreachable = Inference.node_unreachable_threshold_ms()
    freshness = Inference.node_freshness_threshold_ms()

    cond do
      interval >= unreachable ->
        raise ArgumentError,
              "activation_probe interval_ms=#{interval} must be < node_unreachable_threshold_ms=#{unreachable}"

      interval >= freshness ->
        raise ArgumentError,
              "activation_probe interval_ms=#{interval} must be < node_freshness_threshold_ms=#{freshness}"

      true ->
        :ok
    end
  end

  @spec run_once(keyword()) :: {:ok, [result()]} | {:error, atom()}
  def run_once(opts \\ []) do
    client = Keyword.get(opts, :client, Inference.runtime_endpoint_client())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    heartbeat_context = Keyword.get(opts, :heartbeat_context, NodeHeartbeats)

    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         true <- allowed_client?(client) do
      trusted_targets =
        Keyword.get_lazy(opts, :targets, fn ->
          Inference.activation_probe_runtime_endpoint_targets()
        end)

      discovery_targets =
        if Keyword.has_key?(opts, :targets) do
          Keyword.get(opts, :discovery_targets, [])
        else
          Keyword.get_lazy(opts, :discovery_targets, fn ->
            Inference.discovery_runtime_endpoint_targets()
          end)
        end

      trusted_results =
        Enum.flat_map(trusted_targets, &probe_target(&1, client, timeout, observed_at, :trusted))

      discovery_results =
        Enum.flat_map(
          discovery_targets,
          &probe_target(&1, client, timeout, observed_at, :discovery)
        )

      _ = Nodes.sweep_stale_node_heartbeats(observed_at)
      safe_prune_heartbeats(heartbeat_context, observed_at)

      {:ok, trusted_results ++ discovery_results}
    else
      false -> {:error, :activation_probe_transport_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    interval =
      opts
      |> Keyword.get(:interval, configured_interval())
      |> contract_safe_interval()

    schedule_probe(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:probe, state) do
    safe_run_once()
    schedule_probe(state.interval)
    {:noreply, state}
  end

  defp safe_run_once do
    case run_once() do
      {:ok, _results} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    exception ->
      Logger.debug("Activation status probe crashed: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("Activation status probe aborted: #{inspect({kind, reason})}")
      :ok
  end

  defp safe_prune_heartbeats(heartbeat_context, observed_at) do
    _ = heartbeat_context.prune_expired(observed_at)
    :ok
  rescue
    exception ->
      Logger.debug("Node heartbeat retention failed: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.debug("Node heartbeat retention aborted: #{inspect({kind, reason})}")
      :ok
  end

  defp probe_target(target, client, timeout, observed_at, mode) do
    case client.connect(target) do
      {:ok, connection} ->
        try do
          case client.status(connection, timeout: timeout) do
            {:ok, observation} ->
              maybe_persist_discovery_observation(mode, target, observation, observed_at)
              [%{target_id: target.id, status: :observed}]

            {:error, reason} ->
              record_probe_failure(mode, target, reason, observed_at)
          end
        after
          disconnect(client, connection)
        end

      {:error, reason} ->
        record_probe_failure(mode, target, reason, observed_at)
    end
  end

  defp maybe_persist_discovery_observation(
         :discovery,
         %Target{transport: :beam} = target,
         observation,
         observed_at
       ) do
    case Nodes.observe_admission_candidate(target, observation, observed_at) do
      :ok ->
        :ok

      :noop ->
        Logger.info("Discovery observation did not persist a candidate for #{target.id}")

        :ok
    end
  end

  # gRPC compatibility discovery stays ephemeral even if a caller injects it.
  defp maybe_persist_discovery_observation(:discovery, _target, _observation, _observed_at),
    do: :ok

  defp maybe_persist_discovery_observation(:trusted, _target, _observation, _observed_at), do: :ok

  defp record_probe_failure(:trusted, target, reason, observed_at) do
    # Pass the raw reason so transport_failure_reason?/1 classifies correctly.
    # Seam rejections are ignored by Nodes.record_transport_failure/3.
    _ = Nodes.record_transport_failure(target, reason, observed_at)
    log_probe_failure(target.id, reason)
  end

  defp record_probe_failure(:discovery, target, reason, _observed_at) do
    # Discovery targets are not yet trusted inventory. Failures stay ephemeral so
    # a missing configured peer does not invent Node demotion rows.
    log_probe_failure(target.id, reason)
  end

  defp disconnect(client, connection) do
    case client.disconnect(connection) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp log_probe_failure(target_id, reason) do
    Logger.debug("Activation status probe failed for #{target_id}: #{probe_failure_code(reason)}")
    []
  end

  defp probe_failure_code(reason) when is_atom(reason), do: reason
  defp probe_failure_code({reason, _detail}) when is_atom(reason), do: reason
  defp probe_failure_code(_reason), do: :activation_probe_failed

  if Mix.env() == :test do
    defp allowed_client?(client) do
      extras =
        :orchard_controller
        |> Application.get_env(:activation_probe, [])
        |> Keyword.get(:allowed_clients, [])

      client in (@transport_clients ++ extras)
    end
  else
    defp allowed_client?(client), do: client in @transport_clients
  end

  defp configured_interval do
    :orchard_controller
    |> Application.get_env(:activation_probe, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp contract_safe_interval(interval) when is_integer(interval) and interval > 0 do
    ceiling =
      min(Inference.node_unreachable_threshold_ms(), Inference.node_freshness_threshold_ms())

    cond do
      interval < ceiling ->
        interval

      ceiling > @min_interval_ms ->
        clamped = clamped_interval(ceiling)

        Logger.warning(
          "activation_probe interval_ms=#{interval} must be < #{ceiling}; clamping to #{clamped}"
        )

        clamped

      true ->
        Logger.error(
          "activation_probe cannot satisfy interval_ms < #{inspect(ceiling)} above the " <>
            "#{@min_interval_ms}ms floor; using #{@default_interval_ms} and degrading liveness detection"
        )

        @default_interval_ms
    end
  end

  defp contract_safe_interval(interval) do
    Logger.warning(
      "activation_probe interval_ms=#{inspect(interval)} is not a positive integer; " <>
        "using #{@default_interval_ms}"
    )

    contract_safe_interval(@default_interval_ms)
  end

  defp clamped_interval(ceiling) do
    ceiling
    |> div(2)
    |> min(@default_interval_ms)
    |> max(@min_interval_ms)
  end

  defp schedule_probe(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :probe, interval)
  end
end
