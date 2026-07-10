defmodule Orchard.RuntimeEndpoint.ActivationProbe do
  @moduledoc """
  Performs leader-side status-only probes for admitted gRPC compatibility Nodes.
  """

  use GenServer

  require Logger

  alias Orchard.ControlPlane
  alias Orchard.Inference
  alias Orchard.RuntimeEndpoint.GrpcCompatibilityClient

  @default_interval_ms 5_000
  @default_timeout_ms 5_000

  @type result :: %{required(:target_id) => String.t(), required(:status) => :activated}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec run_once(keyword()) :: {:ok, [result()]} | {:error, atom()}
  def run_once(opts \\ []) do
    client = Keyword.get(opts, :client, Inference.runtime_endpoint_client())
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         true <- client == GrpcCompatibilityClient do
      results =
        Inference.activation_probe_runtime_endpoint_targets()
        |> Enum.flat_map(&probe_target(&1, client, timeout))

      {:ok, results}
    else
      false -> {:error, :activation_probe_transport_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, configured_interval())
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

  defp probe_target(target, client, timeout) do
    case client.connect(target) do
      {:ok, connection} ->
        try do
          case client.status(connection, timeout: timeout) do
            {:ok, _observation} -> [%{target_id: target.id, status: :activated}]
            {:error, reason} -> log_probe_failure(target.id, reason)
          end
        after
          disconnect(client, connection)
        end

      {:error, reason} ->
        log_probe_failure(target.id, reason)
    end
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

  defp configured_interval do
    :orchard_controller
    |> Application.get_env(:activation_probe, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp schedule_probe(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :probe, interval)
  end
end
