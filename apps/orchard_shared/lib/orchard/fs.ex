defmodule Orchard.FS do
  @moduledoc """
  Shared filesystem helpers for artifact-safe writes.
  """

  @type atomic_write_opts :: [modes: [File.mode()], permissions: non_neg_integer()]

  @doc """
  Writes `content` to `path` through a same-filesystem temporary file.

  The temporary file is created one directory above the final file's parent.
  For bundle manifests, that keeps the temp file outside the hashed bundle tree
  while preserving atomic rename semantics on the artifact filesystem.
  """
  @spec atomic_write!(Path.t(), iodata(), atomic_write_opts()) :: :ok
  def atomic_write!(path, content, opts \\ []) when is_binary(path) do
    tmp_path = atomic_temp_path(path)
    modes = Keyword.get(opts, :modes, [:binary])
    permissions = Keyword.get(opts, :permissions)

    try do
      prepare_temp_file!(tmp_path, permissions)
      File.write!(tmp_path, content, modes)
      File.rename!(tmp_path, path)
      :ok
    rescue
      error ->
        File.rm(tmp_path)
        reraise(error, __STACKTRACE__)
    end
  end

  defp prepare_temp_file!(_tmp_path, nil), do: :ok

  defp prepare_temp_file!(tmp_path, permissions) do
    File.open!(tmp_path, [:write, :exclusive], fn _file -> :ok end)
    File.chmod!(tmp_path, permissions)
  end

  @spec atomic_temp_path(Path.t()) :: Path.t()
  defp atomic_temp_path(path) do
    path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.join(".tmp-#{System.unique_integer([:positive])}")
  end
end
