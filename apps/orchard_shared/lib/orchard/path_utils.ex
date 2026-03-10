defmodule Orchard.PathUtils do
  @moduledoc """
  Path utilities shared across Orchard apps.
  """

  # Canonicalize a path by walking each component and resolving symlinks.
  # Returns {:ok, canonical_path} or {:error, posix_reason}.
  @max_symlink_depth 40

  @doc """
  Resolve a filesystem path to its canonical form by expanding symlinks.

  Walks each path component and resolves symlinks encountered along the way,
  guarding against symlink loops with a depth limit of #{@max_symlink_depth}.

  Returns `{:ok, canonical_path}` or `{:error, posix_reason}`.
  """
  @spec resolve_realpath(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve_realpath(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_realpath_components("/", @max_symlink_depth)
  end

  defp resolve_realpath_components([], acc, _depth), do: {:ok, acc}
  defp resolve_realpath_components(_rest, _acc, 0), do: {:error, :eloop}

  defp resolve_realpath_components([component | rest], acc, depth) do
    current = Path.join(acc, component)

    case File.lstat(current) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(current) do
          {:ok, target} ->
            resolved = Path.expand(target, acc)
            # Re-split the resolved target to walk through it (handles chained symlinks)
            new_components = Path.split(resolved) ++ rest
            resolve_realpath_components(tl(new_components), "/", depth - 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _stat} ->
        resolve_realpath_components(rest, current, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
