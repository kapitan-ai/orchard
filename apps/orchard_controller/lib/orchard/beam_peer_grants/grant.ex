defmodule Orchard.BeamPeerGrants.Grant do
  @moduledoc """
  Durable non-secret scope and lifecycle evidence for one exact BEAM pair.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [
    :pending_delivery,
    :staged,
    :active,
    :superseded,
    :revoked,
    :expired,
    :delivery_failed
  ]

  @type t :: %__MODULE__{}

  schema "beam_peer_grants" do
    field(:generation, :integer)
    field(:cluster_id, :binary_id)
    field(:controller_id, :binary_id)
    field(:controller_beam_name, :string)
    field(:controller_certificate_identifier, :string)
    field(:controller_certificate_fingerprint_sha256, :string)
    field(:beam_authorization_root_id, :binary_id)
    field(:node_id, :binary_id)
    field(:node_beam_name, :string)
    field(:node_certificate_identifier, :string)
    field(:node_certificate_fingerprint_sha256, :string)
    field(:contract_version, :integer)
    field(:purpose, :string)
    field(:state, Ecto.Enum, values: @states)
    field(:secret_hash, :binary)
    field(:issued_at, :utc_datetime_usec)
    field(:not_before_at, :utc_datetime_usec)
    field(:cutover_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:delivery_evidence, :map, default: %{})
    field(:activation_evidence, :map, default: %{})
    field(:supersession_evidence, :map, default: %{})
    field(:failure_evidence, :map, default: %{})
    field(:revocation_evidence, :map, default: %{})
    field(:delivered_at, :utc_datetime_usec)
    field(:activated_at, :utc_datetime_usec)
    field(:superseded_at, :utc_datetime_usec)
    field(:failed_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
  def insert_changeset(grant, attrs) do
    grant
    |> cast(attrs, scope_fields() ++ lifecycle_fields())
    |> validate_required(required_scope_fields() ++ required_lifecycle_fields())
    |> validate_number(:generation, greater_than: 0)
    |> validate_number(:contract_version, greater_than: 0)
    |> unique_constraint(
      [:cluster_id, :controller_id, :node_id, :purpose, :generation],
      name: :beam_peer_grants_pair_generation
    )
    |> unique_constraint([:cluster_id, :controller_id, :node_id, :purpose],
      name: :beam_peer_grants_one_active
    )
    |> unique_constraint([:cluster_id, :controller_id, :node_id, :purpose],
      name: :beam_peer_grants_one_staged
    )
    |> check_constraint(:generation, name: :beam_peer_grants_generation)
    |> check_constraint(:contract_version, name: :beam_peer_grants_contract_version)
    |> check_constraint(:secret_hash, name: :beam_peer_grants_secret_hash)
    |> check_constraint(:expires_at, name: :beam_peer_grants_validity)
    |> check_constraint(:cutover_at, name: :beam_peer_grants_cutover)
  end

  defp scope_fields do
    [
      :id,
      :generation,
      :cluster_id,
      :controller_id,
      :controller_beam_name,
      :controller_certificate_identifier,
      :controller_certificate_fingerprint_sha256,
      :beam_authorization_root_id,
      :node_id,
      :node_beam_name,
      :node_certificate_identifier,
      :node_certificate_fingerprint_sha256,
      :contract_version,
      :purpose,
      :secret_hash,
      :issued_at,
      :not_before_at,
      :cutover_at,
      :expires_at
    ]
  end

  defp lifecycle_fields do
    [
      :state,
      :delivery_evidence,
      :activation_evidence,
      :supersession_evidence,
      :failure_evidence,
      :revocation_evidence,
      :delivered_at,
      :activated_at,
      :superseded_at,
      :failed_at,
      :revoked_at
    ]
  end

  defp required_scope_fields do
    scope_fields() -- [:cutover_at]
  end

  defp required_lifecycle_fields do
    [
      :state,
      :delivery_evidence,
      :activation_evidence,
      :supersession_evidence,
      :failure_evidence,
      :revocation_evidence
    ]
  end
end
