defmodule Orchard.Nodes.AdmissionMode do
  @moduledoc """
  Durable cluster-wide Node Admission mode.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:singleton, :boolean, autogenerate: false}
  @modes [:manual, :enrollment_preauthorized]

  @type mode :: :manual | :enrollment_preauthorized
  @type t :: %__MODULE__{}

  schema "node_admission_modes" do
    field(:mode, Ecto.Enum, values: @modes, default: :manual)
    field(:version, :integer, default: 1)
    field(:changed_by_actor_type, :string)
    field(:changed_by_actor_id, :string)
    field(:changed_at, :utc_datetime_usec)
    field(:change_reason, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @spec modes() :: [mode()]
  def modes, do: @modes

  @spec change_changeset(t(), map()) :: Ecto.Changeset.t()
  def change_changeset(mode, attrs) do
    mode
    |> cast(attrs, [
      :mode,
      :version,
      :changed_by_actor_type,
      :changed_by_actor_id,
      :changed_at,
      :change_reason
    ])
    |> update_change(:change_reason, &String.trim/1)
    |> validate_required([
      :mode,
      :version,
      :changed_by_actor_type,
      :changed_by_actor_id,
      :changed_at,
      :change_reason
    ])
    |> validate_number(:version, greater_than: 0)
    |> check_constraint(:singleton, name: :node_admission_modes_singleton)
    |> check_constraint(:mode, name: :node_admission_modes_mode)
    |> check_constraint(:version, name: :node_admission_modes_version)
  end
end
