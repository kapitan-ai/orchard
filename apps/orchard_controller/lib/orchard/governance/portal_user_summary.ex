defmodule Orchard.Governance.PortalUserSummary do
  @moduledoc """
  Secret-free Portal User row for Console presentation.
  """

  @enforce_keys [:id, :email, :status, :invite_context, :invite_expires_at]
  defstruct [:id, :email, :status, :invite_context, :invite_expires_at]

  @type invite_context :: :not_issued | :pending | :expired | :redeemed | nil

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          email: String.t(),
          status: String.t(),
          invite_context: invite_context(),
          invite_expires_at: DateTime.t() | nil
        }
end
