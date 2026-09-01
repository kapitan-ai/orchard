defmodule Orchard.Governance.TenantApiKeySummary do
  @moduledoc """
  Secret-free tenant-direct API Token row for Console presentation.
  """

  @enforce_keys [
    :id,
    :name,
    :token_prefix,
    :issuance_surface,
    :portal_user_email,
    :expires_at,
    :last_used_at,
    :revoked_at,
    :inserted_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          token_prefix: String.t(),
          issuance_surface: String.t(),
          portal_user_email: String.t() | nil,
          expires_at: DateTime.t() | nil,
          last_used_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: DateTime.t()
        }

  @spec status(t(), DateTime.t()) :: :active | :expired | :revoked
  def status(%__MODULE__{revoked_at: %DateTime{}}, _now), do: :revoked

  def status(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt, do: :active, else: :expired
  end

  def status(%__MODULE__{}, %DateTime{}), do: :active
end
