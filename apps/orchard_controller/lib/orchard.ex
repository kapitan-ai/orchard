defmodule Orchard do
  @moduledoc """
  Controller application namespace for Orchard.
  """

  @type canonical_request :: Orchard.CanonicalRequest.t()
  @type inference_event :: Orchard.InferenceEvent.t()
  @type model_manifest :: Orchard.ModelManifest.t()

  @spec version() :: String.t()
  def version do
    case Application.spec(:orchard_controller, :vsn) do
      nil -> "dev"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn when is_binary(vsn) -> vsn
      vsn -> to_string(vsn)
    end
  end
end
