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
    field(:tool_readiness, :map, default: %{})
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
      :tool_readiness,
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
      :capabilities,
      :tool_readiness
    ])
    |> validate_length(:hostname, min: 1)
    |> validate_length(:display_name, min: 1)
    |> validate_length(:advertise_addr, min: 1)
    |> validate_number(:rpc_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_tool_readiness_contract()
    |> unique_constraint(:display_name)
    |> unique_constraint([:advertise_addr, :rpc_port])
    |> check_constraint(:rpc_port, name: :nodes_rpc_port_range)
  end

  defp validate_tool_readiness_contract(changeset) do
    tool_readiness = get_field(changeset, :tool_readiness)
    hosted_tool_refs = hosted_tool_refs(get_field(changeset, :capabilities))

    cond do
      is_nil(tool_readiness) ->
        changeset

      not is_map(tool_readiness) ->
        add_error(changeset, :tool_readiness, "must be a map")

      Enum.all?(tool_readiness, &valid_tool_readiness_entry?(&1, hosted_tool_refs)) ->
        changeset

      true ->
        add_error(changeset, :tool_readiness, "must reference hosted tools with valid readiness payloads")
    end
  end

  defp hosted_tool_refs(capabilities) when is_map(capabilities) do
    capabilities
    |> map_value(:hosted_tools)
    |> case do
      entries when is_list(entries) ->
        entries
        |> Enum.flat_map(fn entry ->
          case map_value(entry, :ref) do
            ref when is_binary(ref) and ref != "" -> [ref]
            _other -> []
          end
        end)
        |> MapSet.new()

      _other ->
        MapSet.new()
    end
  end

  defp hosted_tool_refs(_capabilities), do: MapSet.new()

  defp valid_tool_readiness_entry?({ref, payload}, hosted_tool_refs)
       when is_binary(ref) and is_map(payload) do
    MapSet.member?(hosted_tool_refs, ref) and
      is_boolean(map_value(payload, :ready)) and
      is_binary(map_value(payload, :status_code)) and
      is_binary(map_value(payload, :status_message))
  end

  defp valid_tool_readiness_entry?(_entry, _hosted_tool_refs), do: false

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
