defmodule Orchard.LocalNodeIdentity do
  @moduledoc """
  Read-only local association from the installation-selected Node Join store.

  Returns registered identity identifiers only. Private keys and certificates
  remain in Node custody; this projection grants no trust or execution authority.
  """

  import Bitwise, only: [band: 2]

  @type t :: %{
          node_id: String.t(),
          enrollment_id: String.t(),
          certificate_identifier: String.t()
        }
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @doc "Reads protected registered metadata without creating or modifying custody."
  @spec read(String.t() | nil) :: {:ok, t()} | {:error, :not_configured | :identity_unavailable}
  def read(nil), do: {:error, :not_configured}
  def read(""), do: {:error, :not_configured}

  def read(root) when is_binary(root) do
    with {:ok, stat} <- File.lstat(root),
         true <- stat.type == :directory and band(stat.mode, 0o777) == 0o700,
         {:ok, current} <- private_read(Path.join(root, "current"), stat.uid),
         generation = String.trim(current),
         true <- uuid?(generation),
         :ok <- private_directory(Path.join(root, "generations"), stat.uid),
         directory = Path.join([root, "generations", generation]),
         :ok <- private_directory(directory, stat.uid),
         {:ok, json} <- private_read(Path.join(directory, "metadata.json"), stat.uid),
         {:ok, metadata} <- Jason.decode(json),
         %{"state" => "registered", "generation_id" => ^generation} <- metadata,
         true <- uuid?(metadata["node_id"]) and uuid?(metadata["enrollment_id"]),
         certificate when is_binary(certificate) and byte_size(certificate) in 1..512 <-
           metadata["certificate_identifier"],
         {:ok, ^current} <- private_read(Path.join(root, "current"), stat.uid) do
      {:ok,
       %{
         node_id: metadata["node_id"],
         enrollment_id: metadata["enrollment_id"],
         certificate_identifier: certificate
       }}
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp private_directory(path, uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :directory and stat.uid == uid and band(stat.mode, 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp private_read(path, uid) do
    with {:ok, stat} <- File.lstat(path),
         true <- stat.type == :regular and stat.uid == uid and band(stat.mode, 0o777) == 0o600,
         true <- stat.size <= 16_384 do
      File.read(path)
    else
      _ -> {:error, :identity_unavailable}
    end
  end

  defp uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
end
