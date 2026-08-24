defmodule Orchard.Governance.PortalUser do
  @moduledoc "Named identity authorized only for one Organization Developer Portal."

  use Ecto.Schema
  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, PortalInviteToken, PortalSession, Tenant}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @type t :: %__MODULE__{}

  schema "portal_users" do
    field(:email, :string)
    field(:password_hash, :string)
    field(:status, :string, default: "invited")
    field(:session_epoch, :integer, default: 0)
    field(:disabled_at, :utc_datetime_usec)
    belongs_to(:tenant, Tenant)
    has_many(:invite_tokens, PortalInviteToken)
    has_many(:sessions, PortalSession)
    has_many(:api_keys, ApiKey)
    timestamps(type: :utc_datetime_usec)
  end

  @spec invite_changeset(t(), map()) :: Ecto.Changeset.t()
  def invite_changeset(user, attrs) do
    user
    |> cast(attrs, [:tenant_id, :email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:tenant_id, :email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
    |> unique_constraint([:tenant_id, :email])
    |> foreign_key_constraint(:tenant_id)
  end

  @spec activation_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def activation_changeset(%__MODULE__{status: "invited"} = user, password_hash) do
    change(user,
      password_hash: password_hash,
      status: "active",
      disabled_at: nil,
      session_epoch: user.session_epoch + 1
    )
  end

  def activation_changeset(user, _password_hash) do
    user
    |> change()
    |> add_error(:status, "must be invited")
  end

  @spec disable_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def disable_changeset(user, now) do
    change(user, status: "disabled", disabled_at: now, session_epoch: user.session_epoch + 1)
  end

  @spec normalize_email(term()) :: String.t()
  def normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  def normalize_email(_email), do: ""
end
