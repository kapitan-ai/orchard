defmodule Orchard.API.AdminRequestContext do
  @moduledoc """
  Plug that resolves and authorizes `/admin/v1/*` caller context.
  """

  use Orchard.API.ScopedRequestContext,
    authorizer: &Orchard.Governance.authorize_admin_api/1,
    required_code: "admin_required",
    required_message: "Admin API requires a cluster-scoped admin API Client token."
end
