defmodule Orchard.Node.ModelAcquisition.Source.File do
  @moduledoc """
  Source adapter for `file://` URIs.

  Copies a local model bundle directory into the staging path using
  `ArtifactBundle.copy_directory/2`, which rejects symlinks and
  unsupported file types.
  """

  @behaviour Orchard.Node.ModelAcquisition.SourceAdapter

  alias Orchard.ArtifactBundle
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.PathUtils

  @impl true
  def materialize(%Request{} = request) do
    with {:ok, source_path} <- parse_file_uri(request.artifact_source_uri),
         {:ok, canonical_path} <- resolve_source(source_path),
         :ok <- validate_source_directory(canonical_path) do
      ArtifactBundle.copy_directory(canonical_path, request.staging_path)
    end
  end

  defp parse_file_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", host: host, path: path}
      when path != nil and (host == nil or host == "" or host == "localhost") ->
        if Path.type(path) == :absolute do
          {:ok, path}
        else
          {:error, :invalid_source_uri}
        end

      _ ->
        {:error, :invalid_source_uri}
    end
  end

  defp parse_file_uri(_), do: {:error, :invalid_source_uri}

  defp resolve_source(path) do
    case PathUtils.resolve_realpath(path) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:source_not_found, "cannot resolve #{path}: #{inspect(reason)}"}}
    end
  end

  defp validate_source_directory(path) do
    cond do
      not File.exists?(path) ->
        {:error, {:source_not_found, "source path does not exist: #{path}"}}

      not File.dir?(path) ->
        {:error, {:source_not_directory, "expected a directory: #{path}"}}

      true ->
        :ok
    end
  end
end
