defmodule Orchard.RuntimeEndpoint.DistributionTLS do
  @moduledoc """
  Writes exact-peer OTP TLS Distribution options into owner-only state.
  """

  import Bitwise, only: [band: 2]

  alias Orchard.TransportTLS.PeerVerifier

  @directory_mode 0o700
  @file_mode 0o600

  @spec write_options(String.t(), map(), map(), keyword()) :: :ok | {:error, atom()}
  def write_options(path, local_identity, peer_identity, opts \\ [])
      when is_binary(path) and is_map(local_identity) and is_map(peer_identity) and
             is_list(opts) do
    path = Path.expand(path)
    parent = Path.dirname(path)
    sync_directory = Keyword.get(opts, :sync_directory, &sync_directory/1)

    with {:ok, owner} <- validate_directory(parent),
         {:ok, local} <- validate_local_identity(local_identity, owner),
         {:ok, peer} <- validate_peer_identity(peer_identity),
         true <- is_function(sync_directory, 1),
         :ok <- publish(path, options(local, peer), owner, sync_directory) do
      :ok
    else
      _other -> {:error, :beam_distribution_tls_configuration_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_tls_configuration_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_tls_configuration_invalid}
  end

  @spec verify_options(String.t(), map(), map()) :: :ok | {:error, atom()}
  def verify_options(path, local_identity, peer_identity)
      when is_binary(path) and is_map(local_identity) and is_map(peer_identity) do
    path = Path.expand(path)

    with {:ok, owner} <- validate_directory(Path.dirname(path)),
         true <- protected_file?(path, owner),
         {:ok, local} <- validate_local_identity(local_identity, owner),
         {:ok, peer} <- validate_peer_identity(peer_identity),
         {:ok, [actual]} <- :file.consult(String.to_charlist(path)),
         true <- actual == options(local, peer) do
      :ok
    else
      _other -> {:error, :beam_distribution_tls_configuration_invalid}
    end
  rescue
    _error -> {:error, :beam_distribution_tls_configuration_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_tls_configuration_invalid}
  end

  defp validate_directory(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode do
      {:ok, stat.uid}
    end
  end

  defp validate_local_identity(identity, owner) do
    local = %{
      certfile: value(identity, :certfile),
      keyfile: value(identity, :keyfile),
      cacertfile: value(identity, :cacertfile)
    }

    if Enum.all?(Map.values(local), &protected_file?(&1, owner)) do
      {:ok, local}
    else
      {:error, :invalid_local_identity}
    end
  end

  defp protected_file?(path, owner) when is_binary(path) and path != "" do
    case File.lstat(path) do
      {:ok, stat} ->
        stat.type == :regular and stat.uid == owner and band(stat.mode, 0o777) == @file_mode

      {:error, _reason} ->
        false
    end
  end

  defp protected_file?(_path, _owner), do: false

  defp validate_peer_identity(identity) do
    peer = %{
      expected_uri: value(identity, :uri_san),
      expected_serial: value(identity, :certificate_serial),
      expected_fingerprint: value(identity, :certificate_fingerprint)
    }

    if Enum.all?(Map.values(peer), &(is_binary(&1) and &1 != "")) do
      {:ok, peer}
    else
      {:error, :invalid_peer_identity}
    end
  end

  defp options(local, peer) do
    common = [
      certfile: String.to_charlist(local.certfile),
      keyfile: String.to_charlist(local.keyfile),
      cacertfile: String.to_charlist(local.cacertfile),
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      verify_fun: {&PeerVerifier.verify_fun/3, peer}
    ]

    [
      server: Keyword.put(common, :fail_if_no_peer_cert, true),
      client: Keyword.put(common, :server_name_indication, :disable)
    ]
  end

  defp publish(path, options, owner, sync_directory) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    contents = :io_lib.format(~c"~tp.~n", [options])

    result =
      case File.open(temporary, [:write, :exclusive, :binary]) do
        {:ok, file} ->
          publish_open_file(temporary, path, file, contents, owner, sync_directory)

        {:error, _reason} ->
          {:error, :publish_failed}
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp publish_open_file(temporary, path, file, contents, owner, sync_directory) do
    write_result =
      with :ok <- File.chmod(temporary, @file_mode),
           {:ok, stat} <- File.lstat(temporary),
           true <- stat.uid == owner,
           :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      else
        _other -> {:error, :publish_failed}
      end

    close_result = File.close(file)

    if write_result == :ok and close_result == :ok do
      rename_published(temporary, path, sync_directory)
    else
      {:error, :publish_failed}
    end
  end

  defp rename_published(temporary, path, sync_directory) do
    with :ok <- File.rename(temporary, path),
         :ok <- sync_directory.(Path.dirname(path)) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, file} -> sync_open_directory(file)
      {:error, _reason} -> {:error, :sync_failed}
    end
  end

  defp sync_open_directory(file) do
    sync_result = :file.sync(file)
    close_result = :file.close(file)

    if sync_result == :ok and close_result == :ok do
      :ok
    else
      {:error, :sync_failed}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
