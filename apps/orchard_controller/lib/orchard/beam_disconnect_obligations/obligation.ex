defmodule Orchard.BeamDisconnectObligations.Obligation do
  @moduledoc """
  Durable evidence that obsolete BEAM authority still requires disconnection.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @states [:pending, :attempted, :completed]

  @type t :: %__MODULE__{}

  schema "beam_disconnect_obligations" do
    field(:peer_beam_name, :string)
    field(:reason, :string)
    field(:state, Ecto.Enum, values: @states)
    field(:due_at, :utc_datetime_usec)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:completed_at, :utc_datetime_usec)
    field(:evidence, :map, default: %{})

    belongs_to(:node, Orchard.Nodes.Node)
    belongs_to(:grant, Orchard.BeamPeerGrants.Grant)
    belongs_to(:credential_generation, Orchard.NodeCredentials.Generation)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(obligation, attrs) do
    obligation
    |> cast(attrs, [
      :node_id,
      :grant_id,
      :credential_generation_id,
      :peer_beam_name,
      :reason,
      :state,
      :due_at,
      :last_attempt_at,
      :attempt_count,
      :completed_at,
      :evidence
    ])
    |> validate_required([
      :node_id,
      :peer_beam_name,
      :reason,
      :state,
      :due_at,
      :attempt_count,
      :evidence
    ])
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :beam_disconnect_obligations_state)
    |> check_constraint(:attempt_count, name: :beam_disconnect_obligations_attempt_count)
  end
end
