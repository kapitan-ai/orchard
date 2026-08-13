defmodule Orchard.Governance.PortalApiKeySummary do
  @moduledoc """
  Read-only tenant-direct API Key row for the developer portal list.
  """

  @enforce_keys [
    :id,
    :name,
    :token_prefix,
    :issuance_surface,
    :status,
    :request_count,
    :revocable?,
    :inserted_at
  ]
  defstruct [
    :id,
    :name,
    :token_prefix,
    :issuance_surface,
    :status,
    :request_count,
    :revocable?,
    :inserted_at,
    :last_used_at,
    :expires_at,
    :revoked_at
  ]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          token_prefix: String.t(),
          issuance_surface: String.t(),
          status: :active | :expired | :revoked,
          request_count: non_neg_integer(),
          revocable?: boolean(),
          inserted_at: DateTime.t(),
          last_used_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil
        }
end
