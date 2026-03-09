defmodule Orchard.Node.SharedContract do
  @moduledoc false

  defdelegate request_model_ref(request), to: Orchard.SharedContract
  defdelegate event_kind(event), to: Orchard.SharedContract
  defdelegate manifest_proto_model_ref(manifest), to: Orchard.SharedContract
end
