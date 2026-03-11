defmodule Orchard.ArtifactBundle do
  @moduledoc """
  Shared filesystem utilities for model artifact bundles.

  Provides deterministic tree hashing and secure directory copying used by
  both the controller importer and the node-agent acquisition subsystem.
  """

  @hash_chunk_bytes 64 * 1024

  # -- Public API -----------------------------------------------------------

  @doc """
  Compute a deterministic SHA-256 digest over all regular files in `dir_path`.

  The hash is computed by:
  1. Recursively collecting all regular file paths (symlinks rejected)
  2. Sorting by path relative to `dir_path`
  3. For each file in order: hash the relative path bytes, then stream
     file content in #{@hash_chunk_bytes}-byte chunks into the digest

  Returns `{:ok, lowercase_hex_digest}` or `{:error, term()}`.
  """
  @spec tree_sha256(String.t()) :: {:ok, String.t()} | {:error, term()}
  def tree_sha256(dir_path) do
    root_prefix = String.trim_trailing(dir_path, "/") <> "/"

    case collect_file_paths(dir_path) do
      {:ok, paths} ->
        sorted = Enum.sort(paths)
        hash = hash_files(sorted, root_prefix, :crypto.hash_init(:sha256))
        {:ok, Base.encode16(hash, case: :lower)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Securely copy the contents of `source` into `dest`.

  Recursively copies all regular files and directories. Rejects symlinks
  and unsupported file types. `dest` must already exist as a directory.

  Returns `:ok` or `{:error, term()}`.
  """
  @spec copy_directory(String.t(), String.t()) :: :ok | {:error, term()}
  def copy_directory(source, dest) do
    safe_copy_directory(source, dest)
  end

  # -- Directory copy (secure, recursive) -----------------------------------

  defp safe_copy_directory(source, dest) do
    with {:ok, entries} <- list_dir(source) do
      copy_entries(entries, source, dest)
    end
  end

  defp list_dir(dir) do
    case File.ls(dir) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:copy_failed, "failed to list #{dir}: #{inspect(reason)}"}}
    end
  end

  defp copy_entries([], _source, _dest), do: :ok

  defp copy_entries([entry | rest], source, dest) do
    case safe_copy_entry(Path.join(source, entry), Path.join(dest, entry)) do
      :ok -> copy_entries(rest, source, dest)
      {:error, _} = err -> err
    end
  end

  defp safe_copy_entry(src, dst) do
    case File.lstat(src) do
      {:ok, stat} -> copy_by_type(stat.type, src, dst)
      {:error, reason} -> {:error, {:copy_failed, "stat #{src}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(:symlink, src, _dst) do
    {:error, {:symlink_rejected, "symlinks not allowed in bundle: #{src}"}}
  end

  defp copy_by_type(:directory, src, dst) do
    case File.mkdir_p(dst) do
      :ok -> safe_copy_directory(src, dst)
      {:error, reason} -> {:error, {:copy_failed, "mkdir #{dst}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(:regular, src, dst) do
    case File.cp(src, dst) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy_failed, "copy #{src}: #{inspect(reason)}"}}
    end
  end

  defp copy_by_type(type, src, _dst) do
    {:error, {:copy_failed, "unsupported file type #{type} at #{src}"}}
  end

  # -- Tree hash (streaming) ------------------------------------------------

  defp collect_file_paths(dir) do
    case File.ls(dir) do
      {:ok, entries} -> collect_entries_for_hash(entries, dir, [])
      {:error, reason} -> {:error, {:hash_failed, "failed to list #{dir}: #{inspect(reason)}"}}
    end
  end

  defp collect_entries_for_hash([], _dir, acc), do: {:ok, acc}

  defp collect_entries_for_hash([entry | rest], dir, acc) do
    full = Path.join(dir, entry)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:hash_failed, "symlinks not allowed in bundle: #{full}"}}

      {:ok, %File.Stat{type: :directory}} ->
        case collect_file_paths(full) do
          {:ok, paths} -> collect_entries_for_hash(rest, dir, acc ++ paths)
          {:error, _} = err -> err
        end

      {:ok, %File.Stat{type: :regular}} ->
        collect_entries_for_hash(rest, dir, acc ++ [full])

      {:ok, %File.Stat{type: type}} ->
        {:error, {:hash_failed, "unsupported file type #{type} at #{full}"}}

      {:error, reason} ->
        {:error, {:hash_failed, "stat #{full}: #{inspect(reason)}"}}
    end
  end

  defp hash_files([], _root_prefix, state), do: :crypto.hash_final(state)

  defp hash_files([path | rest], root_prefix, state) do
    relative = String.replace_leading(path, root_prefix, "")
    state = :crypto.hash_update(state, relative)
    state = hash_file_content(path, state)
    hash_files(rest, root_prefix, state)
  end

  defp hash_file_content(path, state) do
    path
    |> File.stream!([], @hash_chunk_bytes)
    |> Enum.reduce(state, fn chunk, acc -> :crypto.hash_update(acc, chunk) end)
  end
end
