defmodule Orchard.Node.ModelAcquisition.Request do
  @moduledoc """
  Normalized acquisition request struct.

  Encapsulates path derivation, URI parsing, and containment validation
  so that downstream acquisition code operates on pre-validated fields.
  """

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest

  @type t :: %__MODULE__{
          model_id: String.t(),
          version: String.t(),
          artifact_sha256: String.t(),
          artifact_source_uri: String.t() | nil,
          source_scheme: String.t() | nil,
          deadline_unix_ms: non_neg_integer(),
          models_root: String.t(),
          final_path: String.t(),
          staging_path: String.t()
        }

  @enforce_keys [
    :model_id,
    :version,
    :artifact_sha256,
    :deadline_unix_ms,
    :models_root,
    :final_path,
    :staging_path
  ]

  defstruct [
    :model_id,
    :version,
    :artifact_sha256,
    :artifact_source_uri,
    :source_scheme,
    :deadline_unix_ms,
    :models_root,
    :final_path,
    :staging_path
  ]

  @doc """
  Build a `%Request{}` from an `EnsureModelLoadedRequest` proto and a models root path.

  Validates that required fields are present, parses the source URI scheme,
  and derives staging/final paths with containment checks.

  Returns `{:ok, request}` or `{:error, reason}`.
  """
  @spec from_proto(EnsureModelLoadedRequest.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_proto(%EnsureModelLoadedRequest{} = proto, models_root) do
    with :ok <- validate_required(proto),
         {:ok, source_uri, scheme} <- normalize_source_uri(proto.artifact_source_uri),
         {:ok, final_path, staging_path} <-
           derive_paths(proto.model_id, proto.version, models_root) do
      {:ok,
       %__MODULE__{
         model_id: proto.model_id,
         version: proto.version,
         artifact_sha256: proto.artifact_sha256,
         artifact_source_uri: source_uri,
         source_scheme: scheme,
         deadline_unix_ms: proto.deadline_unix_ms || 0,
         models_root: models_root,
         final_path: final_path,
         staging_path: staging_path
       }}
    end
  end

  defp validate_required(%EnsureModelLoadedRequest{} = proto) do
    cond do
      blank?(proto.model_id) -> {:error, :missing_model_id}
      blank?(proto.version) -> {:error, :missing_version}
      blank?(proto.artifact_sha256) -> {:error, :missing_artifact_sha256}
      true -> :ok
    end
  end

  defp normalize_source_uri(nil), do: {:ok, nil, nil}
  defp normalize_source_uri(""), do: {:ok, nil, nil}

  defp normalize_source_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: nil} -> {:error, :invalid_source_uri}
      %URI{scheme: scheme} -> {:ok, uri, scheme}
    end
  end

  defp derive_paths(model_id, version, models_root) do
    with :ok <- validate_path_segments(model_id, version) do
      # Resolve models_root to canonical path to catch symlink-based escapes.
      # Construct final/staging paths from the canonical root so both share
      # the same prefix (avoids macOS /tmp → /private/tmp mismatch).
      canonical_root = canonical_models_root(models_root)

      canonical_final = Path.join([canonical_root, model_id, version])
      canonical_staging = Path.join([canonical_root, ".staging", model_id, version])

      cond do
        not String.starts_with?(canonical_final, canonical_root <> "/") ->
          {:error, :path_escape}

        not String.starts_with?(canonical_staging, canonical_root <> "/") ->
          {:error, :path_escape}

        true ->
          # Return paths using the original models_root for caller consistency
          final_path = Path.join([models_root, model_id, version])
          staging_path = Path.join([models_root, ".staging", model_id, version])
          {:ok, final_path, staging_path}
      end
    end
  end

  defp canonical_models_root(models_root) do
    case Orchard.PathUtils.resolve_realpath(models_root) do
      {:ok, canonical} -> canonical
      {:error, _} -> Path.expand(models_root)
    end
  end

  defp validate_path_segments(model_id, version) do
    segments = Path.split(model_id) ++ Path.split(version)

    if Enum.any?(segments, &(&1 == ".." or &1 == "." or &1 == "")) do
      {:error, :path_escape}
    else
      :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
