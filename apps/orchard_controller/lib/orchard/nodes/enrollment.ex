defmodule Orchard.Nodes.Enrollment do
  @moduledoc """
  Durable versioned persistence for one Node Enrollment.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.Node

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:pending_publication, :issued, :consumed, :revoked, :expired, :output_failed]
  @certificate_outcomes [:not_started, :pending, :issued, :failed]

  @type t :: %__MODULE__{}

  schema "node_enrollments" do
    field(:format_version, :integer, default: 1)
    belongs_to(:node, Node)
    field(:cluster_id, :binary_id)
    field(:expected_controller_id, :binary_id)
    field(:trust_authority_id, :binary_id)
    field(:token_prefix, :string)
    field(:token_hash, :string)
    field(:state, Ecto.Enum, values: @states, default: :pending_publication)
    field(:creator_type, :string)
    field(:creator_id, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:published_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:output_failed_at, :utc_datetime_usec)
    field(:csr_fingerprint, :string)
    field(:resume_verifier_metadata, :map, default: %{})

    field(:certificate_issuance_outcome, Ecto.Enum,
      values: @certificate_outcomes,
      default: :not_started
    )

    field(:certificate_identifier, :string)
    field(:certificate_result, :map, default: %{})
    field(:audit_metadata, :map, default: %{})
    field(:lock_version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(enrollment, attrs) do
    enrollment
    |> cast(attrs, [
      :id,
      :format_version,
      :node_id,
      :cluster_id,
      :expected_controller_id,
      :trust_authority_id,
      :token_prefix,
      :token_hash,
      :state,
      :creator_type,
      :creator_id,
      :issued_at,
      :expires_at,
      :published_at,
      :consumed_at,
      :revoked_at,
      :output_failed_at,
      :csr_fingerprint,
      :resume_verifier_metadata,
      :certificate_issuance_outcome,
      :certificate_identifier,
      :certificate_result,
      :audit_metadata,
      :lock_version
    ])
    |> validate_required([
      :format_version,
      :node_id,
      :cluster_id,
      :expected_controller_id,
      :trust_authority_id,
      :token_prefix,
      :token_hash,
      :state,
      :creator_type,
      :issued_at,
      :expires_at,
      :resume_verifier_metadata,
      :certificate_issuance_outcome,
      :certificate_result,
      :audit_metadata,
      :lock_version
    ])
    |> validate_number(:format_version, equal_to: 1)
    |> validate_expiry_window()
    |> unique_constraint(:node_id)
    |> unique_constraint(:token_prefix)
    |> unique_constraint(:token_hash)
    |> unique_constraint(:certificate_identifier)
    |> check_constraint(:format_version, name: :node_enrollments_format_version)
    |> check_constraint(:state, name: :node_enrollments_state)
    |> check_constraint(:certificate_issuance_outcome,
      name: :node_enrollments_certificate_issuance_outcome
    )
    |> check_constraint(:expires_at, name: :node_enrollments_expiry_window)
    |> check_constraint(:state, name: :node_enrollments_lifecycle_timestamps)
  end

  defp validate_expiry_window(changeset) do
    issued_at = get_field(changeset, :issued_at)
    expires_at = get_field(changeset, :expires_at)

    if is_struct(issued_at, DateTime) and is_struct(expires_at, DateTime) do
      maximum = DateTime.add(issued_at, 24, :hour)

      if DateTime.compare(expires_at, issued_at) == :gt and
           DateTime.compare(expires_at, maximum) in [:lt, :eq] do
        changeset
      else
        add_error(
          changeset,
          :expires_at,
          "must be after issuance and no more than 24 hours later"
        )
      end
    else
      changeset
    end
  end
end
