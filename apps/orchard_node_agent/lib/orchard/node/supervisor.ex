defmodule Orchard.Node.Supervisor do
  @moduledoc """
  Node-agent supervision anchor for the runtime gRPC boundary.

  Uses `:rest_for_one` strategy with `ModelManager` before `WorkerSupervisor`:
  if the manager crashes, all workers are torn down and restarted, preventing
  orphaned workers that the new manager would not know about.
  """

  use Supervisor

  alias Orchard.Node.{Endpoint, ModelManager, RuntimeProcessReaper, RuntimeTLS, WorkerSupervisor}

  @grpc_server_id Orchard.Node.GRPCServer

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      ModelManager,
      {Task.Supervisor, name: Orchard.Node.ModelLoadTaskSupervisor},
      RuntimeProcessReaper,
      WorkerSupervisor,
      {Task.Supervisor, name: Orchard.Node.RuntimeEndpointTaskSupervisor},
      Supervisor.child_spec({GRPC.Server.Supervisor, grpc_server_opts()}, id: @grpc_server_id)
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def grpc_server_id, do: @grpc_server_id

  def grpc_server_opts do
    listen_address = Orchard.Node.listen_address()

    [
      endpoint: Endpoint,
      port: listen_address[:port] || raise("missing orchard_node_agent listen port"),
      start_server: true,
      adapter_opts: grpc_adapter_opts(listen_address)
    ]
  end

  defp grpc_adapter_opts(listen_address) do
    opts = [ip: listen_ip(listen_address[:host])]

    case RuntimeTLS.server_credential() do
      :plaintext_compatibility -> opts
      {:ok, credential} -> Keyword.put(opts, :cred, credential)
    end
  end

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
