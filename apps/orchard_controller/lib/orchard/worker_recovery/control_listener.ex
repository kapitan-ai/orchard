defmodule Orchard.WorkerRecovery.ControlListener do
  @moduledoc """
  Starts the recovery-only mTLS Controller checkpoint listener for SPEC §12.2.

  The listener serves `Orchard.WorkerRecovery.ControlServer` alone, so enabling
  recovery control never exposes grant control. Its bind host accepts a loopback
  or private IPv4 address: a single-host source-dev Controller is legitimate,
  while a publicly routable bind is refused.
  """

  use Orchard.WorkerRecovery.LazyListener

  alias Orchard.NodeTrust
  alias Orchard.WorkerRecovery.ControlEndpoint

  @invalid {:error, :worker_recovery_control_configuration_invalid}

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
  rescue
    _exception -> {:error, :worker_recovery_control_identity_unavailable}
  catch
    _kind, _reason -> {:error, :worker_recovery_control_identity_unavailable}
  end
end
