defmodule Orchard.BeamPeerGrantDescriptor do
  @moduledoc """
  Reads and writes one owner-only nonsecret admitted-grant descriptor.
  """

  import Bitwise, only: [band: 2]

  @directory_mode 0o700
  @file_mode 0o600
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type t :: %{
          required(:grant_id) => String.t(),
          required(:generation) => pos_integer(),
          required(:controller_id) => String.t(),
          required(:control_endpoint) => String.t()
        }

  @spec load(String.t()) :: {:ok, t()} | {:error, atom()}
  def load(path) when is_binary(path) and path != "" do
    path = Path.expand(path)

    with {:ok, owner} <- validate_parent(path),
         :ok <- validate_file(path, owner),
         {:ok, json} <- File.read(path),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, descriptor} <- normalize(decoded) do
      {:ok, descriptor}
    else
      _other -> {:error, :beam_peer_grant_descriptor_invalid}
    end
  rescue
    _error -> {:error, :beam_peer_grant_descriptor_invalid}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_descriptor_invalid}
  end

  def load(_path), do: {:error, :beam_peer_grant_descriptor_invalid}

  @spec write(String.t(), map(), keyword()) :: :ok | {:error, atom()}
  def write(path, descriptor, opts \\ [])

  def write(path, descriptor, opts)
      when is_binary(path) and path != "" and is_map(descriptor) and is_list(opts) do
    path = Path.expand(path)
    sync_directory = Keyword.get(opts, :sync_directory, &sync_directory/1)

    with {:ok, owner} <- validate_parent(path),
         {:ok, normalized} <- normalize(descriptor),
         {:ok, json} <- encode(normalized),
         true <- is_function(sync_directory, 1),
         :ok <- publish_or_match(path, json, owner, sync_directory) do
      :ok
    else
      _other -> {:error, :beam_peer_grant_descriptor_invalid}
    end
  rescue
    _error -> {:error, :beam_peer_grant_descriptor_invalid}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_descriptor_invalid}
  end

  def write(_path, _descriptor, _opts), do: {:error, :beam_peer_grant_descriptor_invalid}

  defp validate_parent(path) do
    case File.lstat(Path.dirname(path)) do
      {:ok, stat}
      when stat.type == :directory and band(stat.mode, 0o777) == @directory_mode ->
        {:ok, stat.uid}

      _other ->
        {:error, :invalid_parent}
    end
  end

  defp validate_file(path, owner) do
    case File.lstat(path) do
      {:ok, stat}
      when stat.type == :regular and stat.uid == owner and
             band(stat.mode, 0o777) == @file_mode ->
        :ok

      {:error, :enoent} ->
        {:error, :enoent}

      _other ->
        {:error, :invalid_file}
    end
  end

  defp normalize(decoded) do
    descriptor = %{
      grant_id: value(decoded, :grant_id),
      generation: value(decoded, :generation),
      controller_id: value(decoded, :controller_id),
      control_endpoint: value(decoded, :control_endpoint)
    }

    valid =
      valid_uuid?(descriptor.grant_id) and
        is_integer(descriptor.generation) and descriptor.generation > 0 and
        valid_uuid?(descriptor.controller_id) and
        valid_control_endpoint?(descriptor.control_endpoint)

    if valid do
      {:ok, descriptor}
    else
      {:error, :invalid_descriptor}
    end
  end

  defp encode(descriptor) do
    descriptor
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Jason.encode()
  end

  defp publish_or_match(path, json, owner, sync_directory) do
    case validate_file(path, owner) do
      :ok -> match_and_sync(path, json, sync_directory)
      {:error, :enoent} -> publish(path, json, owner, sync_directory)
      _other -> {:error, :publish_failed}
    end
  end

  defp match_and_sync(path, json, sync_directory) do
    with :ok <- match_existing(path, json),
         :ok <- sync_directory.(Path.dirname(path)) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp match_existing(path, json) do
    case File.read(path) do
      {:ok, ^json} -> :ok
      _other -> {:error, :descriptor_conflict}
    end
  end

  defp publish(path, json, owner, sync_directory) do
    temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    result =
      with :ok <- write_private_file(temporary, json, owner),
           link_result <- File.ln(temporary, path) do
        finish_publication(link_result, temporary, path, json, sync_directory)
      else
        _other -> {:error, :publish_failed}
      end

    File.rm(temporary)
    result
  end

  defp finish_publication(:ok, temporary, path, _json, sync_directory) do
    with :ok <- File.rm(temporary),
         :ok <- sync_directory.(Path.dirname(path)) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp finish_publication({:error, :eexist}, temporary, path, json, sync_directory) do
    with :ok <- File.rm(temporary),
         :ok <- match_existing(path, json),
         :ok <- sync_directory.(Path.dirname(path)) do
      :ok
    else
      _other -> {:error, :publish_failed}
    end
  end

  defp finish_publication(_link_result, _temporary, _path, _json, _sync_directory),
    do: {:error, :publish_failed}

  defp write_private_file(path, contents, owner) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} -> write_open_file(path, file, contents, owner)
      {:error, _reason} -> {:error, :write_failed}
    end
  end

  defp write_open_file(path, file, contents, owner) do
    write_result =
      with :ok <- File.chmod(path, @file_mode),
           {:ok, stat} <- File.lstat(path),
           true <- stat.uid == owner,
           :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      else
        _other -> {:error, :write_failed}
      end

    close_result = File.close(file)

    if write_result == :ok and close_result == :ok do
      :ok
    else
      File.rm(path)
      {:error, :write_failed}
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

  defp valid_control_endpoint?(endpoint) when is_binary(endpoint) do
    endpoint = String.replace_prefix(endpoint, "ipv4:", "")

    case String.split(endpoint, ":", parts: 2) do
      [host, port] -> private_ipv4?(host) and valid_port?(port)
      _other -> false
    end
  end

  defp valid_control_endpoint?(_endpoint), do: false

  defp private_ipv4?(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {127, 0, 0, 1}} -> test_loopback?()
      {:ok, {10, _b, _c, _d}} -> true
      {:ok, {172, b, _c, _d}} when b in 16..31 -> true
      {:ok, {192, 168, _c, _d}} -> true
      _other -> false
    end
  end

  defp test_loopback?, do: Code.ensure_loaded?(Mix) and Mix.env() == :test

  defp valid_port?(port) do
    case Integer.parse(port) do
      {value, ""} when value in 1..65_535 -> true
      _other -> false
    end
  end

  defp valid_uuid?(value) when is_binary(value), do: Regex.match?(@uuid_pattern, value)
  defp valid_uuid?(_value), do: false

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
