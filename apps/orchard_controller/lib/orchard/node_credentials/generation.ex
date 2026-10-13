defmodule Orchard.NodeCredentials.Generation do
  @moduledoc """
  Durable public authority state for one Node certificate generation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @states [:current, :staged, :superseded, :revoked]

  @type t :: %__MODULE__{}

  schema "node_credential_generations" do
    field(:generation, :integer)
    field(:state, Ecto.Enum, values: @states)
    field(:cluster_id, :binary_id)
    field(:controller_id, :binary_id)
    field(:trust_authority_id, :binary_id)
    field(:certificate_identifier, :string)
    field(:certificate_fingerprint_sha256, :string)
    field(:csr_fingerprint_sha256, :string)
    field(:public_key_fingerprint_sha256, :string)
    field(:certificate_result, :map)
    field(:issued_at, :utc_datetime_usec)
    field(:not_before_at, :utc_datetime_usec)
    field(:not_after_at, :utc_datetime_usec)
    field(:renew_after_at, :utc_datetime_usec)
    field(:staged_at, :utc_datetime_usec)
    field(:overlap_ends_at, :utc_datetime_usec)
    field(:activated_at, :utc_datetime_usec)
    field(:superseded_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:transition_evidence, :map, default: %{})

    belongs_to(:node, Orchard.Nodes.Node)
    belongs_to(:enrollment, Orchard.Nodes.Enrollment)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(generation, attrs) do
    generation
    |> cast(attrs, fields())
    |> validate_required(required_fields())
    |> validate_number(:generation, greater_than: 0)
    |> unique_constraint([:node_id, :generation],
      name: :node_credential_generations_node_generation
    )
    |> unique_constraint(:certificate_identifier,
      name: :node_credential_generations_certificate_identifier
    )
    |> unique_constraint(:node_id, name: :node_credential_generations_one_current)
    |> unique_constraint(:node_id, name: :node_credential_generations_one_staged)
    |> check_constraint(:generation, name: :node_credential_generations_generation)
    |> check_constraint(:state, name: :node_credential_generations_state)
    |> check_constraint(:not_before_at, name: :node_credential_generations_validity)
  end

  defp fields do
    [
      :id,
      :node_id,
      :enrollment_id,
      :generation,
      :state,
      :cluster_id,
      :controller_id,
      :trust_authority_id,
      :certificate_identifier,
      :certificate_fingerprint_sha256,
      :csr_fingerprint_sha256,
      :public_key_fingerprint_sha256,
      :certificate_result,
      :issued_at,
      :not_before_at,
      :not_after_at,
      :renew_after_at,
      :staged_at,
      :overlap_ends_at,
      :activated_at,
      :superseded_at,
      :revoked_at,
      :transition_evidence
    ]
  end

  defp required_fields do
    fields() -- [:staged_at, :overlap_ends_at, :activated_at, :superseded_at, :revoked_at]
  end
end
