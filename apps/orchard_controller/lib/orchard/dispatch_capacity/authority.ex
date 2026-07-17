defmodule Orchard.DispatchCapacity.Authority do
  @moduledoc """
  Durable cluster-wide dispatch-capacity enforcement authority.

  The schema spans both phases so the evaluator's truth table and the database
  constraints can be settled once, but this foundation ships no way to reach
  `enforcing`: the row is seeded `pre_cutover` and nothing writes the phase.
  Enforcement cutover belongs to a later implementation slice.
  """

  use Ecto.Schema

  @primary_key {:singleton, :boolean, autogenerate: false}
  @phases [:pre_cutover, :enforcing]

  @type phase :: :pre_cutover | :enforcing
  @type t :: %__MODULE__{
          singleton: boolean(),
          enforcement_phase: phase(),
          required_contract_version: pos_integer(),
          cutover_by_actor_type: String.t() | nil,
          cutover_by_actor_id: String.t() | nil,
          cutover_at: DateTime.t() | nil,
          cutover_reason: String.t() | nil
        }

  schema "dispatch_capacity_authority" do
    field(:enforcement_phase, Ecto.Enum, values: @phases, default: :pre_cutover)
    field(:required_contract_version, :integer, default: 1)
    field(:cutover_by_actor_type, :string)
    field(:cutover_by_actor_id, :string)
    field(:cutover_at, :utc_datetime_usec)
    field(:cutover_reason, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
