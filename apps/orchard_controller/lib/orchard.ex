defmodule Orchard do
  @moduledoc """
  Controller application namespace for Orchard.
  """

  @type canonical_request :: Orchard.CanonicalRequest.t()
  @type inference_event :: Orchard.InferenceEvent.t()
  @type model_manifest :: Orchard.ModelManifest.t()

  @spec version() :: String.t()
  def version, do: "0.1.0"
end
