defmodule Orchard.Node.WorkerRecoveryControlListener do
  @moduledoc "Enables certificate-pinned recovery control independently of BEAM runtime transport."

  use GenServer

  alias Orchard.Node.RuntimeTLS
  alias Orchard.TransportTLS.PeerVerifier

  @retry_interval 1_000

  @doc "Explicit control enablement never inherits the plaintext compatibility default."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.fetch_env!(:orchard_node_agent, :runtime)[:worker_recovery_control_enabled] ==
      true
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    {:ok, server_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    send(self(), :start_listener)
    {:ok, %{opts: opts, server_supervisor: server_supervisor}}
  end

  @impl true
  def handle_info(:start_listener, state) do
    case start_server(state) do
      :ok ->
        {:noreply, state}

      :retry ->
        Process.send_after(self(), :start_listener, @retry_interval)
        {:noreply, state}
    end
  end

  @spec server_options(keyword()) ::
          {:ok, keyword()}
          | {:error,
             :worker_recovery_control_configuration_invalid
             | :worker_recovery_control_identity_unavailable}
  def server_options(opts \\ []) when is_list(opts) do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    listen_address = Keyword.get(opts, :listen_address, runtime[:listen_address])

    with {:ok, ip} <- listen_ipv4(Keyword.get(listen_address, :host)),
         {:ok, port} <- port(Keyword.get(listen_address, :port)),
         {:ok, credential} <- credential(runtime) do
      {:ok,
       [
         endpoint: Orchard.Node.WorkerRecoveryControlEndpoint,
         port: port,
         start_server: true,
         adapter_opts: [ip: ip, cred: credential]
       ]}
    end
  end

  defp start_server(state) do
    with {:ok, server_options} <- server_options(state.opts),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             state.server_supervisor,
             {GRPC.Server.Supervisor, server_options}
           ) do
      :ok
    else
      {:error, {:already_started, _pid}} -> :ok
      _unavailable -> :retry
    end
  end

  defp listen_ipv4({127, _b, _c, _d} = ip), do: {:ok, ip}
  defp listen_ipv4({10, _b, _c, _d} = ip), do: {:ok, ip}
  defp listen_ipv4({172, b, _c, _d} = ip) when b in 16..31, do: {:ok, ip}
  defp listen_ipv4({192, 168, _c, _d} = ip), do: {:ok, ip}
  defp listen_ipv4(nil), do: {:ok, {127, 0, 0, 1}}

  defp listen_ipv4(host) when is_binary(host) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d} = ip} -> {:ok, ip}
      {:ok, {10, _b, _c, _d} = ip} -> {:ok, ip}
      {:ok, {172, b, _c, _d} = ip} when b in 16..31 -> {:ok, ip}
      {:ok, {192, 168, _c, _d} = ip} -> {:ok, ip}
      _other -> {:error, :worker_recovery_control_configuration_invalid}
    end
  end

  defp listen_ipv4(_host), do: {:error, :worker_recovery_control_configuration_invalid}

  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(_port), do: {:error, :worker_recovery_control_configuration_invalid}

  defp credential(runtime) do
    case RuntimeTLS.load_registered_identity(runtime[:node_identity_root],
           require_controller_certificate: true
         ) do
      {:ok, identity} ->
        {:ok,
         GRPC.Credential.new(
           ssl: [
             certfile: identity.certfile,
             keyfile: identity.keyfile,
             cacertfile: identity.cacertfile,
             verify: :verify_peer,
             fail_if_no_peer_cert: true,
             verify_fun:
               PeerVerifier.new(identity.controller_uri_san,
                 fingerprint: identity.controller_certificate_fingerprint
               )
           ]
         )}

      _unavailable ->
        {:error, :worker_recovery_control_identity_unavailable}
    end
  end
end
