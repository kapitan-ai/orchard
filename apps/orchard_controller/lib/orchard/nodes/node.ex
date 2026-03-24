defmodule Orchard.Nodes.Node do
  @moduledoc """
  Ecto schema for persistent node inventory entries.

  Maps to the `nodes` table with SPEC-aligned `node_state` and `node_health`
  enums. Represents a discovered node-agent that has reported its identity
  via a successful `GetStatus` RPC.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [
    :provisioned,
    :registered,
    :admitted,
    :active,
    :cordoned,
    :draining,
    :maintenance,
    :decommissioning,
    :removed
  ]

  @health_values [:healthy, :degraded, :unhealthy, :unreachable]

  schema "nodes" do
    field(:hostname, :string)
    field(:display_name, :string)
    field(:advertise_addr, :string)
    field(:rpc_port, :integer)
    field(:state, Ecto.Enum, values: @states)
    field(:health, Ecto.Enum, values: @health_values)
    field(:capabilities, :map, default: %{})
    field(:agent_version, :string)
    field(:last_heartbeat_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec health_values() :: [atom()]
  def health_values, do: @health_values

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :id,
      :hostname,
      :display_name,
      :advertise_addr,
      :rpc_port,
      :state,
      :health,
      :capabilities,
      :agent_version,
      :last_heartbeat_at
    ])
    |> validate_required([
      :hostname,
      :display_name,
      :advertise_addr,
      :rpc_port,
      :state,
      :health,
      :capabilities
    ])
    |> validate_length(:hostname, min: 1)
    |> validate_length(:display_name, min: 1)
    |> validate_length(:advertise_addr, min: 1)
    |> validate_number(:rpc_port, greater_than: 0, less_than_or_equal_to: 65535)
    |> unique_constraint(:display_name)
    |> unique_constraint([:advertise_addr, :rpc_port])
    |> check_constraint(:rpc_port, name: :nodes_rpc_port_range)
  end
end
