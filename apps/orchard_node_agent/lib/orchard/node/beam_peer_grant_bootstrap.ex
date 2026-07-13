defmodule Orchard.Node.BeamPeerGrantBootstrap do
  @moduledoc """
  Installs one admitted exact-pair grant before the Node runtime becomes reachable.

  Canonical node naming and TLS Distribution emulator options are pre-VM launch
  prerequisites. This child owns only certificate-authenticated grant retrieval,
  restart-safe local custody, and the exact Controller peer cookie mapping.
  """

  use GenServer

  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.Cluster.V1.RetrieveBeamPeerGrantRequest

  alias Orchard.Node.{
    BeamPeerGrantClient,
    BeamPeerGrantStore,
    RuntimeTLS
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Loads or retrieves the configured grant and installs its exact peer cookie.
  """
  @spec bootstrap(keyword()) :: {:ok, map()} | {:error, atom()}
  def bootstrap(opts) when is_list(opts) do
    identity_root = Keyword.get(opts, :identity_root)
    descriptor_path = Keyword.get(opts, :descriptor_path)
    node_beam_name = Keyword.get(opts, :node_beam_name, Atom.to_string(Node.self()))
    identity_loader = Keyword.get(opts, :identity_loader, RuntimeTLS)
    descriptor_loader = Keyword.get(opts, :descriptor_loader, BeamPeerGrantDescriptor)
    grant_store = Keyword.get(opts, :grant_store, BeamPeerGrantStore)
    grant_client = Keyword.get(opts, :grant_client, BeamPeerGrantClient)
    cookie_installer = Keyword.get(opts, :cookie_installer, __MODULE__.CookieInstaller)
    retrieval = Keyword.get(opts, :retrieval, :allow)

    with true <- is_binary(identity_root) and identity_root != "",
         true <- is_binary(descriptor_path) and descriptor_path != "",
         true <- is_binary(node_beam_name) and node_beam_name != "",
         {:ok, identity} <-
           identity_loader.load_registered_identity(identity_root,
             require_controller_certificate: true
           ),
         {:ok, descriptor} <- descriptor_loader.load(descriptor_path),
         :ok <- validate_identity_descriptor(identity, descriptor),
         :ok <- validate_node_name(identity, node_beam_name),
         {:ok, grant} <-
           load_or_retrieve(
             grant_store,
             grant_client,
             identity_root,
             identity,
             node_beam_name,
             descriptor,
             retrieval
           ),
         :ok <- validate_grant_descriptor(grant, descriptor, node_beam_name),
         :ok <- grant_store.ensure_current(grant),
         :ok <- cookie_installer.install(grant, node_beam_name) do
      {:ok, grant}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_bootstrap_invalid}
    end
  rescue
    _error -> {:error, :beam_peer_grant_bootstrap_invalid}
  catch
    :exit, _reason -> {:error, :beam_peer_grant_bootstrap_invalid}
  end

  @impl true
  def init(opts) do
    case bootstrap(opts) do
      {:ok, grant} -> {:ok, grant}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp load_or_retrieve(store, client, root, identity, node_beam_name, descriptor, retrieval) do
    case store.load(root, identity, node_beam_name) do
      {:ok, grant} ->
        {:ok, grant}

      {:error, :beam_peer_grant_missing} when retrieval == :forbid ->
        {:error, :beam_peer_grant_missing}

      {:error, :beam_peer_grant_missing} ->
        request = struct!(RetrieveBeamPeerGrantRequest, Map.take(descriptor, request_fields()))

        client.retrieve_and_install(
          root,
          identity,
          node_beam_name,
          descriptor.control_endpoint,
          request
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_identity_descriptor(identity, descriptor) do
    if value(identity, :controller_id) == descriptor.controller_id do
      :ok
    else
      {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_node_name(identity, node_beam_name) do
    node_id = value(identity, :node_id)

    expected_service =
      if is_binary(node_id), do: "orchard_node_agent_" <> String.replace(node_id, "-", "")

    case String.split(node_beam_name, "@", parts: 2) do
      [^expected_service, host] -> validate_private_ipv4(host)
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_private_ipv4(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {10, _b, _c, _d}} -> :ok
      {:ok, {172, b, _c, _d}} when b in 16..31 -> :ok
      {:ok, {192, 168, _c, _d}} -> :ok
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_grant_descriptor(grant, descriptor, node_beam_name) do
    valid =
      value(grant, :grant_id) == descriptor.grant_id and
        value(grant, :generation) == descriptor.generation and
        value(grant, :controller_id) == descriptor.controller_id and
        value(grant, :node_beam_name) == node_beam_name

    if valid, do: :ok, else: {:error, :beam_peer_credential_mismatch}
  end

  defp request_fields, do: [:grant_id, :generation, :controller_id]
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

defmodule Orchard.Node.BeamPeerGrantBootstrap.CookieInstaller do
  @moduledoc """
  Installs one fully validated Controller peer mapping without changing the local cookie.
  """

  @secret_pattern ~r/\A[A-Za-z0-9_-]{43}\z/

  @spec install(map(), String.t()) :: :ok | {:error, atom()}
  def install(grant, node_beam_name) when is_map(grant) and is_binary(node_beam_name) do
    controller_name = value(grant, :controller_beam_name)
    encoded_secret = value(grant, :encoded_secret)

    with true <- Atom.to_string(Node.self()) == node_beam_name,
         true <- is_binary(controller_name) and controller_name != "",
         true <- is_binary(encoded_secret) and Regex.match?(@secret_pattern, encoded_secret),
         true <-
           Node.set_cookie(
             String.to_atom(controller_name),
             String.to_atom(encoded_secret)
           ) do
      :ok
    else
      _other -> {:error, :beam_peer_grant_cookie_install_failed}
    end
  end

  def install(_grant, _node_beam_name), do: {:error, :beam_peer_grant_cookie_install_failed}

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
