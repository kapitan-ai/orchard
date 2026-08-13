defmodule Orchard.Governance.PortalInviteToken do
  @moduledoc "Hash-only single-use Portal Invite token."

  use Ecto.Schema
  import Ecto.Changeset

  alias Orchard.Governance.PortalUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "portal_invite_tokens" do
    field(:token_hash, :binary)
    field(:expires_at, :utc_datetime_usec)
    field(:redeemed_at, :utc_datetime_usec)
    belongs_to(:portal_user, PortalUser)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:portal_user_id, :token_hash, :expires_at, :redeemed_at])
    |> validate_required([:portal_user_id, :token_hash, :expires_at])
    |> unique_constraint(:portal_user_id)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:portal_user_id)
  end
end
