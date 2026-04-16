defmodule Orchard.NodeIdentityFile do
  @moduledoc """
  Shared file helpers for Orchard node identity persistence.

  Preserves Orchard's existing UUID format and first-boot generation semantics
  so node identity can be shared across releases without depending on
  `orchard_node_agent`.
  """

  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @identity_mode 0o600

  @type read_error ::
          :enoent | {:invalid_uuid, String.t()} | {:read_failed, File.posix()}

  @type ensure_error ::
          {:invalid_uuid, String.t()}
          | {:read_failed, File.posix()}
          | {:write_failed, File.posix()}

  @type ensure_source :: :existing | :generated

  @doc """
  Read an existing Orchard node identity file without generating a new UUID.
  """
  @spec read(String.t()) :: {:ok, String.t()} | {:error, read_error()}
  def read(path) do
    case File.read(path) do
      {:ok, content} ->
        validate_uuid(String.trim(content))

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  @doc """
  Ensure an Orchard node identity file exists, generating and atomically
  persisting a new UUIDv4 when needed.
  """
  @spec ensure(String.t()) :: {:ok, String.t(), ensure_source()} | {:error, ensure_error()}
  def ensure(path) do
    case read(path) do
      {:ok, uuid} ->
        {:ok, uuid, :existing}

      {:error, :enoent} ->
        generate_and_persist(path)

      {:error, _reason} = error ->
        error
    end
  end

  defp generate_and_persist(path) do
    uuid = generate_uuid()
    dir = Path.dirname(path)
    tmp_path = path <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(4))

    case File.mkdir_p(dir) do
      :ok ->
        persist_generated_uuid(path, tmp_path, uuid)

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp persist_generated_uuid(path, tmp_path, uuid) do
    contents = uuid <> "\n"

    with :ok <- File.write(tmp_path, contents),
         :ok <- File.chmod(tmp_path, @identity_mode) do
      publish_generated_uuid(path, tmp_path, uuid)
    else
      {:error, reason} ->
        cleanup_tmp(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  defp publish_generated_uuid(path, tmp_path, uuid) do
    case File.ln(tmp_path, path) do
      :ok ->
        cleanup_tmp(tmp_path)
        {:ok, uuid, :generated}

      {:error, :eexist} ->
        cleanup_tmp(tmp_path)
        adopt_existing_uuid(path)

      {:error, reason} ->
        cleanup_tmp(tmp_path)
        {:error, {:write_failed, reason}}
    end
  end

  defp adopt_existing_uuid(path) do
    case read(path) do
      {:ok, uuid} ->
        {:ok, uuid, :existing}

      {:error, :enoent} ->
        {:error, {:write_failed, :enoent}}

      {:error, {:invalid_uuid, _value} = error} ->
        {:error, error}

      {:error, {:read_failed, _reason} = error} ->
        {:error, error}
    end
  end

  defp cleanup_tmp(tmp_path) do
    case File.rm(tmp_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp validate_uuid(value) do
    if Regex.match?(@uuid_regex, value) do
      {:ok, value}
    else
      {:error, {:invalid_uuid, value}}
    end
  end

  defp generate_uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<g1::binary-8, g2::binary-4, g3::binary-4, g4::binary-4, g5::binary-12>> = hex
      "#{g1}-#{g2}-#{g3}-#{g4}-#{g5}"
    end)
  end
end
