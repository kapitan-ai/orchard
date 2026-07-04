defmodule Orchard.API.OperatorRequestContext do
  @moduledoc """
  Plug that resolves and authorizes `/ops/v1/*` caller context.
  """

  use Orchard.API.ScopedRequestContext,
    authorizer: &Orchard.Governance.authorize_operator_api/1,
    required_code: "operator_required",
    required_message: "Operator API requires a cluster-scoped operator or admin API Client token."
end
