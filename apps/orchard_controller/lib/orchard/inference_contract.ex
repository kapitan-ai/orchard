defmodule Orchard.InferenceContract do
  @moduledoc false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef

  @spec request_model_ref(CanonicalRequest.t()) :: ModelRef.t()
  defdelegate request_model_ref(request), to: Orchard.SharedContract
  defdelegate event_kind(event), to: Orchard.SharedContract
  defdelegate manifest_proto_model_ref(manifest), to: Orchard.SharedContract
end
