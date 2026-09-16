defmodule Orchard.WorkerRecovery.ControlListener do
  @moduledoc """
  Starts the recovery-only mTLS Controller checkpoint listener for SPEC §12.2.

  The listener serves `Orchard.WorkerRecovery.ControlServer` alone, so enabling
  recovery control never exposes grant control. Its bind host accepts a loopback
  or private IPv4 address: a single-host source-dev Controller is legitimate,
  while a publicly routable bind is refused.
  """

  alias Orchard.NodeTrust
  alias Orchard.WorkerRecovery.ControlEndpoint

  @invalid {:error, :worker_recovery_control_configuration_invalid}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case server_options(opts) do
      {:ok, server_options} -> GRPC.Server.Supervisor.start_link(server_options)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec server_options(keyword()) ::
          {:ok, keyword()}
          | {:error,
             :worker_recovery_control_configuration_invalid
             | :worker_recovery_control_identity_unavailable}
  def server_options(opts) when is_list(opts) do
    with {:ok, ip} <- listen_ipv4(Keyword.get(opts, :host)),
         {:ok, port} <- port(Keyword.get(opts, :port)),
         {:ok, credential} <- credential() do
      {:ok,
       [
         endpoint: ControlEndpoint,
         port: port,
         start_server: true,
         adapter_opts: [ip: ip, cred: credential]
       ]}
    end
  end

  defp listen_ipv4(host) when is_binary(host) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d} = ip} -> {:ok, ip}
      {:ok, {10, _b, _c, _d} = ip} -> {:ok, ip}
      {:ok, {172, b, _c, _d} = ip} when b in 16..31 -> {:ok, ip}
      {:ok, {192, 168, _c, _d} = ip} -> {:ok, ip}
      _other -> @invalid
    end
  end

  defp listen_ipv4(_host), do: @invalid

  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(_port), do: @invalid

  defp credential do
    case NodeTrust.peer_grant_runtime_generation_paths() do
      {:ok, identity} ->
        {:ok,
         GRPC.Credential.new(
           ssl: [
             certfile: identity.certfile,
             keyfile: identity.keyfile,
             cacertfile: identity.cacertfile,
             verify: :verify_peer,
             fail_if_no_peer_cert: true,
             versions: [:"tlsv1.3"]
           ]
         )}

      _unavailable ->
        {:error, :worker_recovery_control_identity_unavailable}
    end
  end
end
