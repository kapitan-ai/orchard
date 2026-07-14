defmodule Orchard.ControllerInstances.ControllerInstance do
  @moduledoc """
  Durable identity for one enrolled Controller instance.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @statuses [:enrolled, :operational, :recovery_required, :retired]

  @type t :: %__MODULE__{}

  schema "controller_instances" do
    field(:certificate_uri_san, :string)
    field(:certificate_identifier, :string)
    field(:certificate_fingerprint_sha256, :string)
    field(:canonical_beam_name, :string)
    field(:beam_authorization_root_id, :binary_id)
    field(:authorization_root_custody_ref, :string)
    field(:status, Ecto.Enum, values: @statuses)
    field(:first_enrolled_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :id,
      :certificate_uri_san,
      :certificate_identifier,
      :certificate_fingerprint_sha256,
      :canonical_beam_name,
      :beam_authorization_root_id,
      :authorization_root_custody_ref,
      :status,
      :first_enrolled_at,
      :last_seen_at
    ])
    |> validate_required([
      :id,
      :certificate_uri_san,
      :certificate_identifier,
      :certificate_fingerprint_sha256,
      :canonical_beam_name,
      :beam_authorization_root_id,
      :authorization_root_custody_ref,
      :status,
      :first_enrolled_at
    ])
    |> unique_constraint(:certificate_uri_san)
    |> unique_constraint(:canonical_beam_name)
    |> unique_constraint(:beam_authorization_root_id)
    |> check_constraint(:status, name: :controller_instances_status)
  end
end
