defmodule Orchard.Nodes.TrustAuthority do
  @moduledoc """
  Public metadata for the active internal Node trust authority.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.ClusterIdentity

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @states [:active, :retired]

  @type t :: %__MODULE__{}

  schema "node_trust_authorities" do
    belongs_to(:cluster, ClusterIdentity)
    field(:state, Ecto.Enum, values: @states, default: :active)
    field(:material_generation, :binary_id)
    field(:ca_certificate_pem, :string)
    field(:ca_certificate_fingerprint, :string)
    field(:ca_spki_fingerprint, :string)
    field(:controller_certificate_pem, :string)
    field(:controller_certificate_fingerprint, :string)
    field(:controller_uri_san, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(authority, attrs) do
    authority
    |> cast(attrs, [
      :id,
      :cluster_id,
      :state,
      :material_generation,
      :ca_certificate_pem,
      :ca_certificate_fingerprint,
      :ca_spki_fingerprint,
      :controller_certificate_pem,
      :controller_certificate_fingerprint,
      :controller_uri_san
    ])
    |> validate_required([
      :id,
      :cluster_id,
      :state,
      :material_generation,
      :ca_certificate_pem,
      :ca_certificate_fingerprint,
      :ca_spki_fingerprint,
      :controller_certificate_pem,
      :controller_certificate_fingerprint,
      :controller_uri_san
    ])
    |> foreign_key_constraint(:cluster_id)
    |> unique_constraint(:material_generation)
    |> unique_constraint(:ca_certificate_fingerprint)
    |> unique_constraint(:ca_spki_fingerprint)
    |> unique_constraint(:controller_certificate_fingerprint)
    |> unique_constraint(:cluster_id,
      name: :idx_node_trust_authorities_one_active_per_cluster
    )
    |> check_constraint(:state, name: :node_trust_authorities_state)
  end
end
