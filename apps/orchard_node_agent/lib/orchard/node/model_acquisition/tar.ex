defmodule Orchard.Node.ModelAcquisition.Tar do
  @moduledoc """
  Safe tar/tar.gz extraction for model bundles.

  Enforces strict security rules:
  - Only regular files and directories are allowed
  - Rejects symlinks, hardlinks, device files, fifos
  - Rejects absolute paths and path traversal (`..`)
  - Post-extraction scan verifies no symlinks were created
  - Normalizes single-wrapper-directory archives to flat layout

  Extraction scratch work uses a sibling directory outside the target
  `staging_path` to avoid collisions between archive entries and
  internal temp names (e.g. an archive entry named `.extract`).
  """

  require Logger

  @type archive_format :: :tar | :tar_gz

  @doc """
  Extract an archive into `staging_path`, enforcing safety rules.

  Uses a sibling temporary directory (outside `staging_path`) for extraction
  scratch work, then normalizes the layout into `staging_path`. This avoids
  collisions between archive entries and internal temp names.

  An optional 4th argument `extract_root` can supply a caller-managed
  extraction directory; otherwise a unique sibling directory is created
  and cleaned up automatically.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec extract_archive(String.t(), String.t(), archive_format()) :: :ok | {:error, term()}
  def extract_archive(archive_path, staging_path, archive_format) do
    # Derive a sibling temp directory outside staging_path to avoid
    # collisions with archive entries named `.extract` etc.
    unique = System.unique_integer([:positive]) |> Integer.to_string()
    extract_root = Path.join(Path.dirname(staging_path), ".orchard-extract-#{unique}")
    extract_archive(archive_path, staging_path, archive_format, extract_root)
  end

  @spec extract_archive(String.t(), String.t(), archive_format(), String.t()) ::
          :ok | {:error, term()}
  def extract_archive(archive_path, staging_path, archive_format, extract_root) do
    with :ok <- mkdir_p(extract_root),
         {:ok, entries} <- list_archive_entries(archive_path, archive_format),
         :ok <- validate_entries(entries),
         :ok <- do_extract(archive_path, extract_root, archive_format),
         :ok <- post_extraction_scan(extract_root),
         :ok <- normalize_layout(extract_root, staging_path) do
      # Clean up extract root (now empty or removed by normalize)
      File.rm_rf(extract_root)
      :ok
    else
      {:error, _} = err ->
        File.rm_rf(extract_root)
        err
    end
  end

  # -- Archive Listing -------------------------------------------------------

  defp list_archive_entries(archive_path, format) do
    open_opts = table_options(format)

    case :erl_tar.table(String.to_charlist(archive_path), open_opts) do
      {:ok, entries} ->
        {:ok, entries}

      {:error, reason} ->
        {:error, {:archive_extract_failed, "failed to list archive: #{inspect(reason)}"}}
    end
  end

  # -- Entry Validation ------------------------------------------------------

  defp validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with :ok <- validate_entry_type(entry),
           :ok <- validate_entry_path(entry) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_entry_type({name, type, _size, _mtime, _mode, _uid, _gid}) do
    case type do
      :regular ->
        :ok

      :directory ->
        :ok

      :symlink ->
        {:error,
         {:invalid_source_layout,
          "archive contains symlink: #{to_string(name)}"}}

      :link ->
        {:error,
         {:invalid_source_layout,
          "archive contains hardlink: #{to_string(name)}"}}

      other ->
        {:error,
         {:invalid_source_layout,
          "archive contains unsupported entry type #{inspect(other)}: #{to_string(name)}"}}
    end
  end

  defp validate_entry_path({name, _type, _size, _mtime, _mode, _uid, _gid}) do
    path = to_string(name)
    segments = Path.split(path)

    cond do
      Path.type(path) == :absolute ->
        {:error,
         {:invalid_source_layout,
          "archive contains absolute path: #{path}"}}

      Enum.any?(segments, &(&1 in ["..", ".", ""])) ->
        {:error,
         {:invalid_source_layout,
          "archive contains path traversal: #{path}"}}

      true ->
        :ok
    end
  end

  # -- Extraction ------------------------------------------------------------

  defp do_extract(archive_path, extract_root, format) do
    extract_opts = [{:cwd, String.to_charlist(extract_root)} | extract_options(format)]

    case :erl_tar.extract(String.to_charlist(archive_path), extract_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:archive_extract_failed, "extraction failed: #{inspect(reason)}"}}
    end
  end

  # -- Post-Extraction Scan --------------------------------------------------

  defp post_extraction_scan(extract_root) do
    case scan_directory(extract_root) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp scan_directory(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          full_path = Path.join(dir, entry)

          case File.lstat(full_path) do
            {:ok, %File.Stat{type: :regular}} ->
              {:cont, :ok}

            {:ok, %File.Stat{type: :directory}} ->
              case scan_directory(full_path) do
                :ok -> {:cont, :ok}
                {:error, _} = err -> {:halt, err}
              end

            {:ok, %File.Stat{type: type}} ->
              {:halt,
               {:error,
                {:invalid_source_layout,
                 "extracted file has unsafe type #{inspect(type)}: #{full_path}"}}}

            {:error, reason} ->
              {:halt, {:error, {:filesystem_error, "lstat #{full_path}: #{inspect(reason)}"}}}
          end
        end)

      {:error, reason} ->
        {:error, {:filesystem_error, "ls #{dir}: #{inspect(reason)}"}}
    end
  end

  # -- Layout Normalization --------------------------------------------------

  defp normalize_layout(extract_root, staging_path) do
    case File.ls(extract_root) do
      {:ok, []} ->
        {:error, {:invalid_source_layout, "archive extracted no files"}}

      {:ok, [single_entry]} ->
        single_path = Path.join(extract_root, single_entry)

        if File.dir?(single_path) do
          # Single wrapper directory — move its children into staging_path
          move_children(single_path, staging_path)
        else
          # Single file — move it into staging_path
          move_children(extract_root, staging_path)
        end

      {:ok, _entries} ->
        # Multiple entries — move all into staging_path
        move_children(extract_root, staging_path)

      {:error, reason} ->
        {:error, {:filesystem_error, "ls #{extract_root}: #{inspect(reason)}"}}
    end
  end

  defp move_children(source_dir, dest_dir) do
    case File.ls(source_dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn entry, :ok ->
          src = Path.join(source_dir, entry)
          dst = Path.join(dest_dir, entry)

          case File.rename(src, dst) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt,
               {:error,
                {:filesystem_error,
                 "rename #{src} -> #{dst}: #{inspect(reason)}"}}}
          end
        end)

      {:error, reason} ->
        {:error, {:filesystem_error, "ls #{source_dir}: #{inspect(reason)}"}}
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp table_options(:tar_gz), do: [:compressed, :verbose]
  defp table_options(:tar), do: [:verbose]

  defp extract_options(:tar_gz), do: [:compressed]
  defp extract_options(:tar), do: []

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem_error, "mkdir_p #{path}: #{inspect(reason)}"}}
    end
  end
end
