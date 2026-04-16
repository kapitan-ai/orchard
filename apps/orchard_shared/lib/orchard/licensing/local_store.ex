defmodule Orchard.Licensing.LocalStore do
  @moduledoc false

  @bundle_keys ["license_certificate", "machine_certificate"]
  @bundle_mode 0o600

  @type bundle_pair :: %{
          license_certificate: String.t(),
          machine_certificate: String.t()
        }

  @type read_error :: :enoent | {:malformed_bundle, String.t()} | {:read_failed, File.posix()}

  @doc """
  Read the Orchard-owned licensing bundle from disk.
  """
  @spec read(String.t()) :: {:ok, bundle_pair()} | {:error, read_error()}
  def read(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode_bundle(contents)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Atomically write the Orchard-owned licensing bundle to disk using mode 0600.
  """
  @spec write(String.t(), bundle_pair()) :: :ok | {:error, {:write_failed, File.posix()}}
  def write(path, %{license_certificate: license, machine_certificate: machine})
      when is_binary(license) and is_binary(machine) do
    dir = Path.dirname(path)
    tmp_path = path <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(4))
    contents = encode_bundle(%{license_certificate: license, machine_certificate: machine})

    case File.mkdir_p(dir) do
      :ok ->
        write_bundle_file(path, tmp_path, contents)

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp decode_bundle(contents) do
    case Jason.decode(contents) do
      {:ok, %{} = decoded} ->
        normalize_bundle(decoded)

      {:ok, _other} ->
        {:error, {:malformed_bundle, "licensing bundle must be a JSON object"}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:malformed_bundle, Exception.message(error)}}
    end
  end

  defp normalize_bundle(decoded) do
    keys = decoded |> Map.keys() |> Enum.sort()

    if keys == Enum.sort(@bundle_keys) do
      case decoded do
        %{"license_certificate" => license, "machine_certificate" => machine}
        when is_binary(license) and is_binary(machine) ->
          {:ok, %{license_certificate: license, machine_certificate: machine}}

        _other ->
          {:error,
           {:malformed_bundle,
            "licensing bundle must contain string license_certificate and machine_certificate fields"}}
      end
    else
      {:error,
       {:malformed_bundle,
        "licensing bundle must contain only license_certificate and machine_certificate fields"}}
    end
  end

  defp encode_bundle(%{license_certificate: license, machine_certificate: machine}) do
    Jason.encode!(%{"license_certificate" => license, "machine_certificate" => machine},
      pretty: true
    ) <>
      "\n"
  end

  defp write_bundle_file(path, tmp_path, contents) do
    case File.write(tmp_path, contents) do
      :ok ->
        chmod_and_rename(path, tmp_path)

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp chmod_and_rename(path, tmp_path) do
    case File.chmod(tmp_path, @bundle_mode) do
      :ok ->
        rename_bundle(path, tmp_path)

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  defp rename_bundle(path, tmp_path) do
    case File.rename(tmp_path, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end
end
