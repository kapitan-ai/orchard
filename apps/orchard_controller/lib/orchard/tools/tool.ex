defmodule Orchard.Tools.Tool do
  @moduledoc """
  Ecto schema for controller-managed tool registry entries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Inference.ToolingValidation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @states [:active, :deprecated]
  @execution_modes [:client_only, :server_hostable]
  @source_kinds [:manual, :mcp_server]

  @type state :: :active | :deprecated
  @type execution_mode :: :client_only | :server_hostable
  @type source_kind :: :manual | :mcp_server

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          version: String.t() | nil,
          state: state() | nil,
          definition: map(),
          execution_mode: execution_mode() | nil,
          source_kind: source_kind() | nil,
          source_ref: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "tools" do
    field(:name, :string)
    field(:version, :string)
    field(:state, Ecto.Enum, values: @states, default: :active)
    field(:definition, :map, default: %{})
    field(:execution_mode, Ecto.Enum, values: @execution_modes, default: :client_only)
    field(:source_kind, Ecto.Enum, values: @source_kinds, default: :manual)
    field(:source_ref, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [state()]
  def states, do: @states

  @spec execution_modes() :: [execution_mode()]
  def execution_modes, do: @execution_modes

  @spec source_kinds() :: [source_kind()]
  def source_kinds, do: @source_kinds

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(tool, attrs) do
    tool
    |> cast(attrs, [
      :name,
      :version,
      :state,
      :definition,
      :execution_mode,
      :source_kind,
      :source_ref
    ])
    |> validate_required([:name, :version, :state, :definition, :execution_mode, :source_kind])
    |> validate_length(:name, min: 1)
    |> validate_length(:version, min: 1)
    |> validate_ref_identity_part(:name)
    |> validate_ref_identity_part(:version)
    |> validate_length(:source_ref, min: 1)
    |> validate_definition_shape()
    |> unique_constraint([:name, :version])
    |> check_constraint(:name, name: :tools_name_ref_safe)
    |> check_constraint(:version, name: :tools_version_ref_safe)
  end

  defp validate_ref_identity_part(%Ecto.Changeset{} = changeset, field) do
    validate_change(changeset, field, fn
      ^field, "" ->
        []

      ^field, value ->
        if ToolingValidation.valid_tool_ref_part?(value) do
          []
        else
          [{field, "must be ref-safe for tool://<name>@<version>"}]
        end
    end)
  end

  defp validate_definition_shape(%Ecto.Changeset{} = changeset) do
    definition = get_field(changeset, :definition)
    name = get_field(changeset, :name)

    case definition_error(definition, name) do
      nil -> changeset
      message -> add_error(changeset, :definition, message)
    end
  end

  defp definition_error(definition, _name) when not is_map(definition), do: "must be a map"

  defp definition_error(definition, name) do
    if map_value(definition, :type) == "function" do
      validate_function_payload(map_value(definition, :function), name)
    else
      "must be a function tool definition"
    end
  end

  defp validate_function_payload(function, _name) when not is_map(function),
    do: "must include a function map"

  defp validate_function_payload(function, name) do
    function_name = map_value(function, :name)

    if non_empty_binary?(function_name) do
      validate_function_name_match(function_name, name)
    else
      "must include a non-empty function.name"
    end
  end

  defp validate_function_name_match(function_name, name)
       when is_binary(name) and name != "" and function_name != name,
       do: "function.name must match tool name"

  defp validate_function_name_match(_function_name, _name), do: nil

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
