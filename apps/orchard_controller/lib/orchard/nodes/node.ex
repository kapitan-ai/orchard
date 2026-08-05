defmodule Orchard.Nodes.Node do
  @moduledoc """
  Ecto schema for persistent node inventory entries.

  Maps to the `nodes` table with SPEC-aligned `node_state` and `node_health`
  enums. Represents provisioned placeholders as well as node-agents that have
  reported inventory.
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

  @type t :: %__MODULE__{}

  schema "nodes" do
    field(:hostname, :string)
    field(:display_name, :string)
    field(:advertise_addr, :string)
    field(:canonical_beam_name, :string)
    field(:rpc_port, :integer)
    field(:connect_host, :string)
    field(:connect_port, :integer)
    field(:state, Ecto.Enum, values: @states)
    field(:health, Ecto.Enum, values: @health_values)
    field(:capabilities, :map, default: %{})
    field(:tool_readiness, :map, default: %{})
    field(:agent_version, :string)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:last_transport_failure_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec health_values() :: [atom()]
  def health_values, do: @health_values

  @spec provisioning_changeset(struct(), map()) :: Ecto.Changeset.t()
  def provisioning_changeset(node, attrs) do
    node
    |> cast(attrs, [
      :id,
      :display_name,
      :state,
      :health,
      :capabilities,
      :tool_readiness
    ])
    |> validate_required([
      :display_name,
      :state,
      :health,
      :capabilities,
      :tool_readiness
    ])
    |> validate_length(:display_name, min: 1)
    |> validate_tool_readiness_contract()
    |> unique_constraint(:display_name)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :id,
      :hostname,
      :display_name,
      :advertise_addr,
      :canonical_beam_name,
      :rpc_port,
      :connect_host,
      :connect_port,
      :state,
      :health,
      :capabilities,
      :tool_readiness,
      :agent_version,
      :last_heartbeat_at,
      :last_transport_failure_at
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
    |> validate_length(:connect_host, min: 1)
    |> validate_number(:rpc_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_number(:connect_port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_connect_target_pair()
    |> validate_tool_readiness_contract()
    |> unique_constraint(:display_name)
    |> unique_constraint([:advertise_addr, :rpc_port])
    |> unique_constraint([:connect_host, :connect_port])
    |> check_constraint(:rpc_port, name: :nodes_rpc_port_range)
    |> check_constraint(:connect_port, name: :nodes_connect_port_range)
    |> check_constraint(:connect_host, name: :nodes_connect_target_pair)
  end

  defp validate_connect_target_pair(changeset) do
    connect_host = get_field(changeset, :connect_host)
    connect_port = get_field(changeset, :connect_port)

    case {is_nil(connect_host), is_nil(connect_port)} do
      {true, true} ->
        changeset

      {false, false} ->
        changeset

      {true, false} ->
        add_error(changeset, :connect_host, "must be present when connect_port is present")

      {false, true} ->
        add_error(changeset, :connect_port, "must be present when connect_host is present")
    end
  end

  defp validate_tool_readiness_contract(changeset) do
    tool_readiness = get_field(changeset, :tool_readiness)
    hosted_tool_refs = hosted_tool_ref_list(get_field(changeset, :capabilities))

    cond do
      is_nil(tool_readiness) ->
        changeset

      not is_map(tool_readiness) ->
        add_error(changeset, :tool_readiness, "must be a map")

      Enum.all?(tool_readiness, &valid_tool_readiness_entry?(&1, hosted_tool_refs)) ->
        changeset

      true ->
        add_error(
          changeset,
          :tool_readiness,
          "must reference hosted tools with valid readiness payloads"
        )
    end
  end

  defp hosted_tool_ref_list(capabilities) when is_map(capabilities) do
    capabilities
    |> map_value(:hosted_tools)
    |> hosted_tool_ref_list_from_entries()
  end

  defp hosted_tool_ref_list(_capabilities), do: []

  defp hosted_tool_ref_list_from_entries(entries) when is_list(entries) do
    Enum.flat_map(entries, &hosted_tool_ref/1)
  end

  defp hosted_tool_ref_list_from_entries(_entries), do: []

  defp hosted_tool_ref(entry) do
    case map_value(entry, :ref) do
      ref when is_binary(ref) and ref != "" -> [ref]
      _other -> []
    end
  end

  defp valid_tool_readiness_entry?({ref, payload}, hosted_tool_refs)
       when is_binary(ref) and is_map(payload) do
    ref in hosted_tool_refs and
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
