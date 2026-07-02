defmodule Orchard.Nodes.AdmissionCandidate do
  @moduledoc """
  Ecto schema for Runtime Endpoint admission review candidates.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.Node

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources [:runtime_endpoint_observation, :provisioned_placeholder, :registered_node]
  @admission_categories [
    :pending_observed,
    :pending_provisioned,
    :pending_registered,
    :rejected,
    :admitted
  ]
  # `external` is reserved for future provider/runtime adapters. RuntimeEndpoint.Target
  # currently supports first-party gRPC compatibility and BEAM targets only.
  @endpoint_transports [:grpc, :beam, :external]

  @type t :: %__MODULE__{}

  schema "node_admission_candidates" do
    field(:source, Ecto.Enum, values: @sources)
    field(:admission_category, Ecto.Enum, values: @admission_categories)
    field(:observed_identity, :map, default: %{})
    field(:target_ref, :string)
    field(:endpoint_transport, Ecto.Enum, values: @endpoint_transports)
    field(:endpoint_target, :string)
    field(:inventory, :map, default: %{})
    field(:compatibility_evidence, :map, default: %{})
    field(:last_observed_at, :utc_datetime_usec)

    belongs_to(:node, Node)

    timestamps(type: :utc_datetime_usec)
  end

  @spec sources() :: [atom()]
  def sources, do: @sources

  @spec admission_categories() :: [atom()]
  def admission_categories, do: @admission_categories

  @review_categories [:pending_observed, :pending_provisioned, :pending_registered, :rejected]

  @spec review_categories() :: [atom()]
  def review_categories, do: @review_categories

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, [
      :node_id,
      :source,
      :admission_category,
      :observed_identity,
      :target_ref,
      :endpoint_transport,
      :endpoint_target,
      :inventory,
      :compatibility_evidence,
      :last_observed_at
    ])
    |> validate_required([:source, :admission_category, :observed_identity, :inventory])
    |> validate_required([:compatibility_evidence])
    |> validate_observed_timestamp()
    |> foreign_key_constraint(:node_id)
    |> check_constraint(:source, name: :node_admission_candidates_source)
    |> check_constraint(:admission_category, name: :node_admission_candidates_admission_category)
    |> check_constraint(:endpoint_transport, name: :node_admission_candidates_endpoint_transport)
    |> check_constraint(:last_observed_at, name: :node_admission_candidates_observed_timestamp)
    |> unique_constraint(:observed_identity,
      name: :idx_node_admission_candidates_open_observed_identity_unique
    )
  end

  defp validate_observed_timestamp(changeset) do
    source = get_field(changeset, :source)
    last_observed_at = get_field(changeset, :last_observed_at)

    if source == :runtime_endpoint_observation and is_nil(last_observed_at) do
      add_error(changeset, :last_observed_at, "must be present for runtime observations")
    else
      changeset
    end
  end
end
