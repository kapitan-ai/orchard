defmodule Orchard.NodeTrust.Store do
  @moduledoc false

  import Bitwise, only: [band: 2]

  alias Orchard.NodeTrust.PKI

  @directory_mode 0o700
  @file_mode 0o600
  @metadata_file "metadata.json"
  @private_files [
    "ca-private-key.pem",
    "controller-private-key.pem"
  ]
  @public_files [
    "ca-certificate.pem",
    "controller-certificate.pem"
  ]

  @spec publish(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def publish(root, material) do
    staging_root = Path.join(root, ".staging-#{material.generation_id}")
    generation_root = Path.join([root, "generations", material.generation_id])

    with :ok <- prepare_root(root),
         {:error, :enoent} <- File.lstat(Path.join(root, "current")),
         :ok <- create_private_directory(staging_root),
         :ok <- write_generation(staging_root, material),
         :ok <- sync_directory(staging_root),
         :ok <- File.rename(staging_root, generation_root),
         :ok <- sync_directory(Path.join(root, "generations")),
         :ok <- publish_current(root, material.generation_id) do
      {:ok, material}
    else
      {:ok, _stat} -> stable_failure(staging_root, :node_trust_already_present)
      {:error, :enoent} -> stable_failure(staging_root, :node_trust_storage_failed)
      {:error, reason} when is_atom(reason) -> stable_failure(staging_root, reason)
      _other -> stable_failure(staging_root, :node_trust_storage_failed)
    end
  rescue
    _error -> cleanup_publish_failure(root, material)
  catch
    _kind, _reason -> cleanup_publish_failure(root, material)
  end

  @spec load_current(String.t()) :: {:ok, map()} | {:error, atom()}
  def load_current(root) do
    with :ok <- validate_private_directory(root),
         {:ok, root_stat} <- File.stat(root),
         :ok <- verify_current_owner(root, root_stat.uid),
         {:ok, generation_id} <- read_current(root, root_stat.uid),
         generation_root = Path.join([root, "generations", generation_id]),
         :ok <- validate_private_directory(generation_root, root_stat.uid),
         {:ok, material} <- read_generation(generation_root, root_stat.uid),
         true <- material.generation_id == generation_id,
         true <- PKI.valid_material?(material) do
      {:ok, material}
    else
      {:error, :enoent} -> {:error, :not_found}
      _other -> {:error, :node_trust_local_material_invalid}
    end
  rescue
    _error -> {:error, :node_trust_local_material_invalid}
  catch
    _kind, _reason -> {:error, :node_trust_local_material_invalid}
  end

  @spec load_current_with_paths(String.t()) :: {:ok, map()} | {:error, atom()}
  def load_current_with_paths(root) do
    with {:ok, material} <- load_current(root),
         generation_root = Path.join([Path.expand(root), "generations", material.generation_id]),
         {:ok, root_stat} <- File.stat(Path.expand(root)),
         paths = %{
           certfile: Path.join(generation_root, "controller-certificate.pem"),
           keyfile: Path.join(generation_root, "controller-private-key.pem"),
           cacertfile: Path.join(generation_root, "ca-certificate.pem")
         },
         :ok <-
           validate_private_files(
             generation_root,
             ["controller-certificate.pem", "controller-private-key.pem", "ca-certificate.pem"],
             root_stat.uid
           ) do
      {:ok, Map.put(paths, :material, material)}
    else
      _other -> {:error, :node_trust_local_material_invalid}
    end
  rescue
    _error -> {:error, :node_trust_local_material_invalid}
  end

  defp prepare_root(root) do
    with :ok <- create_or_validate_private_directory(root),
         {:ok, root_stat} <- File.stat(root),
         :ok <- verify_current_owner(root, root_stat.uid) do
      create_or_validate_private_directory(Path.join(root, "generations"), root_stat.uid)
    end
  end

  defp create_or_validate_private_directory(path, expected_uid \\ nil) do
    case File.lstat(path) do
      {:ok, _stat} -> validate_private_directory(path, expected_uid)
      {:error, :enoent} -> create_private_directory(path, expected_uid)
      {:error, _reason} -> {:error, :node_trust_storage_failed}
    end
  end

  defp create_private_directory(path, expected_uid \\ nil) do
    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, @directory_mode),
         :ok <- validate_private_directory(path, expected_uid) do
      :ok
    else
      _error -> {:error, :node_trust_storage_failed}
    end
  end

  defp validate_private_directory(path, expected_uid \\ nil) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory,
         true <- band(stat.mode, 0o777) == @directory_mode,
         true <- is_nil(expected_uid) or stat.uid == expected_uid do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :node_trust_storage_failed}
    end
  end

  defp verify_current_owner(root, root_uid) do
    probe = Path.join(root, ".owner-probe-#{Ecto.UUID.generate()}")

    result =
      with :ok <- write_private_file(probe, "owner"),
           {:ok, stat} <- File.stat(probe),
           true <- stat.uid == root_uid do
        :ok
      else
        _other -> {:error, :node_trust_storage_failed}
      end

    File.rm(probe)
    result
  end

  defp write_generation(staging_root, material) do
    metadata =
      material
      |> Map.take([
        :generation_id,
        :cluster_id,
        :controller_id,
        :trust_authority_id,
        :controller_uri_san,
        :ca_certificate_fingerprint,
        :ca_spki_fingerprint,
        :controller_certificate_fingerprint
      ])
      |> Jason.encode!()

    files = %{
      "ca-private-key.pem" => material.ca_private_key_pem,
      "ca-certificate.pem" => material.ca_certificate_pem,
      "controller-private-key.pem" => material.controller_private_key_pem,
      "controller-certificate.pem" => material.controller_certificate_pem,
      @metadata_file => metadata
    }

    Enum.reduce_while(files, :ok, fn {filename, contents}, :ok ->
      case write_private_file(Path.join(staging_root, filename), contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp publish_current(root, generation_id) do
    temporary = Path.join(root, ".current-#{Ecto.UUID.generate()}")
    current = Path.join(root, "current")

    with :ok <- write_private_file(temporary, generation_id <> "\n"),
         :ok <- publish_current_link(temporary, current),
         :ok <- File.rm(temporary),
         :ok <- sync_directory(root) do
      :ok
    else
      {:error, :eexist} ->
        File.rm(temporary)
        {:error, :node_trust_already_present}

      _error ->
        File.rm(temporary)
        {:error, :node_trust_storage_failed}
    end
  end

  defp publish_current_link(temporary, current) do
    File.ln(temporary, current)
  end

  defp write_private_file(path, contents) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, file} ->
        write_result =
          with :ok <- File.chmod(path, @file_mode),
               :ok <- IO.binwrite(file, contents),
               :ok <- :file.sync(file) do
            :ok
          else
            _error -> {:error, :node_trust_storage_failed}
          end

        close_result = File.close(file)

        if write_result == :ok and close_result == :ok do
          :ok
        else
          File.rm(path)
          {:error, :node_trust_storage_failed}
        end

      {:error, _reason} ->
        {:error, :node_trust_storage_failed}
    end
  end

  defp read_current(root, expected_uid) do
    current = Path.join(root, "current")

    with :ok <- validate_private_file(current, expected_uid),
         {:ok, contents} <- File.read(current) do
      contents
      |> String.trim()
      |> Ecto.UUID.cast()
    end
  end

  defp read_generation(generation_root, expected_uid) do
    required_files = [@metadata_file | @private_files ++ @public_files]

    with :ok <- validate_private_files(generation_root, required_files, expected_uid),
         {:ok, metadata_json} <- File.read(Path.join(generation_root, @metadata_file)),
         {:ok, metadata} <- Jason.decode(metadata_json),
         {:ok, ca_private_key_pem} <-
           File.read(Path.join(generation_root, "ca-private-key.pem")),
         {:ok, ca_certificate_pem} <-
           File.read(Path.join(generation_root, "ca-certificate.pem")),
         {:ok, controller_private_key_pem} <-
           File.read(Path.join(generation_root, "controller-private-key.pem")),
         {:ok, controller_certificate_pem} <-
           File.read(Path.join(generation_root, "controller-certificate.pem")) do
      {:ok,
       %{
         generation_id: metadata["generation_id"],
         cluster_id: metadata["cluster_id"],
         controller_id: metadata["controller_id"],
         trust_authority_id: metadata["trust_authority_id"],
         controller_uri_san: metadata["controller_uri_san"],
         ca_certificate_fingerprint: metadata["ca_certificate_fingerprint"],
         ca_spki_fingerprint: metadata["ca_spki_fingerprint"],
         controller_certificate_fingerprint: metadata["controller_certificate_fingerprint"],
         ca_private_key_pem: ca_private_key_pem,
         ca_certificate_pem: ca_certificate_pem,
         controller_private_key_pem: controller_private_key_pem,
         controller_certificate_pem: controller_certificate_pem
       }}
    else
      _error -> {:error, :node_trust_local_material_invalid}
    end
  end

  defp validate_private_files(root, files, expected_uid) do
    Enum.reduce_while(files, :ok, fn filename, :ok ->
      case validate_private_file(Path.join(root, filename), expected_uid) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_private_file(path, expected_uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular,
         true <- stat.uid == expected_uid,
         true <- band(stat.mode, 0o777) == @file_mode do
      :ok
    else
      {:error, :enoent} -> {:error, :enoent}
      _other -> {:error, :node_trust_local_material_invalid}
    end
  end

  defp sync_directory(path) do
    path = String.to_charlist(path)

    case :file.open(path, [:read, :raw, :directory]) do
      {:ok, file} ->
        sync_result = :file.sync(file)
        close_result = :file.close(file)

        if sync_result == :ok and close_result == :ok do
          :ok
        else
          {:error, :node_trust_storage_failed}
        end

      {:error, _reason} ->
        {:error, :node_trust_storage_failed}
    end
  end

  defp cleanup_publish_failure(root, material) do
    staging_root = Path.join(root, ".staging-#{material.generation_id}")
    stable_failure(staging_root, :node_trust_storage_failed)
  end

  defp stable_failure(staging_root, reason) do
    File.rm_rf(staging_root)
    {:error, reason}
  end
end
