defmodule Orchard.Governance.PortalSession do
  @moduledoc """
  Persisted Organization portal session.

  The raw cookie token is never stored. Only its SHA-256 digest is kept.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "portal_sessions" do
    field(:token_hash, :binary)
    field(:password_epoch, :integer)
    field(:issued_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)
    field(:absolute_expires_at, :utc_datetime_usec)

    belongs_to(:tenant, Tenant)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :tenant_id,
      :token_hash,
      :password_epoch,
      :issued_at,
      :last_seen_at,
      :absolute_expires_at
    ])
    |> validate_required([
      :tenant_id,
      :token_hash,
      :password_epoch,
      :issued_at,
      :last_seen_at,
      :absolute_expires_at
    ])
    |> validate_number(:password_epoch, greater_than_or_equal_to: 0)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:tenant_id)
  end
end
