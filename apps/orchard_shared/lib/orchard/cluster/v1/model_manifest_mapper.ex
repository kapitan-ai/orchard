defmodule Orchard.Cluster.V1.ModelManifestMapper do
  @moduledoc false

  alias Orchard.Cluster.V1
  alias Orchard.ModelManifest

  @spec to_model_ref(ModelManifest.t()) :: V1.ModelRef.t()
  def to_model_ref(%ModelManifest{model_id: model_id, version: version}) do
    %V1.ModelRef{model_id: model_id, version: version}
  end
end
