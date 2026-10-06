defmodule Orchard.Models.ModelRenderAssets do
  @moduledoc "Shared admitted bundle metadata for discovery and request rendering."

  alias Orchard.Models.ManifestParser

  @spec load(Orchard.Models.Model.t(), :preparation | :discovery) ::
          {:ok, keyword()} | {:error, term()}
  def load(model, mode \\ :preparation) do
    bundle_root = local_path(model.artifact_uri)

    case parse_manifest(bundle_root, mode) do
      {:ok, manifest} ->
        {:ok,
         [manifest: manifest, bundle_root: bundle_root, bundle_sha256: model.artifact_sha256]}

      {:error, _reason} ->
        {:error,
         {:tokenization, {:internal_error, "model manifest could not be loaded for tokenization"}}}
    end
  end

  defp parse_manifest(bundle_root, :preparation),
    do: ManifestParser.parse_from_bundle(bundle_root)

  defp parse_manifest(bundle_root, :discovery) do
    with {:ok, json} <- File.read(Path.join(bundle_root, "manifest.json")) do
      ManifestParser.parse_json(json)
    end
  end

  defp local_path("file://" <> path), do: path
  defp local_path(path), do: path
end
