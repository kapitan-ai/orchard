defmodule OrchardCLI.ExclusiveOutput do
  @moduledoc false

  import Bitwise, only: [band: 2]

  @directory_mode 0o700
  @file_mode 0o600

  @enforce_keys [:io, :path, :staging_dir, :staging_path]
  defstruct [:io, :path, :staging_dir, :staging_path, :device, :inode]

  @type t :: %__MODULE__{
          io: IO.device(),
          path: String.t(),
          staging_dir: String.t(),
          staging_path: String.t(),
          device: {non_neg_integer(), non_neg_integer()} | nil,
          inode: non_neg_integer() | nil
        }

  @callback reserve(String.t()) :: {:ok, term()} | {:error, term()}
  @callback publish(term(), iodata()) :: {:ok, term()} | {:error, term()}
  @callback release(term()) :: :ok | {:error, term()}

  @spec reserve(String.t()) :: {:ok, t()} | {:error, File.posix()}
  def reserve(path) when is_binary(path) do
    path = Path.expand(path)
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent),
         {:ok, parent_stat} <- validate_parent_directory(parent),
         {:error, :enoent} <- File.lstat(path) do
      reserve_private_inode(parent, parent_stat.uid, path)
    else
      {:ok, _stat} -> {:error, :eexist}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec publish(t(), iodata()) :: {:ok, t()} | {:error, term()}
  def publish(%__MODULE__{} = reservation, contents) do
    case write_and_close(reservation.io, contents) do
      :ok -> publish_written_reservation(reservation)
      {:error, reason} -> publish_failure(reservation, reason)
    end
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = reservation), do: cleanup(reservation)

  defp reserve_private_inode(parent, parent_uid, path) do
    staging_dir = Path.join(parent, ".orchard-exclusive-#{Ecto.UUID.generate()}")
    staging_path = Path.join(staging_dir, "output")

    with :ok <- File.mkdir(staging_dir),
         :ok <- File.chmod(staging_dir, @directory_mode),
         {:ok, io} <- File.open(staging_path, [:write, :exclusive, :binary]) do
      reservation = %__MODULE__{
        io: io,
        path: path,
        staging_dir: staging_dir,
        staging_path: staging_path
      }

      protect_reservation(reservation, parent_uid)
    else
      {:error, reason} ->
        File.rm_rf(staging_dir)
        {:error, reason}
    end
  end

  defp protect_reservation(reservation, parent_uid) do
    with :ok <- File.chmod(reservation.staging_path, @file_mode),
         :ok <- validate_private_regular_file(reservation.staging_path, parent_uid) do
      {:ok, reservation}
    else
      {:error, reason} ->
        cleanup(reservation)
        {:error, reason}
    end
  end

  defp publish_written_reservation(reservation) do
    case link_final_path(reservation) do
      {:ok, linked} -> finalize_linked_publication(linked)
      {:linked_error, linked, reason} -> publish_failure(linked, reason)
      {:error, reason} -> publish_failure(reservation, reason)
    end
  end

  defp finalize_linked_publication(linked) do
    with :ok <- sync_directory(Path.dirname(linked.path)),
         :ok <- remove_staging_link(linked),
         :ok <- sync_directory(Path.dirname(linked.path)) do
      {:ok, linked}
    else
      {:error, reason} -> publish_failure(linked, reason)
    end
  end

  defp link_final_path(reservation) do
    with {:ok, staging_stat} <- File.lstat(reservation.staging_path),
         linked <- put_file_identity(reservation, staging_stat),
         :ok <- File.ln(reservation.staging_path, reservation.path) do
      verify_linked_publication(linked)
    end
  end

  defp verify_linked_publication(linked) do
    with :ok <- run_fault_checkpoint(:after_link),
         :ok <- verify_final_identity(linked) do
      {:ok, linked}
    else
      {:error, reason} -> {:linked_error, linked, reason}
    end
  end

  defp run_fault_checkpoint(checkpoint) do
    case Application.get_env(:orchard_cli, :exclusive_output_fault_injector) do
      injector when is_function(injector, 1) -> injector.(checkpoint)
      _other -> :ok
    end
  end

  defp put_file_identity(reservation, stat) do
    %{
      reservation
      | device: {stat.major_device, stat.minor_device},
        inode: stat.inode
    }
  end

  defp verify_final_identity(reservation) do
    case File.lstat(reservation.path) do
      {:ok, stat} ->
        if reserved_identity?(reservation, stat), do: :ok, else: {:error, :eio}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_parent_directory(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o077) == 0 do
      {:ok, stat}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :eacces}
    end
  end

  defp validate_private_regular_file(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == expected_uid,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :eacces}
    end
  end

  defp write_and_close(io, contents) do
    with :ok <- IO.binwrite(io, contents),
         :ok <- :file.sync(io) do
      File.close(io)
    end
  end

  defp publish_failure(reservation, reason) do
    case cleanup(reservation) do
      :ok ->
        {:error, {:publication_failed, :cleanup_complete, reason}}

      {:error, cleanup_reason} ->
        {:error, {:publication_failed, {:cleanup_unresolved, cleanup_reason}, reason}}
    end
  end

  defp cleanup(reservation) do
    results = [
      close_reservation(reservation.io),
      remove_reserved_output(reservation),
      remove_staging_directory(reservation.staging_dir),
      sync_directory(Path.dirname(reservation.path))
    ]

    Enum.find(results, :ok, &match?({:error, _reason}, &1))
  end

  defp close_reservation(io) do
    case File.close(io) do
      :ok -> :ok
      {:error, :terminated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_reserved_output(%__MODULE__{device: nil}), do: :ok

  defp remove_reserved_output(%__MODULE__{} = reservation) do
    quarantine_dir =
      Path.join(Path.dirname(reservation.path), ".orchard-cleanup-#{Ecto.UUID.generate()}")

    quarantine_path = Path.join(quarantine_dir, "output")

    with :ok <- File.mkdir(quarantine_dir),
         :ok <- File.chmod(quarantine_dir, @directory_mode) do
      move_and_remove_reserved_output(reservation, quarantine_dir, quarantine_path)
    end
  end

  defp move_and_remove_reserved_output(reservation, quarantine_dir, quarantine_path) do
    case File.rename(reservation.path, quarantine_path) do
      :ok ->
        verify_and_remove_quarantined_output(reservation, quarantine_dir, quarantine_path)

      {:error, :enoent} ->
        File.rmdir(quarantine_dir)
        :ok

      {:error, reason} ->
        File.rmdir(quarantine_dir)
        {:error, reason}
    end
  end

  defp verify_and_remove_quarantined_output(reservation, quarantine_dir, quarantine_path) do
    case File.lstat(quarantine_path) do
      {:ok, stat} ->
        if reserved_identity?(reservation, stat) do
          remove_verified_quarantine(quarantine_dir, quarantine_path)
        else
          restore_mismatched_quarantine(reservation.path, quarantine_dir, quarantine_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_verified_quarantine(quarantine_dir, quarantine_path) do
    case File.rm(quarantine_path) do
      :ok -> File.rmdir(quarantine_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore_mismatched_quarantine(final_path, quarantine_dir, quarantine_path) do
    case File.ln(quarantine_path, final_path) do
      :ok ->
        File.rm(quarantine_path)
        File.rmdir(quarantine_dir)
        {:error, :output_identity_changed}

      {:error, reason} ->
        {:error, {:output_identity_changed, reason}}
    end
  end

  defp remove_staging_directory(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _entry} -> {:error, reason}
    end
  end

  defp reserved_identity?(reservation, stat) do
    {stat.major_device, stat.minor_device} == reservation.device and
      stat.inode == reservation.inode
  end

  defp remove_staging_link(reservation) do
    case File.rm(reservation.staging_path) do
      :ok -> File.rmdir(reservation.staging_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, directory} ->
        sync_result = :file.sync(directory)
        close_result = :file.close(directory)

        if sync_result == :ok and close_result == :ok do
          :ok
        else
          {:error, :eio}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
