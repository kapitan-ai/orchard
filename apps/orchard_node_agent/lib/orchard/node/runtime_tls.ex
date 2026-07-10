defmodule Orchard.Node.RuntimeTLS do
  @moduledoc """
  Loads the protected registered Node identity and builds the gRPC server
  credential used by the enrolled compatibility listener.
  """

  import Bitwise, only: [band: 2]

  alias Orchard.TransportTLS.{CertificateIdentity, PeerVerifier}

  @directory_mode 0o700
  @file_mode 0o600
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type identity :: %{
          required(:generation_id) => String.t(),
          required(:enrollment_id) => String.t(),
          required(:cluster_id) => String.t(),
          required(:node_id) => String.t(),
          required(:controller_id) => String.t(),
          required(:controller_uri_san) => String.t(),
          required(:node_uri_san) => String.t(),
          required(:certificate_identifier) => String.t(),
          required(:certificate_serial) => String.t(),
          required(:certificate_fingerprint) => String.t(),
          required(:runtime_trust_spki_sha256) => String.t(),
          required(:certfile) => String.t(),
          required(:keyfile) => String.t(),
          required(:cacertfile) => String.t()
        }

  @spec load(keyword()) :: :plaintext_compatibility | {:ok, identity()} | {:error, atom()}
  def load(runtime) when is_list(runtime) do
    case Keyword.get(runtime, :grpc_security, :plaintext_compatibility) do
      :plaintext_compatibility -> :plaintext_compatibility
      :mutual_tls -> load_registered_identity(Keyword.get(runtime, :node_identity_root))
      _other -> {:error, :node_runtime_tls_configuration_invalid}
    end
  end

  @spec server_credential() :: :plaintext_compatibility | {:ok, GRPC.Credential.t()}
  def server_credential do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    case Keyword.get(runtime, :runtime_tls_identity) do
      %{} = identity -> {:ok, credential(identity)}
      nil -> load_server_credential(runtime)
    end
  end

  @spec load_registered_identity(String.t() | nil) :: {:ok, identity()} | {:error, atom()}
  def load_registered_identity(root) when is_binary(root) and root != "" do
    root = Path.expand(root)

    with :ok <- validate_directory(root),
         {:ok, root_stat} <- File.stat(root),
         :ok <- verify_running_owner(root, root_stat.uid),
         {:ok, generation_id} <- read_current(root, root_stat.uid),
         generation_root = Path.join([root, "generations", generation_id]),
         :ok <- validate_directory(generation_root, root_stat.uid),
         {:ok, identity} <- read_identity(generation_root, root_stat.uid),
         true <- identity.generation_id == generation_id do
      {:ok, identity}
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  rescue
    _error -> {:error, :node_runtime_tls_identity_invalid}
  catch
    _kind, _reason -> {:error, :node_runtime_tls_identity_invalid}
  end

  def load_registered_identity(_root), do: {:error, :node_runtime_tls_identity_invalid}

  defp load_server_credential(runtime) do
    case load(runtime) do
      :plaintext_compatibility -> :plaintext_compatibility
      {:ok, identity} -> {:ok, credential(identity)}
      {:error, reason} -> raise "Node Runtime TLS identity unavailable: #{reason}"
    end
  end

  defp credential(identity) do
    GRPC.Credential.new(
      ssl: [
        certfile: identity.certfile,
        keyfile: identity.keyfile,
        cacertfile: identity.cacertfile,
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        verify_fun: PeerVerifier.new(identity.controller_uri_san)
      ]
    )
  end

  defp read_current(root, expected_uid) do
    path = Path.join(root, "current")

    with :ok <- validate_file(path, expected_uid),
         {:ok, contents} <- File.read(path),
         generation_id = String.trim(contents),
         true <- valid_uuid?(generation_id) do
      {:ok, String.downcase(generation_id)}
    end
  end

  defp read_identity(root, expected_uid) do
    metadata_path = Path.join(root, "metadata.json")
    certfile = Path.join(root, "node-certificate.pem")
    keyfile = Path.join(root, "node-private-key.pem")
    cacertfile = Path.join(root, "runtime-ca-certificate.pem")

    with :ok <- validate_files([metadata_path, certfile, keyfile, cacertfile], expected_uid),
         {:ok, metadata_json} <- File.read(metadata_path),
         {:ok, metadata} <- Jason.decode(metadata_json),
         {:ok, certificate_pem} <- File.read(certfile),
         {:ok, private_key_pem} <- File.read(keyfile),
         {:ok, ca_certificate_pem} <- File.read(cacertfile),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         {:ok, ca_spki_fingerprint} <-
           CertificateIdentity.spki_fingerprint_from_pem(ca_certificate_pem),
         {:ok, binding} <- validate_metadata(metadata, certificate),
         true <- ca_spki_fingerprint == binding.runtime_trust_spki_sha256,
         true <- CertificateIdentity.signed_by?(certificate_pem, ca_certificate_pem),
         true <-
           CertificateIdentity.private_key_matches_certificate?(private_key_pem, certificate_pem) do
      {:ok,
       Map.merge(binding, %{
         certificate_serial: certificate.serial,
         certificate_fingerprint: certificate.fingerprint,
         certfile: certfile,
         keyfile: keyfile,
         cacertfile: cacertfile
       })}
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp validate_metadata(metadata, certificate) do
    binding = %{
      generation_id: metadata["generation_id"],
      enrollment_id: metadata["enrollment_id"],
      cluster_id: metadata["cluster_id"],
      node_id: metadata["node_id"],
      controller_id: metadata["controller_id"],
      controller_uri_san: metadata["controller_uri_san"],
      node_uri_san: metadata["node_uri_san"],
      certificate_identifier: metadata["certificate_identifier"],
      runtime_trust_spki_sha256: metadata["runtime_trust_spki_sha256"]
    }

    identifiers = [
      binding.generation_id,
      binding.enrollment_id,
      binding.cluster_id,
      binding.node_id,
      binding.controller_id
    ]

    expected_node_uri =
      "urn:orchard:cluster:#{binding.cluster_id}:node:#{binding.node_id}"

    expected_controller_uri =
      "urn:orchard:cluster:#{binding.cluster_id}:controller:#{binding.controller_id}"

    valid =
      metadata["state"] == "registered" and
        Enum.all?(identifiers, &valid_uuid?/1) and
        binding.node_uri_san == expected_node_uri and
        binding.controller_uri_san == expected_controller_uri and
        certificate.uri_sans == [expected_node_uri] and
        non_empty?(binding.certificate_identifier) and
        non_empty?(binding.runtime_trust_spki_sha256)

    if valid, do: {:ok, binding}, else: {:error, :node_runtime_tls_identity_invalid}
  end

  defp verify_running_owner(root, root_uid) do
    probe = Path.join(root, ".owner-probe-#{probe_token()}")

    result =
      with :ok <- write_probe(probe),
           {:ok, stat} <- File.stat(probe),
           true <- stat.uid == root_uid do
        :ok
      else
        _other -> {:error, :node_runtime_tls_identity_invalid}
      end

    File.rm(probe)
    result
  end

  defp write_probe(path) do
    with :ok <- File.write(path, "owner"),
         :ok <- File.chmod(path, @file_mode) do
      :ok
    else
      _error -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp probe_token do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  defp validate_files(paths, expected_uid) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case validate_file(path, expected_uid) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_directory(path, expected_uid \\ nil) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode,
         true <- is_nil(expected_uid) or stat.uid == expected_uid do
      :ok
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp validate_file(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == expected_uid,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid_pattern, value)
  defp non_empty?(value), do: is_binary(value) and value != ""
end
