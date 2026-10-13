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

  alias Orchard.RuntimeEndpoint.{
    BeamClient,
    GrpcCompatibilityClient,
    ReconnectBackoff,
    Target
  }

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
    case run_cycle(opts) do
      {:ok, results, _failures} -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_cycle(opts) do
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

      trusted_outcomes =
        Enum.map(trusted_targets, &probe_target(&1, client, timeout, observed_at, :trusted))

      discovery_outcomes =
        Enum.map(
          discovery_targets,
          &probe_target(&1, client, timeout, observed_at, :discovery)
        )

      _ = Nodes.sweep_stale_node_heartbeats(observed_at)
      safe_prune_heartbeats(heartbeat_context, observed_at)

      outcomes = trusted_outcomes ++ discovery_outcomes

      results =
        for {:observed, result} <- outcomes, do: result

      failures =
        for {{:failed, reason}, target} <- Enum.zip(trusted_outcomes, trusted_targets),
            target.transport == :beam,
            do: {target.id, reason}

      {:ok, results, failures}
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

    monotonic_ms = Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)
    now_ms = monotonic_ms.()
    schedule_probe(interval)

    {:ok,
     %{
       interval: interval,
       monotonic_ms: monotonic_ms,
       next_regular_at_ms: now_ms + interval,
       probe_opts:
         Keyword.take(opts, [
           :client,
           :discovery_targets,
           :heartbeat_context,
           :observed_at,
           :targets,
           :timeout
         ]),
       random_offset: Keyword.get(opts, :random_offset, fn width -> :rand.uniform(width) - 1 end),
       reconnect: %{}
     }}
  end

  @impl true
  def handle_info(:probe, state) do
    now_ms = state.monotonic_ms.()
    {targets, regular?, configured_ids} = scheduled_targets(state, now_ms)

    state =
      if targets == [] and not regular? do
        state
      else
        probe_scheduled_targets(state, targets, configured_ids, regular?, now_ms)
      end

    schedule_probe(next_delay(state, now_ms))
    {:noreply, state}
  end

  defp safe_run_cycle(opts) do
    run_cycle(opts)
  rescue
    exception ->
      Logger.debug("Activation status probe crashed: #{Exception.message(exception)}")
      {:error, :activation_probe_failed}
  catch
    kind, reason ->
      Logger.debug("Activation status probe aborted: #{inspect({kind, reason})}")
      {:error, :activation_probe_failed}
  end

  defp scheduled_targets(state, now_ms) do
    targets = configured_targets(state.probe_opts)
    regular? = now_ms >= state.next_regular_at_ms

    selected =
      Enum.filter(targets, fn target ->
        case Map.get(state.reconnect, target.id) do
          nil -> regular?
          backoff -> ReconnectBackoff.due?(backoff, now_ms)
        end
      end)

    {selected, regular?, MapSet.new(targets, & &1.id)}
  end

  defp configured_targets(opts) do
    Keyword.get_lazy(opts, :targets, fn ->
      Inference.activation_probe_runtime_endpoint_targets()
    end)
  end

  defp probe_scheduled_targets(state, targets, configured_ids, regular?, now_ms) do
    opts =
      state.probe_opts
      |> Keyword.put(:targets, targets)
      |> Keyword.put(:discovery_targets, [])

    state = if regular?, do: %{state | next_regular_at_ms: now_ms + state.interval}, else: state

    case safe_run_cycle(opts) do
      {:ok, results, failures} ->
        update_reconnect_state(state, configured_ids, results, failures, regular?, now_ms)

      {:error, _reason} ->
        %{state | reconnect: Map.new(state.reconnect, &block_reconnect/1)}
    end
  end

  defp update_reconnect_state(state, configured_ids, results, failures, regular?, now_ms) do
    observed_ids = MapSet.new(results, & &1.target_id)

    reconnect =
      state.reconnect
      |> Map.drop(MapSet.to_list(observed_ids))
      |> maybe_drop_absent_targets(configured_ids, regular?)
      |> add_failures(failures, now_ms, state.random_offset)

    %{state | reconnect: reconnect}
  end

  defp maybe_drop_absent_targets(reconnect, current_ids, true),
    do: Map.take(reconnect, MapSet.to_list(current_ids))

  defp maybe_drop_absent_targets(reconnect, _current_ids, false), do: reconnect

  defp block_reconnect({target_id, backoff}),
    do: {target_id, ReconnectBackoff.authority_lost(backoff)}

  defp add_failures(reconnect, failures, now_ms, random_offset) do
    Enum.reduce(failures, reconnect, fn {target_id, reason}, states ->
      backoff = Map.get(states, target_id, ReconnectBackoff.new(now_ms))
      backoff = next_reconnect_state(backoff, reason, now_ms, random_offset)
      Map.put(states, target_id, backoff)
    end)
  end

  defp next_reconnect_state(backoff, reason, now_ms, random_offset) do
    if authority_failure?(reason) do
      ReconnectBackoff.authority_lost(backoff)
    else
      {_delay, backoff} = ReconnectBackoff.failed(backoff, now_ms, random_offset)
      backoff
    end
  end

  defp authority_failure?(reason)
       when reason in [
              :beam_peer_grant_authorization_unavailable,
              :beam_peer_grant_revoked,
              :beam_peer_grant_expired,
              :beam_peer_grant_missing,
              :beam_peer_credential_mismatch,
              :beam_authorization_root_unavailable
            ],
       do: true

  defp authority_failure?(_reason), do: false

  defp next_delay(state, now_ms) do
    retry_deadline =
      state.reconnect
      |> Map.values()
      |> Enum.reject(& &1.blocked?)
      |> Enum.map(& &1.next_attempt_at_ms)
      |> Enum.min(fn -> state.next_regular_at_ms end)

    max(min(retry_deadline, state.next_regular_at_ms) - now_ms, 1)
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
              {:observed, %{target_id: target.id, status: :observed}}

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
    {:failed, reason}
  end

  defp record_probe_failure(:discovery, target, reason, _observed_at) do
    # Discovery targets are not yet trusted inventory. Failures stay ephemeral so
    # a missing configured peer does not invent Node demotion rows.
    log_probe_failure(target.id, reason)
    {:failed, reason}
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
    :ok
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
