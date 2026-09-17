defmodule Orchard.Node.Supervisor do
  @moduledoc """
  Node-agent supervision anchor for the runtime gRPC boundary.

  Uses `:rest_for_one` strategy with `ModelManager` before `WorkerSupervisor`:
  if the manager crashes, all workers are torn down and restarted, preventing
  orphaned workers that the new manager would not know about.
  """

  use Supervisor

  alias Orchard.Node.{Endpoint, ModelManager, RuntimeProcessReaper, RuntimeTLS, WorkerSupervisor}

  alias Orchard.Node.WorkerRecoveryControlListener

  @grpc_server_id Orchard.Node.GRPCServer

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        ModelManager,
        {Task.Supervisor, name: Orchard.Node.ModelLoadTaskSupervisor},
        RuntimeProcessReaper,
        WorkerSupervisor,
        {Task.Supervisor, name: Orchard.Node.RuntimeEndpointTaskSupervisor}
      ]
      |> maybe_add_runtime_grpc_listener()
      |> maybe_add_worker_recovery_control_listener()
      |> Kernel.++([Orchard.Node.WorkerRecoveryShutdown])

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def grpc_server_id, do: @grpc_server_id

  def grpc_server_opts do
    if Orchard.Node.runtime_grpc_listener_enabled?() do
      runtime_grpc_server_opts()
    else
      recovery_grpc_server_opts()
    end
  end

  defp runtime_grpc_server_opts do
    listen_address = Orchard.Node.listen_address()

    [
      endpoint: Endpoint,
      port: listen_address[:port] || raise("missing orchard_node_agent listen port"),
      start_server: true,
      adapter_opts: grpc_adapter_opts(listen_address)
    ]
  end

  defp recovery_grpc_server_opts do
    case WorkerRecoveryControlListener.server_options() do
      {:ok, opts} ->
        opts

      {:error, :worker_recovery_control_identity_unavailable} ->
        raise "worker recovery control requires registered mTLS identity"

      {:error, :worker_recovery_control_configuration_invalid} ->
        raise "worker recovery control configuration is invalid"
    end
  end

  defp maybe_add_runtime_grpc_listener(children) do
    if Orchard.Node.runtime_grpc_listener_enabled?() do
      children ++
        [Supervisor.child_spec({GRPC.Server.Supervisor, grpc_server_opts()}, id: @grpc_server_id)]
    else
      children
    end
  end

  defp maybe_add_worker_recovery_control_listener(children) do
    if WorkerRecoveryControlListener.enabled?() and
         not Orchard.Node.runtime_grpc_listener_enabled?() do
      children ++ [{WorkerRecoveryControlListener, []}]
    else
      children
    end
  end

  defp grpc_adapter_opts(listen_address) do
    opts = [ip: listen_ip(listen_address[:host])]

    case grpc_credential() do
      :plaintext_compatibility -> opts
      {:ok, credential} -> Keyword.put(opts, :cred, credential)
    end
  end

  defp grpc_credential, do: RuntimeTLS.server_credential()

  defp listen_ip({_, _, _, _} = ip), do: ip
  defp listen_ip({_, _, _, _, _, _, _, _} = ip), do: ip
  defp listen_ip(nil), do: {127, 0, 0, 1}

  defp listen_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        ip

      {:error, :einval} when host == "localhost" ->
        {127, 0, 0, 1}

      {:error, reason} ->
        raise ArgumentError,
              "invalid orchard_node_agent listen host #{inspect(host)}: #{inspect(reason)}"
    end
  end
end
