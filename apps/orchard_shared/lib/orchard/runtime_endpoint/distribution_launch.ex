defmodule Orchard.RuntimeEndpoint.DistributionLaunch do
  @moduledoc """
  Owner-only launch contract for an exact BEAM Peer Grant Distribution pair.
  """

  import Bitwise, only: [band: 2]

  alias Orchard.RuntimeEndpoint.BeamNodeName

  @directory_mode 0o700
  @file_mode 0o600
  @schema_version 1
  @roles [:controller, :node_agent]
  @string_fields [
    :grant_id,
    :purpose,
    :cluster_id,
    :controller_id,
    :node_id,
    :controller_beam_name,
    :node_beam_name,
    :controller_certificate_identifier,
    :controller_certificate_fingerprint_sha256,
    :node_certificate_identifier,
    :node_certificate_fingerprint_sha256,
    :beam_authorization_root_id,
    :local_identity_generation_id
  ]

  @type manifest :: %{
          required(:schema_version) => pos_integer(),
          required(:role) => :controller | :node_agent,
          required(:grant_id) => String.t(),
          required(:generation) => pos_integer(),
          required(:contract_version) => pos_integer(),
          required(:purpose) => String.t(),
          required(:cluster_id) => String.t(),
          required(:controller_id) => String.t(),
          required(:node_id) => String.t(),
          required(:controller_beam_name) => String.t(),
          required(:node_beam_name) => String.t(),
          required(:controller_certificate_identifier) => String.t(),
          required(:controller_certificate_fingerprint_sha256) => String.t(),
          required(:node_certificate_identifier) => String.t(),
          required(:node_certificate_fingerprint_sha256) => String.t(),
          required(:beam_authorization_root_id) => String.t(),
          required(:not_before_at) => DateTime.t(),
          required(:expires_at) => DateTime.t(),
          required(:optfile_path) => String.t(),
          required(:optfile_digest_sha256) => String.t(),
          required(:local_identity_generation_id) => String.t()
        }

  @spec write(String.t(), map()) :: :ok | {:error, atom()}
  def write(path, attrs) when is_binary(path) and is_map(attrs) do
    path = Path.expand(path)

    with {:ok, owner} <- validate_directory(Path.dirname(path)),
         {:ok, manifest} <- build_manifest(attrs, owner),
         :ok <- publish(path, Jason.encode!(encode_manifest(manifest)), owner) do
      :ok
    else
      _other -> {:error, :beam_distribution_launch_contract_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_launch_contract_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_launch_contract_invalid}
  end

  @spec load(String.t()) :: {:ok, manifest()} | {:error, atom()}
  def load(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, owner} <- validate_directory(Path.dirname(path)),
         :ok <- validate_file(path, owner),
         {:ok, contents} <- File.read(path),
         {:ok, encoded} <- Jason.decode(contents),
         {:ok, manifest} <- decode_manifest(encoded, owner) do
      {:ok, manifest}
    else
      _other -> {:error, :beam_distribution_launch_contract_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_launch_contract_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_launch_contract_invalid}
  end

  @spec verify_vm(manifest(), keyword()) :: :ok | {:error, atom()}
  def verify_vm(manifest, opts) when is_map(manifest) and is_list(opts) do
    with :ok <- verify_current_window(manifest, Keyword.get(opts, :now, DateTime.utc_now())),
         :ok <- verify_current_node(manifest, Keyword.get(opts, :current_node, node())),
         :ok <- verify_vm_arguments(manifest, argument_reader(opts)),
         :ok <- verify_no_legacy_authorization(opts),
         :ok <- verify_tls_version(Keyword.get(opts, :tls_versions, supported_tls_versions())) do
      verify_optfile_digest(manifest)
    end
  rescue
    _error -> {:error, :beam_distribution_startup_mismatch}
  catch
    _kind, _reason -> {:error, :beam_distribution_startup_mismatch}
  end

  defp build_manifest(attrs, owner) do
    role = value(attrs, :role)
    optfile_path = value(attrs, :optfile_path) |> expand_path()

    with true <- role in @roles,
         true <- valid_positive_integer?(value(attrs, :generation)),
         true <- valid_positive_integer?(value(attrs, :contract_version)),
         true <- Enum.all?(@string_fields, &nonempty?(value(attrs, &1))),
         :ok <- validate_peer_names(attrs),
         true <- is_struct(value(attrs, :not_before_at), DateTime),
         true <- is_struct(value(attrs, :expires_at), DateTime),
         :ok <- validate_file(optfile_path, owner),
         {:ok, digest} <- digest_file(optfile_path) do
      {:ok,
       attrs
       |> Map.new(fn {key, val} -> {normalize_key(key), val} end)
       |> Map.take(
         @string_fields ++ [:generation, :contract_version, :not_before_at, :expires_at]
       )
       |> Map.merge(%{
         schema_version: @schema_version,
         role: role,
         optfile_path: optfile_path,
         optfile_digest_sha256: digest
       })}
    else
      _other -> {:error, :invalid_manifest}
    end
  end

  defp encode_manifest(manifest) do
    manifest
    |> Map.update!(:role, &Atom.to_string/1)
    |> Map.update!(:not_before_at, &DateTime.to_iso8601/1)
    |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
  end

  defp decode_manifest(encoded, owner) when is_map(encoded) do
    with {:ok, role} <- decode_role(value(encoded, :role)),
         true <- value(encoded, :schema_version) == @schema_version,
         true <- valid_positive_integer?(value(encoded, :generation)),
         true <- valid_positive_integer?(value(encoded, :contract_version)),
         true <- Enum.all?(@string_fields, &nonempty?(value(encoded, &1))),
         :ok <- validate_peer_names(encoded),
         {:ok, not_before_at, 0} <- DateTime.from_iso8601(value(encoded, :not_before_at)),
         {:ok, expires_at, 0} <- DateTime.from_iso8601(value(encoded, :expires_at)),
         optfile_path when is_binary(optfile_path) <- value(encoded, :optfile_path),
         true <- Path.type(optfile_path) == :absolute,
         :ok <- validate_file(optfile_path, owner),
         {:ok, digest} <- digest_file(optfile_path),
         true <- digest == value(encoded, :optfile_digest_sha256) do
      {:ok,
       @string_fields
       |> Enum.reduce(%{}, fn field, manifest ->
         Map.put(manifest, field, value(encoded, field))
       end)
       |> Map.merge(%{
         schema_version: @schema_version,
         role: role,
         generation: value(encoded, :generation),
         contract_version: value(encoded, :contract_version),
         not_before_at: not_before_at,
         expires_at: expires_at,
         optfile_path: optfile_path,
         optfile_digest_sha256: digest
       })}
    else
      _other -> {:error, :invalid_manifest}
    end
  end

  defp decode_manifest(_encoded, _owner), do: {:error, :invalid_manifest}

  defp decode_role("controller"), do: {:ok, :controller}
  defp decode_role("node_agent"), do: {:ok, :node_agent}
  defp decode_role(_role), do: {:error, :invalid_role}

  defp validate_peer_names(manifest) do
    with :ok <-
           BeamNodeName.validate(
             value(manifest, :controller_beam_name),
             "orchard_controller_",
             value(manifest, :controller_id)
           ) do
      BeamNodeName.validate(
        value(manifest, :node_beam_name),
        "orchard_node_agent_",
        value(manifest, :node_id)
      )
    end
  end

  defp verify_current_window(manifest, %DateTime{} = now) do
    if DateTime.compare(now, manifest.not_before_at) != :lt and
         DateTime.compare(now, manifest.expires_at) == :lt do
      :ok
    else
      {:error, :beam_distribution_startup_mismatch}
    end
  end

  defp verify_current_window(_manifest, _now),
    do: {:error, :beam_distribution_startup_mismatch}

  defp verify_current_node(manifest, current_node) do
    expected =
      case manifest.role do
        :controller -> manifest.controller_beam_name
        :node_agent -> manifest.node_beam_name
      end

    actual = if is_atom(current_node), do: Atom.to_string(current_node), else: current_node
    if actual == expected, do: :ok, else: {:error, :beam_distribution_startup_mismatch}
  end

  defp verify_vm_arguments(manifest, reader) do
    with {:ok, proto_dist} <- read_single_argument(reader, :proto_dist),
         true <- proto_dist == "inet_tls",
         {:ok, optfile} <- read_single_argument(reader, :ssl_dist_optfile),
         true <- Path.expand(optfile) == manifest.optfile_path,
         :ok <- verify_argument_absent(reader, :setcookie) do
      :ok
    else
      _other -> {:error, :beam_distribution_startup_mismatch}
    end
  end

  defp read_single_argument(reader, name) do
    case reader.(name) do
      {:ok, [[value]]} -> {:ok, to_string(value)}
      {:ok, [value]} -> {:ok, to_string(value)}
      _other -> {:error, :missing_argument}
    end
  end

  defp verify_argument_absent(reader, name) do
    case reader.(name) do
      :error -> :ok
      _argument -> {:error, :argument_present}
    end
  end

  defp verify_no_legacy_authorization(opts) do
    if Keyword.get(opts, :static_targets, []) == [] and
         Keyword.get(opts, :cookie_file) in [nil, ""] do
      :ok
    else
      {:error, :beam_distribution_startup_mismatch}
    end
  end

  defp verify_tls_version(versions) when is_list(versions) do
    if :"tlsv1.3" in versions do
      :ok
    else
      {:error, :beam_distribution_tls_configuration_invalid}
    end
  end

  defp verify_tls_version(_versions),
    do: {:error, :beam_distribution_tls_configuration_invalid}

  defp verify_optfile_digest(manifest) do
    with {:ok, digest} <- digest_file(manifest.optfile_path),
         true <- digest == manifest.optfile_digest_sha256 do
      :ok
    else
      _other -> {:error, :beam_distribution_tls_configuration_invalid}
    end
  end

  defp argument_reader(opts),
    do: Keyword.get(opts, :argument_reader, &:init.get_argument/1)

  defp supported_tls_versions do
    versions = :ssl.versions()
    Keyword.get(versions, :available, Keyword.get(versions, :supported, []))
  end

  defp digest_file(path) do
    with {:ok, contents} <- File.read(path) do
      {:ok, :sha256 |> :crypto.hash(contents) |> Base.url_encode64(padding: false)}
    end
  end

  defp validate_directory(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode do
      {:ok, stat.uid}
    end
  end

  defp validate_file(path, owner) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == owner,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    end
  end

  defp publish(path, contents, owner) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with {:ok, file} <- File.open(temporary, [:write, :exclusive, :binary]),
           :ok <- publish_open_file(file, temporary, contents, owner),
           :ok <- File.rename(temporary, path) do
        sync_directory(Path.dirname(path))
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp publish_open_file(file, temporary, contents, owner) do
    result =
      with :ok <- File.chmod(temporary, @file_mode),
           :ok <- validate_file(temporary, owner),
           :ok <- IO.binwrite(file, contents) do
        :file.sync(file)
      end

    close_result = File.close(file)
    if result == :ok and close_result == :ok, do: :ok, else: {:error, :publish_failed}
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        result = :file.sync(directory)
        close_result = :file.close(directory)
        if result == :ok and close_result == :ok, do: :ok, else: {:error, :publish_failed}

      {:error, _reason} ->
        {:error, :publish_failed}
    end
  end

  defp expand_path(path) when is_binary(path) and path != "", do: Path.expand(path)
  defp expand_path(_path), do: nil

  defp valid_positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
