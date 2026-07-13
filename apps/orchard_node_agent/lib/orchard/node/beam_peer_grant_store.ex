defmodule Orchard.Node.BeamPeerGrantStore do
  @moduledoc """
  Persists the Node's exact-pair BEAM grant in owner-only local identity state.

  Values are validated against the registered Node identity before plaintext
  is written. The current tracer permits one immutable generation per
  Controller identity; rotation and replacement remain future lifecycle work.
  """

  import Bitwise, only: [band: 2]

  @directory_mode 0o700
  @file_mode 0o600
  @store_directory "beam-peer-grants"
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @secret_pattern ~r/\A[A-Za-z0-9_-]{43}\z/

  @type stored_grant :: map()

  @spec install(String.t(), map(), map(), String.t(), keyword()) ::
          {:ok, stored_grant()} | {:error, atom()}
  def install(root, identity, delivery, expected_node_name, opts \\ [])
      when is_binary(root) and is_map(identity) and is_map(delivery) and
             is_binary(expected_node_name) and is_list(opts) do
    with {:ok, grant} <- validate_grant(identity, delivery, expected_node_name),
         :ok <- ensure_current(grant),
         {:ok, store_root, expected_uid} <- prepare_store(root, opts),
         path = grant_path(store_root, grant.controller_id),
         {:ok, stored} <- publish_or_load(path, grant, expected_uid),
         :ok <- sync_directory(store_root, opts) do
      {:ok, stored}
    end
  rescue
    _error -> {:error, :beam_peer_grant_store_invalid}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_store_invalid}
  end

  @spec load(String.t(), map(), String.t()) :: {:ok, stored_grant()} | {:error, atom()}
  def load(root, identity, expected_node_name)
      when is_binary(root) and is_map(identity) and is_binary(expected_node_name) do
    controller_id = value(identity, :controller_id)

    with true <- valid_uuid?(controller_id),
         root = Path.expand(root),
         :ok <- validate_directory(root),
         {:ok, root_stat} <- File.stat(root),
         store_root = Path.join(root, @store_directory),
         :ok <- validate_directory(store_root, root_stat.uid),
         path = grant_path(store_root, controller_id),
         :ok <- validate_file(path, root_stat.uid),
         {:ok, json} <- File.read(path),
         {:ok, persisted} <- Jason.decode(json),
         {:ok, grant} <- decode_persisted(persisted),
         true <- grant.controller_id == controller_id,
         {:ok, grant} <- validate_grant(identity, grant, expected_node_name),
         :ok <- ensure_current(grant) do
      {:ok, grant}
    else
      {:error, :enoent} -> {:error, :beam_peer_grant_missing}
      {:error, :beam_peer_credential_mismatch} = error -> error
      {:error, :beam_peer_grant_expired} = error -> error
      {:error, :beam_peer_grant_not_active} = error -> error
      false -> {:error, :beam_peer_credential_mismatch}
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  rescue
    _error -> {:error, :beam_peer_grant_store_invalid}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_store_invalid}
  end

  def load(_root, _identity, _expected_node_name),
    do: {:error, :beam_peer_grant_store_invalid}

  @doc """
  Revalidates a grant at the exact moment plaintext may be installed for a peer.
  """
  @spec ensure_current(map(), DateTime.t()) :: :ok | {:error, atom()}
  def ensure_current(grant, now \\ DateTime.utc_now())

  def ensure_current(grant, now) when is_map(grant) do
    not_before_at = value(grant, :not_before_at)
    expires_at = value(grant, :expires_at)

    cond do
      not is_struct(not_before_at, DateTime) or not is_struct(expires_at, DateTime) ->
        {:error, :beam_peer_credential_mismatch}

      DateTime.compare(now, not_before_at) == :lt ->
        {:error, :beam_peer_grant_not_active}

      DateTime.compare(now, expires_at) != :lt ->
        {:error, :beam_peer_grant_expired}

      true ->
        :ok
    end
  end

  def ensure_current(_grant, _now), do: {:error, :beam_peer_credential_mismatch}

  defp validate_grant(identity, delivery, expected_node_name) do
    grant = normalized_grant(delivery)

    valid =
      [
        valid_grant_identifiers?(grant),
        valid_grant_contract?(grant),
        valid_identity_binding?(grant, identity),
        valid_grant_names?(grant, expected_node_name),
        valid_grant_secret?(grant),
        valid_window?(grant)
      ]
      |> Enum.all?()

    if valid do
      {:ok, grant}
    else
      {:error, :beam_peer_credential_mismatch}
    end
  rescue
    _error -> {:error, :beam_peer_credential_mismatch}
  end

  defp valid_grant_identifiers?(grant) do
    [
      grant.grant_id,
      grant.cluster_id,
      grant.controller_id,
      grant.beam_authorization_root_id,
      grant.node_id
    ]
    |> Enum.all?(&valid_uuid?/1)
  end

  defp valid_grant_contract?(grant) do
    is_integer(grant.generation) and grant.generation > 0 and grant.contract_version == 1 and
      grant.purpose == "runtime_endpoint"
  end

  defp valid_identity_binding?(grant, identity) do
    [
      grant.cluster_id == value(identity, :cluster_id),
      grant.controller_id == value(identity, :controller_id),
      grant.node_id == value(identity, :node_id),
      grant.controller_certificate_identifier ==
        value(identity, :controller_certificate_identifier),
      grant.controller_certificate_fingerprint_sha256 ==
        value(identity, :controller_certificate_fingerprint),
      grant.node_certificate_identifier == value(identity, :certificate_identifier),
      grant.node_certificate_fingerprint_sha256 == value(identity, :certificate_fingerprint)
    ]
    |> Enum.all?()
  end

  defp valid_grant_names?(grant, expected_node_name) do
    grant.node_beam_name == expected_node_name and
      canonical_name?("orchard_controller_", grant.controller_id, grant.controller_beam_name) and
      canonical_name?("orchard_node_agent_", grant.node_id, grant.node_beam_name)
  end

  defp valid_grant_secret?(grant) do
    is_binary(grant.encoded_secret) and Regex.match?(@secret_pattern, grant.encoded_secret) and
      is_binary(grant.secret_hash) and byte_size(grant.secret_hash) == 32 and
      :crypto.hash(:sha256, grant.encoded_secret) == grant.secret_hash
  end

  defp normalized_grant(delivery) do
    %{
      grant_id: value(delivery, :grant_id),
      generation: value(delivery, :generation),
      cluster_id: value(delivery, :cluster_id),
      controller_id: value(delivery, :controller_id),
      controller_beam_name: value(delivery, :controller_beam_name),
      controller_certificate_identifier: value(delivery, :controller_certificate_identifier),
      controller_certificate_fingerprint_sha256:
        value(delivery, :controller_certificate_fingerprint_sha256),
      beam_authorization_root_id: value(delivery, :beam_authorization_root_id),
      node_id: value(delivery, :node_id),
      node_beam_name: value(delivery, :node_beam_name),
      node_certificate_identifier: value(delivery, :node_certificate_identifier),
      node_certificate_fingerprint_sha256: value(delivery, :node_certificate_fingerprint_sha256),
      contract_version: value(delivery, :contract_version),
      purpose: value(delivery, :purpose),
      issued_at: value(delivery, :issued_at),
      not_before_at: value(delivery, :not_before_at),
      cutover_at: value(delivery, :cutover_at),
      expires_at: value(delivery, :expires_at),
      encoded_secret: value(delivery, :encoded_secret),
      secret_hash: value(delivery, :secret_hash)
    }
  end

  defp valid_window?(grant) do
    is_struct(grant.issued_at, DateTime) and
      is_struct(grant.not_before_at, DateTime) and
      (is_nil(grant.cutover_at) or is_struct(grant.cutover_at, DateTime)) and
      is_struct(grant.expires_at, DateTime) and
      DateTime.compare(grant.expires_at, grant.not_before_at) == :gt and
      (is_nil(grant.cutover_at) or
         (DateTime.compare(grant.cutover_at, grant.not_before_at) != :lt and
            DateTime.compare(grant.cutover_at, grant.expires_at) != :gt))
  end

  defp canonical_name?(prefix, id, name) when is_binary(name) do
    expected_service = prefix <> String.replace(id, "-", "")

    case String.split(name, "@", parts: 2) do
      [^expected_service, host] -> private_ipv4?(host)
      _other -> false
    end
  end

  defp canonical_name?(_prefix, _id, _name), do: false

  defp private_ipv4?(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {10, _b, _c, _d}} -> true
      {:ok, {172, b, _c, _d}} when b in 16..31 -> true
      {:ok, {192, 168, _c, _d}} -> true
      _other -> false
    end
  end

  defp prepare_store(root, opts) do
    root = Path.expand(root)

    with :ok <- validate_directory(root),
         {:ok, root_stat} <- File.stat(root),
         store_root = Path.join(root, @store_directory),
         :ok <- create_or_validate_directory(store_root, root, root_stat.uid, opts) do
      {:ok, store_root, root_stat.uid}
    else
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp create_or_validate_directory(path, parent, expected_uid, opts) do
    case File.lstat(path) do
      {:ok, _stat} ->
        validate_directory(path, expected_uid)

      {:error, :enoent} ->
        with :ok <- create_private_directory(path, expected_uid) do
          sync_directory(parent, opts)
        end

      _other ->
        {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp create_private_directory(path, expected_uid) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @directory_mode),
         :ok <- validate_directory(path, expected_uid) do
      :ok
    else
      {:error, :eexist} -> validate_directory(path, expected_uid)
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp publish_or_load(path, grant, expected_uid) do
    case load_existing(path, expected_uid) do
      {:ok, ^grant} -> {:ok, grant}
      {:ok, _other} -> {:error, :beam_peer_grant_store_conflict}
      {:error, :beam_peer_grant_missing} -> publish(path, grant, expected_uid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_existing(path, expected_uid) do
    with :ok <- validate_file(path, expected_uid),
         {:ok, json} <- File.read(path),
         {:ok, persisted} <- Jason.decode(json) do
      decode_persisted(persisted)
    else
      {:error, :enoent} -> {:error, :beam_peer_grant_missing}
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp publish(path, grant, expected_uid) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- write_private_file(temporary, encode_persisted(grant)),
         :ok <- File.ln(temporary, path),
         :ok <- File.rm(temporary) do
      {:ok, grant}
    else
      {:error, :eexist} ->
        File.rm(temporary)
        load_after_publish_race(path, grant, expected_uid)

      _other ->
        File.rm(temporary)
        {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp load_after_publish_race(path, grant, expected_uid) do
    case load_existing(path, expected_uid) do
      {:ok, ^grant} -> {:ok, grant}
      {:ok, _other} -> {:error, :beam_peer_grant_store_conflict}
      {:error, _reason} -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp encode_persisted(grant) do
    grant
    |> Map.update!(:secret_hash, &Base.url_encode64(&1, padding: false))
    |> Map.update!(:issued_at, &DateTime.to_iso8601/1)
    |> Map.update!(:not_before_at, &DateTime.to_iso8601/1)
    |> Map.update!(:cutover_at, &encode_optional_datetime/1)
    |> Map.update!(:expires_at, &DateTime.to_iso8601/1)
    |> Jason.encode!()
  end

  defp decode_persisted(persisted) do
    with {:ok, secret_hash} <- Base.url_decode64(value(persisted, :secret_hash), padding: false),
         {:ok, issued_at} <- decode_datetime(value(persisted, :issued_at)),
         {:ok, not_before_at} <- decode_datetime(value(persisted, :not_before_at)),
         {:ok, cutover_at} <- decode_optional_datetime(value(persisted, :cutover_at)),
         {:ok, expires_at} <- decode_datetime(value(persisted, :expires_at)) do
      persisted
      |> normalized_grant()
      |> Map.merge(%{
        secret_hash: secret_hash,
        issued_at: issued_at,
        not_before_at: not_before_at,
        cutover_at: cutover_at,
        expires_at: expires_at
      })
      |> then(&{:ok, &1})
    else
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp encode_optional_datetime(nil), do: nil
  defp encode_optional_datetime(value), do: DateTime.to_iso8601(value)

  defp decode_optional_datetime(nil), do: {:ok, nil}
  defp decode_optional_datetime(value), do: decode_datetime(value)

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp decode_datetime(_value), do: {:error, :beam_peer_grant_store_invalid}

  defp write_private_file(path, contents) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} -> write_open_file(path, file, contents)
      {:error, _reason} -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp write_open_file(path, file, contents) do
    write_result =
      with :ok <- File.chmod(path, @file_mode),
           :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      else
        _other -> {:error, :beam_peer_grant_store_invalid}
      end

    close_result = File.close(file)

    if write_result == :ok and close_result == :ok do
      :ok
    else
      File.rm(path)
      {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp validate_directory(path, expected_uid \\ nil) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode,
         true <- is_nil(expected_uid) or stat.uid == expected_uid do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp validate_file(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == expected_uid,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp sync_directory(path, opts) do
    case Keyword.get(opts, :sync_directory) do
      sync when is_function(sync, 1) -> sync.(path)
      _other -> do_sync_directory(path)
    end
  end

  defp do_sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, file} -> sync_open_directory(file)
      {:error, _reason} -> {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp sync_open_directory(file) do
    sync_result = :file.sync(file)
    close_result = :file.close(file)

    if sync_result == :ok and close_result == :ok do
      :ok
    else
      {:error, :beam_peer_grant_store_invalid}
    end
  end

  defp grant_path(store_root, controller_id), do: Path.join(store_root, controller_id <> ".json")
  defp valid_uuid?(value), do: is_binary(value) and Regex.match?(@uuid_pattern, value)

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
