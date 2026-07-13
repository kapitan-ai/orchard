defmodule Orchard.Node.BeamPeerGrantStartupVerifier do
  @moduledoc """
  Fails Node Agent startup unless the running VM matches stored grant custody.
  """

  use GenServer

  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.Node.{BeamPeerGrantStore, RuntimeTLS}
  alias Orchard.RuntimeEndpoint.{DistributionLaunch, DistributionTLS}

  @grant_fields [
    :grant_id,
    :generation,
    :contract_version,
    :purpose,
    :not_before_at,
    :expires_at,
    :cluster_id,
    :controller_id,
    :node_id,
    :controller_beam_name,
    :node_beam_name,
    :controller_certificate_identifier,
    :controller_certificate_fingerprint_sha256,
    :node_certificate_identifier,
    :node_certificate_fingerprint_sha256,
    :beam_authorization_root_id
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec verify(keyword()) :: :ok | {:error, atom()}
  def verify(opts) when is_list(opts) do
    manifest_path = Keyword.get(opts, :manifest_path)
    identity_root = Keyword.get(opts, :identity_root)
    descriptor_path = Keyword.get(opts, :descriptor_path)
    node_beam_name = Keyword.get(opts, :node_beam_name)
    distribution_launch = Keyword.get(opts, :distribution_launch, DistributionLaunch)
    identity_loader = Keyword.get(opts, :identity_loader, RuntimeTLS)
    descriptor_loader = Keyword.get(opts, :descriptor_loader, BeamPeerGrantDescriptor)
    grant_store = Keyword.get(opts, :grant_store, BeamPeerGrantStore)
    distribution_tls = Keyword.get(opts, :distribution_tls, DistributionTLS)

    with true <- required?(manifest_path, identity_root, descriptor_path, node_beam_name),
         {:ok, manifest} <- distribution_launch.load(manifest_path),
         true <- value(manifest, :role) == :node_agent,
         {:ok, identity} <-
           identity_loader.load_registered_identity(identity_root,
             require_controller_certificate: true
           ),
         {:ok, descriptor} <- descriptor_loader.load(descriptor_path),
         {:ok, grant} <- grant_store.load(identity_root, identity, node_beam_name),
         :ok <- grant_store.ensure_current(grant),
         true <- exact_scope?(manifest, grant, descriptor, identity, node_beam_name),
         :ok <- distribution_launch.verify_vm(manifest, vm_opts(opts)),
         :ok <-
           distribution_tls.verify_options(
             value(manifest, :optfile_path),
             local_identity(identity),
             peer_identity(identity)
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_distribution_launch_contract_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_launch_contract_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_launch_contract_invalid}
  end

  @impl true
  def init(opts) do
    case verify(opts) do
      :ok -> {:ok, opts}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp exact_scope?(manifest, grant, descriptor, identity, node_beam_name) do
    checks = [
      Enum.all?(@grant_fields, &(value(manifest, &1) == value(grant, &1))),
      value(manifest, :local_identity_generation_id) == value(identity, :generation_id),
      value(manifest, :cluster_id) == value(identity, :cluster_id),
      value(manifest, :controller_id) == value(identity, :controller_id),
      value(manifest, :node_id) == value(identity, :node_id),
      value(manifest, :node_beam_name) == node_beam_name,
      value(manifest, :grant_id) == value(descriptor, :grant_id),
      value(manifest, :generation) == value(descriptor, :generation),
      value(manifest, :controller_id) == value(descriptor, :controller_id),
      value(manifest, :controller_certificate_identifier) ==
        value(identity, :controller_certificate_identifier),
      value(manifest, :controller_certificate_fingerprint_sha256) ==
        value(identity, :controller_certificate_fingerprint),
      value(manifest, :node_certificate_identifier) == value(identity, :certificate_identifier),
      value(manifest, :node_certificate_fingerprint_sha256) ==
        value(identity, :certificate_fingerprint)
    ]

    Enum.all?(checks)
  end

  defp vm_opts(opts) do
    [
      current_node: Keyword.get(opts, :current_node, Node.self()),
      static_targets: Keyword.get(opts, :static_targets, []),
      cookie_file: Keyword.get(opts, :cookie_file)
    ]
    |> put_optional(opts, :argument_reader)
    |> put_optional(opts, :tls_versions)
    |> put_optional(opts, :now)
  end

  defp put_optional(target, source, key) do
    if Keyword.has_key?(source, key), do: Keyword.put(target, key, source[key]), else: target
  end

  defp local_identity(identity) do
    %{
      certfile: value(identity, :certfile),
      keyfile: value(identity, :keyfile),
      cacertfile: value(identity, :cacertfile)
    }
  end

  defp peer_identity(identity) do
    %{
      uri_san: value(identity, :controller_uri_san),
      certificate_serial: certificate_serial(value(identity, :controller_certificate_identifier)),
      certificate_fingerprint: value(identity, :controller_certificate_fingerprint)
    }
  end

  defp certificate_serial("serial:" <> serial) when serial != "", do: serial
  defp certificate_serial(_identifier), do: nil

  defp required?(manifest_path, identity_root, descriptor_path, node_beam_name) do
    Enum.all?(
      [manifest_path, identity_root, descriptor_path, node_beam_name],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
