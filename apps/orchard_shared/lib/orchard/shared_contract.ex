defmodule Orchard.SharedContract do
  @moduledoc false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Cluster.V1.ModelManifestMapper
  alias Orchard.InferenceEvent
  alias Orchard.ModelManifest

  @spec request_model_ref(CanonicalRequest.t()) :: ModelRef.t()
  def request_model_ref(%CanonicalRequest{model_ref: model_ref}), do: model_ref

  @spec event_kind(InferenceEvent.t()) :: atom()
  def event_kind(%InferenceEvent{} = event), do: InferenceEvent.kind(event)

  @spec manifest_proto_model_ref(ModelManifest.t()) :: Orchard.Cluster.V1.ModelRef.t()
  def manifest_proto_model_ref(%ModelManifest{} = manifest),
    do: ModelManifestMapper.to_model_ref(manifest)
end
