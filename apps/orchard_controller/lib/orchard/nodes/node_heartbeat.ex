defmodule Orchard.Nodes.NodeHeartbeat do
  @moduledoc """
  Durable bounded Runtime Endpoint observation history for one trusted Node.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.Node

  @foreign_key_type :binary_id
  @health_values [:healthy, :degraded, :unhealthy, :unreachable]

  @type t :: %__MODULE__{}

  schema "node_heartbeats" do
    belongs_to(:node, Node)
    field(:observed_at, :utc_datetime_usec)
    field(:health, Ecto.Enum, values: @health_values)
    field(:available_memory_bytes, :integer)
    field(:swap_used_bytes, :integer)
    field(:cpu_load_1m, :decimal)
    field(:thermal_pressure, :string)
    field(:active_requests, :integer, default: 0)
    field(:payload, :map, default: %{})
  end

  @doc "Validates one normalized trusted heartbeat row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(heartbeat, attrs) do
    heartbeat
    |> cast(attrs, [
      :node_id,
      :observed_at,
      :health,
      :available_memory_bytes,
      :swap_used_bytes,
      :cpu_load_1m,
      :thermal_pressure,
      :active_requests,
      :payload
    ])
    |> validate_required([:node_id, :observed_at, :health, :active_requests, :payload])
    |> validate_number(:available_memory_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:swap_used_bytes, greater_than_or_equal_to: 0)
    |> validate_number(:active_requests, greater_than_or_equal_to: 0)
    |> validate_length(:thermal_pressure, max: 80)
    |> foreign_key_constraint(:node_id)
  end
end
