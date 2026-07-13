defmodule Orchard.BeamAuthorizationRoot.Store do
  @moduledoc """
  Protects one Controller-local BEAM Authorization Root.

  The root never enters Postgres and is loaded only from owner-only local
  storage before an exact pair secret is derived.
  """

  import Bitwise, only: [band: 2]

  @directory_mode 0o700
  @file_mode 0o600
  @key_file "authorization-root.bin"
  @metadata_file "metadata.json"
  @minimum_key_bytes 32

  @type material :: %{required(:root_id) => Ecto.UUID.t(), required(:key) => binary()}

  @spec ensure(String.t(), keyword()) :: {:ok, material()} | {:error, atom()}
  def ensure(root, opts \\ []) when is_binary(root) and root != "" and is_list(opts) do
    root = Path.expand(root)

    case load(root, opts) do
      {:ok, material} -> {:ok, material}
      {:error, :beam_authorization_root_not_found} -> create(root, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec load(String.t(), keyword()) :: {:ok, material()} | {:error, atom()}
  def load(root, opts \\ []) when is_binary(root) and root != "" and is_list(opts) do
    root = Path.expand(root)

    with {:ok, owner} <- ownership_context(root, opts),
         :ok <- validate_directory(root, owner),
         :ok <- validate_file(Path.join(root, @key_file), owner),
         :ok <- validate_file(Path.join(root, @metadata_file), owner),
         {:ok, key} <- File.read(Path.join(root, @key_file)),
         true <- byte_size(key) >= @minimum_key_bytes,
         {:ok, metadata_json} <- File.read(Path.join(root, @metadata_file)),
         {:ok, %{"root_id" => root_id}} <- Jason.decode(metadata_json),
         {:ok, root_id} <- Ecto.UUID.cast(root_id) do
      {:ok, %{root_id: root_id, key: key}}
    else
      {:error, :enoent} -> {:error, :beam_authorization_root_not_found}
      _other -> {:error, :beam_authorization_root_storage_invalid}
    end
  rescue
    _error -> {:error, :beam_authorization_root_storage_invalid}
  catch
    _kind, _reason -> {:error, :beam_authorization_root_storage_invalid}
  end

  defp create(root, opts) do
    material = %{root_id: Ecto.UUID.generate(), key: :crypto.strong_rand_bytes(32)}
    staging = root <> ".staging-#{Ecto.UUID.generate()}"

    case ownership_context(root, opts) do
      {:ok, owner} -> do_create(root, staging, material, owner, opts)
      _other -> {:error, :beam_authorization_root_storage_failed}
    end
  end

  defp do_create(root, staging, material, owner, opts) do
    with {:ok, ^owner} <- ownership_context(root, opts),
         :ok <- create_private_directory(staging, owner),
         :ok <- write_private_file(Path.join(staging, @key_file), material.key, owner),
         :ok <-
           write_private_file(
             Path.join(staging, @metadata_file),
             Jason.encode!(%{root_id: material.root_id}),
             owner
           ),
         :ok <- sync_directory(staging),
         {:ok, ^owner} <- ownership_context(root, opts),
         :ok <- File.rename(staging, root),
         :ok <- sync_directory(Path.dirname(root)) do
      {:ok, material}
    else
      {:error, reason} when reason in [:eexist, :enotempty] ->
        File.rm_rf(staging)
        load(root, opts)

      _other ->
        File.rm_rf(staging)
        {:error, :beam_authorization_root_storage_failed}
    end
  rescue
    _error ->
      File.rm_rf(staging)
      {:error, :beam_authorization_root_storage_failed}
  catch
    _kind, _reason ->
      File.rm_rf(staging)
      {:error, :beam_authorization_root_storage_failed}
  end

  defp create_private_directory(path, owner) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @directory_mode),
         :ok <- validate_directory(path, owner) do
      :ok
    else
      _other -> {:error, :beam_authorization_root_storage_failed}
    end
  end

  defp write_private_file(path, contents, owner) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} -> write_open_file(path, file, contents, owner)
      {:error, _reason} -> {:error, :beam_authorization_root_storage_failed}
    end
  end

  defp write_open_file(path, file, contents, owner) do
    write_result =
      with :ok <- File.chmod(path, @file_mode),
           {:ok, stat} <- File.lstat(path),
           true <- stat.type == :regular and stat.uid == owner,
           :ok <- IO.binwrite(file, contents),
           :ok <- :file.sync(file) do
        :ok
      else
        _other -> {:error, :beam_authorization_root_storage_failed}
      end

    close_result = File.close(file)

    if write_result == :ok and close_result == :ok do
      :ok
    else
      File.rm(path)
      {:error, :beam_authorization_root_storage_failed}
    end
  end

  defp ownership_context(root, opts) do
    parent = Path.dirname(root)
    uid_probe = Keyword.get(opts, :uid_probe, &probe_uid/1)

    with :ok <- validate_parent_permissions(parent),
         true <- is_function(uid_probe, 1),
         {:ok, owner} when is_integer(owner) and owner >= 0 <- uid_probe.(parent),
         :ok <- validate_parent(parent, owner) do
      {:ok, owner}
    else
      _other -> {:error, :beam_authorization_root_storage_invalid}
    end
  end

  defp validate_parent_permissions(path) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o022) == 0 do
      :ok
    else
      _other -> {:error, :beam_authorization_root_storage_invalid}
    end
  end

  defp validate_parent(path, owner) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- stat.uid == owner,
         true <- band(stat.mode, 0o022) == 0 do
      :ok
    else
      _other -> {:error, :beam_authorization_root_storage_invalid}
    end
  end

  defp probe_uid(parent) do
    probe =
      Path.join(
        parent,
        ".orchard-authorization-root-owner-#{Ecto.UUID.generate()}"
      )

    case File.open(probe, [:write, :exclusive, :binary]) do
      {:ok, file} -> inspect_probe(probe, file)
      {:error, _reason} -> {:error, :beam_authorization_root_storage_invalid}
    end
  end

  defp inspect_probe(probe, file) do
    result =
      with :ok <- File.chmod(probe, @file_mode),
           :ok <- File.close(file),
           {:ok, stat} <- File.lstat(probe),
           true <- stat.type == :regular,
           :ok <- File.rm(probe) do
        {:ok, stat.uid}
      else
        _other -> {:error, :beam_authorization_root_storage_invalid}
      end

    File.close(file)
    File.rm(probe)
    result
  end

  defp validate_directory(path, owner) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- stat.uid == owner,
         true <- band(stat.mode, 0o777) == @directory_mode do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :beam_authorization_root_storage_invalid}
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
      _other -> {:error, :beam_authorization_root_storage_invalid}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, file} -> sync_open_directory(file)
      {:error, _reason} -> {:error, :beam_authorization_root_storage_failed}
    end
  end

  defp sync_open_directory(file) do
    sync_result = :file.sync(file)
    close_result = :file.close(file)

    if sync_result == :ok and close_result == :ok do
      :ok
    else
      {:error, :beam_authorization_root_storage_failed}
    end
  end
end
