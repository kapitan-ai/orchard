defmodule Orchard.Models.ModelRenderAssets do
  @moduledoc "Shared admitted bundle metadata for discovery and request rendering."

  alias Orchard.Models
  alias Orchard.Models.ManifestParser

  @spec load(Orchard.Models.Model.t(), :preparation | :discovery) ::
          {:ok, keyword()} | {:error, term()}
  def load(model, mode \\ :preparation) do
    with {:ok, bundle_root} <- bundle_root(model, mode),
         {:ok, manifest} <- parse_manifest(bundle_root, mode) do
      {:ok, [manifest: manifest, bundle_root: bundle_root, bundle_sha256: model.artifact_sha256]}
    else
      {:error, _reason} ->
        {:error,
         {:tokenization, {:internal_error, "model manifest could not be loaded for tokenization"}}}
    end
  end

  defp bundle_root(model, :discovery), do: Models.artifact_local_path(model)
  defp bundle_root(model, :preparation), do: {:ok, local_path(model.artifact_uri)}

  defp parse_manifest(bundle_root, :preparation),
    do: ManifestParser.parse_from_bundle(bundle_root)

  defp parse_manifest(bundle_root, :discovery) do
    manifest_uri =
      "file://" <>
        URI.encode(
          Path.join(bundle_root, "manifest.json"),
          &(&1 == ?/ or URI.char_unreserved?(&1))
        )

    with {:ok, manifest_path} <- Models.artifact_local_path(manifest_uri),
         {:ok, json} <- File.read(manifest_path) do
      ManifestParser.parse_json(json)
    end
  rescue
    exception in [KeyError, ArgumentError, FunctionClauseError, BadMapError, File.Error] ->
      {:error, {:invalid_discovery_metadata, exception.__struct__}}
  end

  defp local_path("file://" <> path), do: path
  defp local_path(path), do: path
end
